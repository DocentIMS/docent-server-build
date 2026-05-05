#!/bin/bash
# ============================================================================
# run-phases.sh - Chain all build phases automatically.
#
# Use only AFTER phase 0 has been run (so tenant.local and secrets.local
# exist). This script runs phases 1 -> 2 -> 3 -> 4 -> 5 -> 5a -> 5b -> 5c -> 6
# in order, stopping at the first failure.
#
# All phases are idempotent, so it's safe to re-run this script after a
# reboot or after fixing whatever caused a failure.
#
# Usage:
#   sudo bash run-phases.sh                # run all phases
#   sudo bash run-phases.sh --from 4       # start from phase 4
#   sudo bash run-phases.sh --only 4       # run only phase 4
#
# After phase 1 reboots the server, the SSH session will die. After the
# server comes back up, SSH back in and run this script again - it will
# skip phase 1 (already done) and continue with phase 2.
# ============================================================================

set -e

# ============================================================================
# COSMETICS
# ============================================================================
# Use real escape characters via $'...' (not literal backslash strings).
# When stdout is not a terminal, you can disable colors by checking [ -t 1 ]
# but for now we always emit them - terminal handling is good enough on
# every Linux/MobaXterm/PuTTY combo we care about.
RESET=$'\e[0m'
BOLD=$'\e[1m'
RED=$'\e[31m'
GREEN=$'\e[32m'
YELLOW=$'\e[33m'
CYAN=$'\e[36m'

# ============================================================================
# DEFAULTS
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
TENANT_FILE="$REPO_ROOT/tenant.local"
SECRETS_FILE="$REPO_ROOT/secrets.local"

# Ordered list of phases. Each entry is "label:script-filename".
PHASES=(
    "1:phase1.sh"
    "2:phase2.sh"
    "3:phase3.sh"
    "4:phase4.sh"
    "5:phase5.sh"
    "5a:phase5a-rc-plus.sh"
    "5b:phase5b-globaladdressbook.sh"
    "5c:phase5c-email-ai.sh"
    "6:phase6.sh"
)

# ============================================================================
# Argument parsing
# ============================================================================
START_FROM=""
ONLY_PHASE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --from)
            START_FROM="$2"
            shift 2
            ;;
        --only)
            ONLY_PHASE="$2"
            shift 2
            ;;
        --help|-h)
            sed -n '2,/^# =/p' "$0" | sed 's/^# \?//' | head -n 25
            exit 0
            ;;
        *)
            echo "${RED}Unknown argument: $1${RESET}"
            echo "Try: bash run-phases.sh --help"
            exit 1
            ;;
    esac
done

# ============================================================================
# Pre-flight: must be root
# ============================================================================
if [ "$(id -u)" -ne 0 ]; then
    echo "${RED}ERROR: run-phases.sh must be run as root (or via sudo).${RESET}"
    echo "Try:  sudo bash $0"
    exit 1
fi

# ============================================================================
# Pre-flight: phase 0 must have run
# ============================================================================
if [ ! -f "$TENANT_FILE" ] || [ ! -f "$SECRETS_FILE" ]; then
    echo "${RED}ERROR: Phase 0 has not been run yet.${RESET}"
    echo ""
    echo "  Missing one or both of:"
    echo "    $TENANT_FILE"
    echo "    $SECRETS_FILE"
    echo ""
    echo "  Run phase 0 first:"
    echo "    sudo bash $SCRIPT_DIR/phase0-bootstrap.sh"
    exit 1
fi

