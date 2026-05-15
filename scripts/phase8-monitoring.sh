#!/bin/bash
# ============================================================================
# phase8-monitoring.sh
#
# Creates UptimeRobot monitors for a tenant.
#
# RUNS ON DOCENTTEMPLATE (the build server), NOT on the client server.
# This keeps the UptimeRobot API key off client servers entirely.
#
# Usage:
#   ./phase8-monitoring.sh <tenant-domain>
#
# Example:
#   ./phase8-monitoring.sh docent.us
#
# Creates 6 monitors per tenant:
#   - HTTP keyword: WordPress    (https://<domain>/         keyword "Docent IMS")
#   - HTTP keyword: Plone        (https://team.<domain>/    keyword "Plone")
#   - HTTP keyword: Roundcube    (https://<domain>/mail/    keyword "Roundcube")
#   - Port: SMTP                 (<domain>:25)
#   - Port: Submission           (<domain>:587)
#   - Port: IMAPS                (<domain>:993)
#
# Writes monitor IDs to /home/wayne/uptimerobot-monitors/<domain>.txt
# This file is the source of truth for retire-tenant.sh and audit-monitors.sh.
#
# Idempotent: re-running for the same domain will refuse and exit unless
# --force is passed. (Future improvement: detect existing monitors and skip.)
# ============================================================================

set -euo pipefail

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
SECRETS_FILE="/home/wayne/.docent-secrets.env"
MONITORS_DIR="/home/wayne/uptimerobot-monitors"
DEFAULT_INTERVAL=300   # 5 minutes (UR allows 60, 300, 600, 900, 1800, 3600)
KEYWORD_PREFIX="[auto]"  # All auto-created monitors get this prefix in friendly_name
UR_API="https://api.uptimerobot.com/v2"

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------
DRY_RUN=0
DOMAIN=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--dry-run] <tenant-domain>"
      echo "Example: $0 docent.us"
      echo "         $0 --dry-run docent.us"
      exit 0
      ;;
    -*)
      echo "ERROR: unknown option: $1"
      echo "Usage: $0 [--dry-run] <tenant-domain>"
      exit 1
      ;;
    *)
      if [ -z "$DOMAIN" ]; then
        DOMAIN="$1"
      else
        echo "ERROR: unexpected extra argument: $1"
        exit 1
      fi
      shift
      ;;
  esac
done

if [ -z "$DOMAIN" ]; then
  echo "Usage: $0 [--dry-run] <tenant-domain>"
  echo "Example: $0 docent.us"
  exit 1
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "============================================================"
  echo "  DRY RUN MODE — no API calls will be made"
  echo "============================================================"
fi

