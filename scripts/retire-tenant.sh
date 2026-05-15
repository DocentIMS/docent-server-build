#!/bin/bash
# ============================================================================
# retire-tenant.sh
#
# Deletes UptimeRobot monitors for a tenant being decommissioned.
#
# RUNS ON DOCENTTEMPLATE (the build server), NOT on the client server.
# Reads the audit file written by phase8-monitoring.sh to find the IDs.
#
# Usage:
#   ./retire-tenant.sh <tenant-domain>
#   ./retire-tenant.sh --dry-run <tenant-domain>
#
# Example:
#   ./retire-tenant.sh chelseamallproject.com
#
# What it does:
#   1. Reads /home/wayne/uptimerobot-monitors/<domain>.txt
#   2. Confirms with the user (unless --yes is passed)
#   3. Deletes each monitor ID from UptimeRobot
#   4. Archives the audit file (does not delete - kept for audit trail)
#
# Safety:
#   - Refuses to run if audit file missing
#   - Requires "yes" confirmation by default (use --yes to skip)
#   - --dry-run shows what would be deleted without calling the API
#   - Archives audit file rather than deleting (moved to retired/ subdir)
# ============================================================================

set -euo pipefail

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
SECRETS_FILE="/home/wayne/.docent-secrets.env"
MONITORS_DIR="/home/wayne/uptimerobot-monitors"
RETIRED_DIR="$MONITORS_DIR/retired"
UR_API="https://api.uptimerobot.com/v2"

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------
DRY_RUN=0
SKIP_CONFIRM=0
DOMAIN=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --yes|-y)
      SKIP_CONFIRM=1
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--dry-run] [--yes] <tenant-domain>"
      echo ""
      echo "Options:"
      echo "  --dry-run   Show what would be deleted without calling the API"
      echo "  --yes       Skip confirmation prompt"
      echo ""
      echo "Example: $0 chelseamallproject.com"
      echo "         $0 --dry-run chelseamallproject.com"
      exit 0
      ;;
    -*)
      echo "ERROR: unknown option: $1"
      echo "Usage: $0 [--dry-run] [--yes] <tenant-domain>"
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
  echo "Usage: $0 [--dry-run] [--yes] <tenant-domain>"
  exit 1
fi

# Sanity: domain should not contain protocol or path
if [[ "$DOMAIN" =~ ^https?:// ]] || [[ "$DOMAIN" =~ / ]]; then
  echo "ERROR: domain should be bare hostname (e.g. 'docent.us'), not URL"
  exit 1
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "============================================================"
  echo "  DRY RUN MODE — no API calls will be made"
  echo "============================================================"
fi

# ----------------------------------------------------------------------------
# Preflight: audit file exists
# ----------------------------------------------------------------------------
AUDIT_FILE="$MONITORS_DIR/$DOMAIN.txt"

if [ ! -f "$AUDIT_FILE" ]; then
  echo "ERROR: audit file not found: $AUDIT_FILE"
  echo "       This tenant either was never set up via phase8-monitoring.sh"
  echo "       or has already been retired."
  echo ""
  echo "       To find orphan monitors in UR not tracked here, use:"
  echo "         ./audit-monitors.sh"
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
# Parse audit file: extract monitor IDs and their labels
# ----------------------------------------------------------------------------
# Audit file format (one per line, comment lines start with #):
#   domain=docent.us
#   wp=803080619
#   plone=803080620
#   ...
#
# We want all lines that look like "label=numeric_id" excluding "domain=...".

declare -a IDS=()
declare -a LABELS=()

while IFS='=' read -r key value; do
  # Skip comments and blanks
  [[ "$key" =~ ^# ]] && continue
  [ -z "$key" ] && continue
  # Skip the domain= line
  [ "$key" = "domain" ] && continue
  # Only accept numeric IDs
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    LABELS+=("$key")
    IDS+=("$value")
  fi
done < "$AUDIT_FILE"

if [ "${#IDS[@]}" -eq 0 ]; then
  echo "ERROR: audit file has no monitor IDs to delete: $AUDIT_FILE"
  exit 1
fi

# ----------------------------------------------------------------------------
# Show summary and confirm
# ----------------------------------------------------------------------------
echo ""
echo "About to retire tenant: $DOMAIN"
echo "Monitors to delete (${#IDS[@]} total):"
for i in "${!IDS[@]}"; do
  printf "  %-12s %s\n" "${LABELS[$i]}" "${IDS[$i]}"
done
echo ""

if [ "$DRY_RUN" -eq 0 ] && [ "$SKIP_CONFIRM" -eq 0 ]; then
  echo "Type 'yes' to confirm deletion (anything else aborts):"
  read -r CONFIRM
  if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 0
  fi
fi

# ----------------------------------------------------------------------------
# Delete each monitor
# ----------------------------------------------------------------------------
echo ""
echo "Deleting monitors..."

FAILED=()
DELETED=()

for i in "${!IDS[@]}"; do
  LABEL="${LABELS[$i]}"
  ID="${IDS[$i]}"
  echo "  Deleting: $LABEL (id $ID)"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "    [DRY RUN] would POST to $UR_API/deleteMonitor with id=$ID"
    continue
  fi

  RESPONSE=$(curl -sS -X POST "$UR_API/deleteMonitor" \
    -d "api_key=$UPTIMEROBOT_API_KEY" \
    -d "format=json" \
    -d "id=$ID")

  if echo "$RESPONSE" | grep -q '"stat":"ok"'; then
    echo "    OK"
    DELETED+=("$ID")
  elif echo "$RESPONSE" | grep -q '"type":"not_found"'; then
    # Monitor already gone — not an error in retire context
    echo "    Already deleted (not found in UR)"
    DELETED+=("$ID")
  else
    echo "    FAILED: $RESPONSE"
    FAILED+=("$ID")
  fi
done

# ----------------------------------------------------------------------------
# Archive the audit file (skipped in dry-run, skipped if any failures)
# ----------------------------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
  echo ""
  echo "============================================================"
  echo "  DRY RUN complete. No API calls were made."
  echo "  Audit file not archived."
  echo "============================================================"
  exit 0
fi

if [ "${#FAILED[@]}" -gt 0 ]; then
  echo ""
  echo "============================================================"
  echo "  WARNING: ${#FAILED[@]} monitor(s) failed to delete:"
  for id in "${FAILED[@]}"; do
    echo "    $id"
  done
  echo ""
  echo "  Audit file NOT archived (still at $AUDIT_FILE)"
  echo "  Investigate failures, then re-run to retry."
  echo "============================================================"
  exit 1
fi

# All succeeded — archive the audit file
mkdir -p "$RETIRED_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
ARCHIVE_PATH="$RETIRED_DIR/${DOMAIN}.${TIMESTAMP}.txt"
mv "$AUDIT_FILE" "$ARCHIVE_PATH"

# Append a retirement timestamp footer to the archived file
{
  echo ""
  echo "# Retired: $(date -Iseconds)"
  echo "# By: retire-tenant.sh"
} >> "$ARCHIVE_PATH"

echo ""
echo "============================================================"
echo "  Done. Retired tenant: $DOMAIN"
echo "  Deleted ${#DELETED[@]} monitor(s) from UptimeRobot."
echo "  Audit file archived: $ARCHIVE_PATH"
echo "============================================================"
