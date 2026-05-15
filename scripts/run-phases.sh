#!/bin/bash
# ============================================================================
# run-phases.sh - Chain all build phases automatically.
#
# Use only AFTER phase 0 has been run (so tenant.local and secrets.local
# exist). This script runs the core phases 1 -> 2 -> 3 -> 4 -> 5 -> 5a ->
# 5b -> 5c -> 6 in order, stopping at the first failure. After phase 6
# completes, the script prompts whether to continue with the Plone phases
# 7a -> 7b -> 7c (typed yes or no, no default).
#
# All phases are idempotent, so it's safe to re-run this script after a
# reboot or after fixing whatever caused a failure.
#
# Usage:
#   sudo bash run-phases.sh                # run 1-6, prompt for 7a/b/c
#   sudo bash run-phases.sh --from 4       # start from phase 4, prompt for 7
#   sudo bash run-phases.sh --from 7a      # run 7a, 7b, 7c (no prompt)
#   sudo bash run-phases.sh --only 4       # run only phase 4 (no prompt)
#   sudo bash run-phases.sh --only 7b      # run only phase 7b (no prompt)
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
# Ordered list of phases. Each entry is "label:script-filename".
# The Plone phases (7a/7b/7c) are part of this array so that --from and
# --only can target them, but the default run stops after CORE_LAST_LABEL
# and prompts the user whether to continue.
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
    "7a:phase7a-plone-prereqs.sh"
    "7b:phase7b-plone-buildout.sh"
    "7c:phase7c-plone-frontend.sh"
)
# After this label completes in the default run, the script prompts before
# running anything past it. (Phases past this point are the Plone install,
# which is optional and slow.)
CORE_LAST_LABEL="6"

# Set of phase labels that belong to the Plone chain. Used to format the
# prompt and to detect whether an explicit --from or --only is targeting
# Plone (so we don't prompt redundantly).
PLONE_LABELS=" 7a 7b 7c "

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
# - --only X      : run exactly phase X (could be a core phase or a Plone phase).
# - --from X      : run X and every subsequent phase in PHASES order. If X is
#                   a core phase (1..6), only the core sub-list runs first;
#                   the Plone phases are offered via a separate prompt after.
# - (no flag)     : run the core phases (1..CORE_LAST_LABEL), then prompt
#                   the user whether to continue with the Plone phases.
#
# The Plone prompt is presented separately (after the core chain finishes
# cleanly) instead of being a single up-front question, so a fresh build
# operator who has been watching 1-6 succeed can make the call with full
# information.
TO_RUN=()
SHOW_PLONE_PROMPT="no"

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
        echo "Valid phase labels: 1 2 3 4 5 5a 5b 5c 6 7a 7b 7c"
        exit 1
    fi