# Sanity: domain should not contain protocol or path
if [[ "$DOMAIN" =~ ^https?:// ]] || [[ "$DOMAIN" =~ / ]]; then
  echo "ERROR: domain should be bare hostname (e.g. 'docent.us'), not URL"
  exit 1
fi

# ----------------------------------------------------------------------------
# Preflight: load API key
# ----------------------------------------------------------------------------
if [ ! -f "$SECRETS_FILE" ]; then
  echo "ERROR: secrets file not found: $SECRETS_FILE"
  exit 1
fi

# shellcheck disable=SC1090
source "$SECRETS_FILE"

if [ -z "${UPTIMEROBOT_API_KEY:-}" ]; then
  echo "ERROR: UPTIMEROBOT_API_KEY not set in $SECRETS_FILE"
  exit 1
fi

# ----------------------------------------------------------------------------
# Preflight: monitor budget check
# ----------------------------------------------------------------------------
echo "Checking UptimeRobot monitor budget..."
CURRENT_COUNT=$(curl -sS -X POST "$UR_API/getMonitors" \
  -d "api_key=$UPTIMEROBOT_API_KEY" \
  -d "format=json" \
  | grep -o '"total":[0-9]*' | head -1 | cut -d: -f2)

if [ -z "$CURRENT_COUNT" ]; then
  echo "ERROR: could not parse monitor count from getMonitors response"
  exit 1
fi

PLAN_CAP=50  # Solo plan
NEW_MONITORS=6
PROJECTED=$((CURRENT_COUNT + NEW_MONITORS))

echo "  Current monitors: $CURRENT_COUNT"
echo "  Adding:           $NEW_MONITORS"
echo "  Projected total:  $PROJECTED / $PLAN_CAP"

if [ "$PROJECTED" -gt "$PLAN_CAP" ]; then
  echo "ERROR: would exceed plan cap of $PLAN_CAP monitors"
  echo "       Either retire an old tenant, or upgrade UR plan."
  exit 1
fi

# ----------------------------------------------------------------------------
# Preflight: discover alert contacts to attach to new monitors
# ----------------------------------------------------------------------------
# Pulls the current alert contacts from UR and selects active ones by type.
# We attach: email (type 2) and SMS (type 8). We skip voice (type 14).
#
# Format expected by UR for the "alert_contacts" param on newMonitor:
#   id1_threshold_recurrence-id2_threshold_recurrence-...
# threshold and recurrence are typically 0 (use defaults).
echo "Discovering alert contacts..."

CONTACTS_JSON=$(curl -sS -X POST "$UR_API/getAlertContacts" \
  -d "api_key=$UPTIMEROBOT_API_KEY" \
  -d "format=json")

if ! echo "$CONTACTS_JSON" | grep -q '"stat":"ok"'; then
  echo "ERROR: could not fetch alert contacts."
  echo "Response: $CONTACTS_JSON"
  exit 1
fi

# Extract IDs for active email (type 2) and SMS (type 8) contacts.
# Uses python because grep/sed against arbitrary JSON is fragile.
ALERT_CONTACTS_PARAM=$(echo "$CONTACTS_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
wanted_types = {2: 'email', 8: 'sms'}   # type 14 (voice) excluded by omission
parts = []
for c in data.get('alert_contacts', []):
    t = c.get('type')
    if t in wanted_types and c.get('status') == 1:
        parts.append(str(c['id']) + '_0_0')
print('-'.join(parts))
")

if [ -z "$ALERT_CONTACTS_PARAM" ]; then
  echo "ERROR: no active email or SMS alert contacts found."
  echo "       Set them up in the UR dashboard first."
  exit 1
fi

# Friendly summary of which contacts were selected
SELECTED_SUMMARY=$(echo "$CONTACTS_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
types = {2: 'email', 8: 'sms'}
for c in data.get('alert_contacts', []):
    if c.get('type') in types and c.get('status') == 1:
        label = types[c['type']]
        val = c.get('value', '?')
        cid = c['id']
        print(f'  {label}: {val} (id {cid})')
")
echo "$SELECTED_SUMMARY"
# ----------------------------------------------------------------------------
# Preflight: check for existing audit file (idempotency)
# ----------------------------------------------------------------------------
mkdir -p "$MONITORS_DIR"
AUDIT_FILE="$MONITORS_DIR/$DOMAIN.txt"

if [ -f "$AUDIT_FILE" ]; then
  echo "ERROR: audit file already exists: $AUDIT_FILE"
  echo "       This domain appears to have monitors already created."
  echo "       Use retire-tenant.sh to remove them before re-creating."
  exit 1
fi

# ----------------------------------------------------------------------------
# Helper: create one monitor, echo back the ID
# ----------------------------------------------------------------------------
# Args: $1=friendly_name $2=type(2=keyword|4=port) $3=url $4...=extra params
create_monitor() {
  local name="$1"
  local mtype="$2"
  local url="$3"
  shift 3
  local extra=("$@")

  # All progress and error messages go to stderr.
  # ONLY the bare monitor ID is written to stdout, so callers can
  # safely capture it with $(...) without grabbing log lines.
  echo "  Creating: $name" >&2

  if [ "$DRY_RUN" -eq 1 ]; then
    # In dry-run, print the parameters that WOULD be sent, then return a fake ID.
    {
      echo "    [DRY RUN] would POST to $UR_API/newMonitor with:"
      echo "      type=$mtype"
      echo "      url=$url"
      echo "      interval=$DEFAULT_INTERVAL"
      echo "      friendly_name=$name"
      echo "      alert_contacts=$ALERT_CONTACTS_PARAM"
      # Show extra params (they come in as alternating -d "key=val" pairs)
      local i
      for ((i=0; i<${#extra[@]}; i+=2)); do
        echo "      ${extra[$((i+1))]}"
      done
    } >&2
    echo "DRY-RUN-FAKE-ID-$RANDOM"  # placeholder so calling code keeps working
    return 0
  fi

  local response
  response=$(curl -sS -X POST "$UR_API/newMonitor" \
    -d "api_key=$UPTIMEROBOT_API_KEY" \
    -d "format=json" \
    -d "type=$mtype" \
    -d "url=$url" \
    -d "interval=$DEFAULT_INTERVAL" \
    -d "friendly_name=$name" \
    -d "alert_contacts=$ALERT_CONTACTS_PARAM" \
    "${extra[@]}")

  if ! echo "$response" | grep -q '"stat":"ok"'; then
    echo "ERROR: monitor creation failed." >&2
    echo "Response: $response" >&2
    return 1
  fi

  local id
  id=$(echo "$response" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

  if [ -z "$id" ]; then
    echo "ERROR: could not parse monitor ID from response." >&2
    echo "Response: $response" >&2
    return 1
  fi

  echo "    ID: $id" >&2
  echo "$id"  # ← only this goes to stdout, captured by $(create_monitor ...)
}

# ----------------------------------------------------------------------------
# Create the 6 monitors, capture IDs as we go
# ----------------------------------------------------------------------------
echo ""
echo "Creating monitors for $DOMAIN..."

# Temporary scratch for IDs — written to audit file at the end if all succeed
TMPDIR_PATH=$(mktemp -d)
trap 'rm -rf "$TMPDIR_PATH"' EXIT
SCRATCH="$TMPDIR_PATH/ids.txt"
: > "$SCRATCH"

write_id() {
  # $1=label  $2=id
  echo "$1=$2" >> "$SCRATCH"
}

# Monitor 1: WordPress root (keyword check)
ID=$(create_monitor "$KEYWORD_PREFIX wp $DOMAIN" 2 "https://$DOMAIN/" \
  -d "keyword_type=2" -d "keyword_case_type=0" -d "keyword_value=Docent IMS")
write_id "wp" "$ID"

# Monitor 2: Plone (keyword check)
ID=$(create_monitor "$KEYWORD_PREFIX plone $DOMAIN" 2 "https://team.$DOMAIN/" \
  -d "keyword_type=2" -d "keyword_case_type=0" -d "keyword_value=Plone")
write_id "plone" "$ID"

# Monitor 3: Roundcube (keyword check)
ID=$(create_monitor "$KEYWORD_PREFIX mail $DOMAIN" 2 "https://$DOMAIN/mail/" \
  -d "keyword_type=2" -d "keyword_case_type=0" -d "keyword_value=Roundcube")
write_id "mail" "$ID"

# Monitor 4: SMTP port 25 (port check)
# Note: sub_type=99 is UR's "Custom Port" code. sub_type=1 ignores the port param.
ID=$(create_monitor "$KEYWORD_PREFIX smtp $DOMAIN" 4 "$DOMAIN" \
  -d "sub_type=99" -d "port=25")
write_id "smtp" "$ID"

# Monitor 5: Submission port 587 (port check)
ID=$(create_monitor "$KEYWORD_PREFIX submission $DOMAIN" 4 "$DOMAIN" \
  -d "sub_type=99" -d "port=587")
write_id "submission" "$ID"

# Monitor 6: IMAPS port 993 (port check)
ID=$(create_monitor "$KEYWORD_PREFIX imaps $DOMAIN" 4 "$DOMAIN" \
  -d "sub_type=99" -d "port=993")
write_id "imaps" "$ID"

# ----------------------------------------------------------------------------
# Write the audit file
# ----------------------------------------------------------------------------
# ----------------------------------------------------------------------------
# Write the audit file (skipped in dry-run)
# ----------------------------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
  echo ""
  echo "============================================================"
  echo "  DRY RUN complete. No API calls were made."
  echo "  No audit file written."
  echo "  Re-run without --dry-run to actually create monitors."
  echo "============================================================"
  exit 0
fi

{
  echo "# UptimeRobot monitor IDs for $DOMAIN"
  echo "# Created: $(date -Iseconds)"
  echo "# Used by retire-tenant.sh and audit-monitors.sh"
  echo "domain=$DOMAIN"
  cat "$SCRATCH"
} > "$AUDIT_FILE"

chmod 600 "$AUDIT_FILE"

echo ""
echo "============================================================"
echo "  Done. Created 6 monitors for $DOMAIN."
echo "  Audit file: $AUDIT_FILE"
echo "============================================================"
echo ""
echo "Next steps:"
echo "  1. Verify in UR dashboard: https://uptimerobot.com/dashboard"
echo "  2. Wait ~5 min for first check, confirm all monitors go green"
echo "  3. To retire this tenant later: ./retire-tenant.sh $DOMAIN"