# ============================================================================
# Build the list of phases to actually run
# ============================================================================
TO_RUN=()
if [ -n "$ONLY_PHASE" ]; then
    # --only: a single specific phase
    for entry in "${PHASES[@]}"; do
        label="${entry%%:*}"
        if [ "$label" = "$ONLY_PHASE" ]; then
            TO_RUN+=("$entry")
            break
        fi
    done
    if [ ${#TO_RUN[@]} -eq 0 ]; then
        echo "${RED}ERROR: --only $ONLY_PHASE: no such phase.${RESET}"
        echo "Valid phase labels: 1 2 3 4 5 5a 5b 5c 6"
        exit 1
    fi
elif [ -n "$START_FROM" ]; then
    # --from N: start at phase N, run all subsequent
    found=0
    for entry in "${PHASES[@]}"; do
        label="${entry%%:*}"
        if [ "$found" -eq 1 ] || [ "$label" = "$START_FROM" ]; then
            found=1
            TO_RUN+=("$entry")
        fi
    done
    if [ ${#TO_RUN[@]} -eq 0 ]; then
        echo "${RED}ERROR: --from $START_FROM: no such phase.${RESET}"
        echo "Valid phase labels: 1 2 3 4 5 5a 5b 5c 6"
        exit 1
    fi
else
    # No flag: run all phases
    TO_RUN=("${PHASES[@]}")
fi

# ============================================================================
# Banner
# ============================================================================
echo ""
echo "${BOLD}${CYAN}============================================================${RESET}"
echo "${BOLD}${CYAN}  RUN-PHASES - automated phase chain${RESET}"
echo "${BOLD}${CYAN}  Started: $(date "+%Y-%m-%d %H:%M:%S %Z")${RESET}"
echo "${BOLD}${CYAN}============================================================${RESET}"
echo ""
echo "  Phases to run:"
for entry in "${TO_RUN[@]}"; do
    label="${entry%%:*}"
    script="${entry##*:}"
    echo "    Phase $label  ($script)"
done
echo ""
echo "  Notes:"
echo "    - Each phase logs to /tmp/phaseN-run.log."
echo "    - On the first failure, this script stops."
echo "    - Phase 1 may reboot the server. After reboot, SSH back in"
echo "      and re-run this script - already-done phases will be skipped."
echo "    - All phases are idempotent. Re-running is safe."
echo ""
read -r -p "Type ${BOLD}yes${RESET} to start: " confirm
if [ "$confirm" != "yes" ]; then
    echo "Aborted."
    exit 1
fi

# ============================================================================
# Run them
# ============================================================================
START_TIME=$(date +%s)

for entry in "${TO_RUN[@]}"; do
    label="${entry%%:*}"
    script="${entry##*:}"
    script_path="$SCRIPT_DIR/$script"
    log_path="/tmp/phase${label}-run.log"

    if [ ! -f "$script_path" ]; then
        echo ""
        echo "${RED}ERROR: Phase $label script not found at $script_path${RESET}"
        exit 1
    fi

    echo ""
    echo "${BOLD}${CYAN}============================================================${RESET}"
    echo "${BOLD}${CYAN}  PHASE $label - $script${RESET}"
    echo "${BOLD}${CYAN}  Log: $log_path${RESET}"
    echo "${BOLD}${CYAN}============================================================${RESET}"
    echo ""

    set +e
    bash "$script_path" 2>&1 | tee "$log_path"
    rc=${PIPESTATUS[0]}
    set -e

    if [ "$rc" -ne 0 ]; then
        echo ""
        echo "${RED}============================================================${RESET}"
        echo "${RED}  PHASE $label FAILED (exit code $rc)${RESET}"
        echo "${RED}============================================================${RESET}"
        echo ""
        echo "  Log: $log_path"
        echo "  Repo: $REPO_ROOT"
        echo ""
        echo "  Investigate the log, fix the issue, then resume:"
        echo "    sudo bash $0 --from $label"
        exit "$rc"
    fi

    # Heuristic: if the log says "FAIL" in the verification block, the phase
    # technically exited 0 but had failing checks. Surface that loudly.
    if grep -qE '^\s*\[FAIL\]' "$log_path"; then
        echo ""
        echo "${YELLOW}  WARNING: Phase $label had [FAIL] checks in its verification block.${RESET}"
        echo "${YELLOW}  Review the log before continuing.${RESET}"
        echo ""
        read -r -p "Continue anyway? Type ${BOLD}yes${RESET} to proceed: " keep_going
        if [ "$keep_going" != "yes" ]; then
            echo "Stopped at user request. Resume with:"
            echo "  sudo bash $0 --from $label"
            exit 1
        fi
    fi

    echo ""
    echo "${GREEN}  ✓ Phase $label completed.${RESET}"
done

# ============================================================================
# Summary
# ============================================================================
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
DURATION_MIN=$((DURATION / 60))
DURATION_SEC=$((DURATION % 60))

echo ""
echo "${BOLD}${GREEN}============================================================${RESET}"
echo "${BOLD}${GREEN}  ALL PHASES COMPLETE${RESET}"
echo "${BOLD}${GREEN}============================================================${RESET}"
echo ""
echo "  Phases run: ${#TO_RUN[@]}"
echo "  Total time: ${DURATION_MIN}m ${DURATION_SEC}s"
echo ""
echo "  Next steps:"
echo "    1. Verify the build by following the manual checks at the end of"
echo "       each phase's output (Roundcube login, mail test, WP install)."
echo "    2. See QUICK-REFERENCE.txt for day-to-day commands and recovery."
echo "    3. After verifying, delete the sensitive files:"
echo "         rm $REPO_ROOT/CREDENTIALS.txt"
echo "         rm $REPO_ROOT/QUICK-REFERENCE.txt"
echo ""