elif [ -n "$START_FROM" ]; then
    # --from N: start at phase N, run all subsequent in PHASES order.
    # If N is a core phase, stop at CORE_LAST_LABEL and offer Plone prompt.
    # If N is a Plone phase, run the rest of the Plone phases with no prompt.
    found=0
    starting_in_plone="no"
    case "$PLONE_LABELS" in
        *" $START_FROM "*) starting_in_plone="yes" ;;
    esac
    for entry in "${PHASES[@]}"; do
        label="${entry%%:*}"
        if [ "$found" -eq 1 ] || [ "$label" = "$START_FROM" ]; then
            found=1
            # If we started in core and just reached the first Plone phase,
            # stop adding here - those will be offered via the prompt.
            if [ "$starting_in_plone" = "no" ]; then
                case "$PLONE_LABELS" in
                    *" $label "*) break ;;
                esac
            fi
            TO_RUN+=("$entry")
        fi
    done
    if [ ${#TO_RUN[@]} -eq 0 ]; then
        echo "${RED}ERROR: --from $START_FROM: no such phase.${RESET}"
        echo "Valid phase labels: 1 2 3 4 5 5a 5b 5c 6 7a 7b 7c"
        exit 1
    fi
    # Only prompt for Plone if we started in core (we'll have stopped before 7a)
    if [ "$starting_in_plone" = "no" ]; then
        SHOW_PLONE_PROMPT="yes"
    fi
else
    # No flag: run the core phases. Plone is offered separately after.
    for entry in "${PHASES[@]}"; do
        label="${entry%%:*}"
        case "$PLONE_LABELS" in
            *" $label "*) continue ;;
        esac
        TO_RUN+=("$entry")
    done
    SHOW_PLONE_PROMPT="yes"
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
# Normalize to lowercase so YES/Yes/yes are all accepted
confirm=$(echo "$confirm" | tr '[:upper:]' '[:lower:]')
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
        # Normalize to lowercase so YES/Yes/yes are all accepted
        keep_going=$(echo "$keep_going" | tr '[:upper:]' '[:lower:]')
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
# Optional: continue into Plone (phases 7a/7b/7c)
# ============================================================================
# We only offer Plone if the run that just completed was a core run (default
# chain or --from inside core). --only and --from 7x skip this.
if [ "$SHOW_PLONE_PROMPT" = "yes" ]; then
    echo ""
    echo "${BOLD}${CYAN}============================================================${RESET}"
    echo "${BOLD}${CYAN}  CORE PHASES COMPLETE - PLONE (phase 7) IS OPTIONAL${RESET}"
    echo "${BOLD}${CYAN}============================================================${RESET}"
    echo ""
    echo "  Phase 7 installs Plone (the CMS used by Docent IMS) in three steps:"
    echo "    7a  Plone OS prerequisites and per-tenant directory  (~30s)"
    echo "    7b  Plone buildout (downloads + compiles, 5-15 min)"
    echo "    7c  systemd unit, Apache vhost, Let's Encrypt cert,"
    echo "         and the Plone Site itself"
    echo ""
    echo "  Skip phase 7 if this server is for mail/WordPress only and won't"
    echo "  host Plone. You can always run phase 7 later via:"
    echo "    sudo bash $0 --from 7a"
    echo ""
    while true; do
        read -r -p "Run phase 7 (Plone) now? ${BOLD}(type yes or no)${RESET}: " ans
        ans_norm=$(echo "$ans" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
        case "$ans_norm" in
            yes) PLONE_OPT_IN="yes"; break ;;
            no)  PLONE_OPT_IN="no";  break ;;
            *)   echo "${RED}Please type 'yes' or 'no' (full word).${RESET}" ;;
        esac
    done

    if [ "$PLONE_OPT_IN" = "yes" ]; then
        # Build a second TO_RUN containing the Plone phases and run them
        # through the same loop body. Any [FAIL] check in 7a/7b/7c stops
        # the chain the same way as in core.
        PLONE_TO_RUN=()
        for entry in "${PHASES[@]}"; do
            label="${entry%%:*}"
            case "$PLONE_LABELS" in
                *" $label "*) PLONE_TO_RUN+=("$entry") ;;
            esac
        done

        for entry in "${PLONE_TO_RUN[@]}"; do
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
                echo ""
                echo "  Investigate the log, fix the issue, then resume:"
                echo "    sudo bash $0 --from $label"
                exit "$rc"
            fi

            if grep -qE '^\s*\[FAIL\]' "$log_path"; then
                echo ""
                echo "${YELLOW}  WARNING: Phase $label had [FAIL] checks.${RESET}"
                echo "${YELLOW}  Review the log before continuing.${RESET}"
                echo ""
                read -r -p "Continue anyway? Type ${BOLD}yes${RESET} to proceed: " keep_going
                keep_going=$(echo "$keep_going" | tr '[:upper:]' '[:lower:]')
                if [ "$keep_going" != "yes" ]; then
                    echo "Stopped at user request. Resume with:"
                    echo "  sudo bash $0 --from $label"
                    exit 1
                fi
            fi

            echo ""
            echo "${GREEN}  ✓ Phase $label completed.${RESET}"
            TO_RUN+=("$entry")   # so the summary banner includes 7a/7b/7c
        done
    else
        echo ""
        echo "${YELLOW}  Skipping phase 7 (Plone). Run later with:${RESET}"
        echo "    sudo bash $0 --from 7a"
    fi
fi

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
# Build a comma-separated list of phase labels that ran. Displaying the
# count alone is ambiguous when --from is used (e.g. "Phases run: 5" with
# --from 5 looks like "ran phase 5 only" but actually means "ran 5 phases":
# 5, 5a, 5b, 5c, 6). Showing both removes the ambiguity.
RAN_LABELS=""
for entry in "${TO_RUN[@]}"; do
    label="${entry%%:*}"
    if [ -z "$RAN_LABELS" ]; then
        RAN_LABELS="$label"
    else
        RAN_LABELS="$RAN_LABELS, $label"
    fi
