#!/bin/bash
# ============================================================================
# audit-monitors.sh
#
# Sanity check: compares UptimeRobot's monitor list against the audit files
# written by phase8-monitoring.sh. Reports mismatches.
#
# RUNS ON DOCENTTEMPLATE (the build server), NOT on the client server.
#
# Usage:
#   ./audit-monitors.sh           # full report
#   ./audit-monitors.sh --quiet   # only print if there are problems (for cron)
#
# What it checks:
#   1. ORPHANS: monitors in UR that aren't tracked by any active audit file
#      (could be: manual monitors, leftovers from a failed retire, or
#       monitors created outside the phase8 workflow)
#
#   2. MISSING: monitor IDs in audit files that don't exist in UR
#      (could be: deleted manually from the dashboard, or already retired
#       but the audit file wasn't archived)
#
#   3. SUMMARY: monitor counts, plan cap usage, active tenants
#
# Read-only: never modifies UR or local files. Just reports.
# ============================================================================

set -euo pipefail

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
SECRETS_FILE="/home/wayne/.docent-secrets.env"
MONITORS_DIR="/home/wayne/uptimerobot-monitors"
UR_API="https://api.uptimerobot.com/v2"
PLAN_CAP=50  # Solo plan

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------
QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --quiet|-q)
      QUIET=1
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--quiet]"
      echo ""
      echo "Options:"
      echo "  --quiet, -q   Only print output if there are problems (for cron)"
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1"
      exit 1
      ;;
  esac
done

# ----------------------------------------------------------------------------
# Preflight
# ----------------------------------------------------------------------------
if [ ! -f "$SECRETS_FILE" ]; then
  echo "ERROR: secrets file not found: $SECRETS_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$SECRETS_FILE"

if [ -z "${UPTIMEROBOT_API_KEY:-}" ]; then
  echo "ERROR: UPTIMEROBOT_API_KEY not set in $SECRETS_FILE" >&2
  exit 1
fi

# ----------------------------------------------------------------------------
# Step 1: pull current UR monitors
# ----------------------------------------------------------------------------
UR_JSON=$(curl -sS -X POST "$UR_API/getMonitors" \
  -d "api_key=$UPTIMEROBOT_API_KEY" \
  -d "format=json")

if ! echo "$UR_JSON" | grep -q '"stat":"ok"'; then
  echo "ERROR: getMonitors failed: $UR_JSON" >&2
  exit 1
fi