done
echo "  Phases run: ${#TO_RUN[@]} (${RAN_LABELS})"
echo "  Total time: ${DURATION_MIN}m ${DURATION_SEC}s"
echo ""

# ----------------------------------------------------------------------------
# Source tenant.local so the checklist below can reference real values
# (DOMAIN, SERVER_IP, NOTIFICATION_EMAIL, etc.) instead of placeholders
# ----------------------------------------------------------------------------
if [ -f "$TENANT_FILE" ]; then
    # shellcheck disable=SC1090
    source "$TENANT_FILE"
fi
DOMAIN="${DOMAIN:-<your-domain>}"
IP="${SERVER_IP:-<server-ip>}"
NOTIF="${NOTIFICATION_EMAIL:-<notification-email>}"

# ----------------------------------------------------------------------------
# Consolidated manual verification checklist
#
# Each phase prints its own manual-verification block during the run, but
# scrolling back through 9 phases to find them is painful. This block
# gathers the steps that actually require human action - the things the
# automated [PASS]/[FAIL] checks can't verify - into one checklist grouped
# by area. Each item is intentionally short; for full context, scroll up
# to the corresponding phase's manual-verification section.
# ----------------------------------------------------------------------------
echo "${BOLD}============================================================${RESET}"
echo "${BOLD}  MANUAL VERIFICATION CHECKLIST${RESET}"
echo "${BOLD}============================================================${RESET}"
echo ""
echo "  These are steps the install script could not verify. Walk through"
echo "  them in order. Each is independent - if one fails, fix it and"
echo "  continue, you don't have to re-run any phase."
echo ""
echo "${BOLD}  SSH / Admin login (phase 1)${RESET}"
echo "    [ ] From your laptop, SSH as wayne on port 2222:"
echo "          ssh -p 2222 wayne@${IP}"
echo "        Password is in CREDENTIALS.txt. Three wrong = 1-hour lockout."
echo "    [ ] Confirm root SSH is rejected:"
echo "          ssh -p 2222 root@${IP}    # should fail"
echo ""
echo "${BOLD}  Web / TLS (phase 2)${RESET}"
echo "    [ ] Open https://${DOMAIN}/ in browser - placeholder page, lock icon green."
echo "    [ ] Open http://${DOMAIN}/ - browser auto-redirects to https."
echo "    [ ] Open https://www.${DOMAIN}/ - works, no cert warning."
echo ""
echo "${BOLD}  Mail server (phase 4)${RESET}"
echo "    [ ] Phase 4 generated a complete BIND zone file you can import - see"
echo "        /root/server_setup/dns/   (run: sudo ls /root/server_setup/dns/)"
echo "        Or scroll up to phase 4's 'DNS RECORDS TO ADD AT IONOS' block."
echo "        Records to add: MX, SPF (TXT), DKIM (TXT), DMARC (TXT)."
echo "    [ ] Submit Kamatera support ticket asking them to add a PTR record:"
echo "          ${IP} -> mail.${DOMAIN}"
echo "        Without PTR, outbound mail to Gmail/Outlook lands in spam."
echo "    [ ] After PTR is approved, test root alias delivery:"
echo "          echo 'system test' | mail -s 'system test' root"
echo "        Mail should arrive at ${NOTIF}."
echo ""
echo "${BOLD}  Webmail (phase 5/5a/5b/5c)${RESET}"
echo "    [ ] Open https://${DOMAIN}/mail/ - login page renders with Docent logo."
echo "    [ ] Log in as test@${DOMAIN} - password from CREDENTIALS.txt."
echo "    [ ] Send a test email to your own external account."
echo "    [ ] Compose: try the AI Composer (xai plugin) if XAI_API_KEY was set."
echo ""
echo "${BOLD}  WordPress (phase 6)${RESET}"
echo "    [ ] WordPress site is up at https://${DOMAIN}/ (auto-installed via wp-cli, admin login in CREDENTIALS.txt)."
echo ""
echo "${BOLD}  Cleanup (do AFTER all of the above succeed)${RESET}"
echo "    [ ] Save CREDENTIALS.txt to your password manager."
echo "    [ ] Delete the on-disk credential files:"
echo "          rm $REPO_ROOT/CREDENTIALS.txt"
echo "          rm $REPO_ROOT/QUICK-REFERENCE.txt"
echo ""
echo "  See QUICK-REFERENCE.txt for day-to-day commands and recovery procedures."
echo ""