# Extract list of IDs and names from UR. Use python for robust JSON parsing.
# Output format: one line per monitor: "ID|friendly_name"
UR_LIST=$(echo "$UR_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for m in data.get('monitors', []):
    print(f\"{m['id']}|{m.get('friendly_name','')}\")
")

# Count of monitors in UR
UR_COUNT=$(echo "$UR_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('pagination',{}).get('total', 0))
")

# ----------------------------------------------------------------------------
# Step 2: collect IDs from all active audit files
# ----------------------------------------------------------------------------
# Active audit files live in $MONITORS_DIR (not the retired/ subdir).
# Build:
#   - AUDIT_IDS: a sorted list of all IDs claimed by audit files
#   - AUDIT_MAP: "ID|domain|label" for each ID (for reporting)

AUDIT_IDS_FILE=$(mktemp)
AUDIT_MAP_FILE=$(mktemp)
trap 'rm -f "$AUDIT_IDS_FILE" "$AUDIT_MAP_FILE"' EXIT

ACTIVE_TENANTS=0

if [ -d "$MONITORS_DIR" ]; then
  for f in "$MONITORS_DIR"/*.txt; do
    [ -f "$f" ] || continue
    ACTIVE_TENANTS=$((ACTIVE_TENANTS + 1))
    # Get domain from file
    domain=$(grep '^domain=' "$f" | head -1 | cut -d= -f2)
    [ -z "$domain" ] && domain="(unknown)"

    # Get all label=id lines
    while IFS='=' read -r key value; do
      [[ "$key" =~ ^# ]] && continue
      [ -z "$key" ] && continue
      [ "$key" = "domain" ] && continue
      if [[ "$value" =~ ^[0-9]+$ ]]; then
        echo "$value" >> "$AUDIT_IDS_FILE"
        echo "$value|$domain|$key" >> "$AUDIT_MAP_FILE"
      fi
    done < "$f"
  done
fi

# Sort the audit IDs file for comm
sort -u "$AUDIT_IDS_FILE" -o "$AUDIT_IDS_FILE"
AUDIT_COUNT=$(wc -l < "$AUDIT_IDS_FILE")

# ----------------------------------------------------------------------------
# Step 3: extract UR IDs into a sorted file for comparison
# ----------------------------------------------------------------------------
UR_IDS_FILE=$(mktemp)
UR_NAME_FILE=$(mktemp)
trap 'rm -f "$AUDIT_IDS_FILE" "$AUDIT_MAP_FILE" "$UR_IDS_FILE" "$UR_NAME_FILE"' EXIT

echo "$UR_LIST" | cut -d'|' -f1 | sort -u > "$UR_IDS_FILE"
echo "$UR_LIST" > "$UR_NAME_FILE"

# ----------------------------------------------------------------------------
# Step 4: compare
# ----------------------------------------------------------------------------
# Orphans = in UR but not in any audit file
# Missing = in audit file but not in UR

ORPHANS=$(comm -23 "$UR_IDS_FILE" "$AUDIT_IDS_FILE")
MISSING=$(comm -13 "$UR_IDS_FILE" "$AUDIT_IDS_FILE")

ORPHAN_COUNT=$(echo -n "$ORPHANS" | grep -c '.' || true)
MISSING_COUNT=$(echo -n "$MISSING" | grep -c '.' || true)

PROBLEMS=$((ORPHAN_COUNT + MISSING_COUNT))

# ----------------------------------------------------------------------------
# Step 5: report
# ----------------------------------------------------------------------------
# In --quiet mode, only print if there's a problem. Otherwise print full report.

if [ "$QUIET" -eq 1 ] && [ "$PROBLEMS" -eq 0 ]; then
  exit 0
fi

echo "============================================================"
echo "  UptimeRobot Monitor Audit"
echo "  $(date)"
echo "============================================================"
echo ""
echo "Summary:"
echo "  Monitors in UR:        $UR_COUNT / $PLAN_CAP"
echo "  Monitors in audit:     $AUDIT_COUNT"
echo "  Active tenants:        $ACTIVE_TENANTS"
echo ""

if [ "$ORPHAN_COUNT" -gt 0 ]; then
  echo "ORPHANS (in UR but not in any audit file): $ORPHAN_COUNT"
  echo "  These monitors are running in UR but no audit file claims them."
  echo "  They may be: manual monitors, leftovers from a failed retire,"
  echo "  or monitors created outside the phase8 workflow."
  echo ""
  while read -r id; do
    [ -z "$id" ] && continue
    name=$(awk -F'|' -v id="$id" '$1==id { sub(/^[^|]*\|/, ""); print; exit }' "$UR_NAME_FILE")
    printf "    %-12s %s\n" "$id" "$name"
  done <<< "$ORPHANS"
  echo ""
fi

if [ "$MISSING_COUNT" -gt 0 ]; then
  echo "MISSING (in audit file but not in UR): $MISSING_COUNT"
  echo "  These IDs are claimed by audit files but no longer exist in UR."
  echo "  They may have been: deleted manually from the dashboard,"
  echo "  or retired without archiving the audit file."
  echo ""
  while read -r id; do
    [ -z "$id" ] && continue
    info=$(grep "^${id}[|]" "$AUDIT_MAP_FILE" | head -1)
    domain=$(echo "$info" | cut -d'|' -f2)
    label=$(echo "$info" | cut -d'|' -f3)
    printf "    %-12s %s (%s)\n" "$id" "$domain" "$label"
  done <<< "$MISSING"
  echo ""
fi

if [ "$PROBLEMS" -eq 0 ]; then
  echo "All clear. UR monitors and audit files are in sync."
fi

echo "============================================================"

exit 0
