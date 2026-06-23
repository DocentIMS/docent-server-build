#!/bin/bash
# ============================================================================
# run-phases.sh - Chain all build phases automatically.
#
# Use only AFTER phase 0 has been run (so tenant.local and secrets.local
# exist). This script runs the core phases 1 -> 2 -> 3 -> 4 -> post-dkim
# -> 5 -> 5a -> 5b -> 5c -> 6 in order, stopping at the first failure.
# (post-dkim publishes the DKIM DNS record in Hetzner DNS after phase 4
# generates the key.) After phase 6 completes, the script prompts whether
# to continue with the Plone phases 7a -> 7b -> 7c (typed yes or no, no
# default), then prompts separately whether to install the Plone add-on
# products (phase 7d).
#
# All phases are idempotent, so it's safe to re-run this script after a
# reboot or after fixing whatever caused a failure.
#
# Usage:
#   sudo bash run-phases.sh                # run 1-6, then prompt for 7a/b/c and 7d
#   sudo bash run-phases.sh --from 4       # start from phase 4, prompt for 7
#   sudo bash run-phases.sh --from 7a      # run 7a, 7b, 7c, 7d (no prompt)
#   sudo bash run-phases.sh --only 4       # run only phase 4 (no prompt)
#   sudo bash run-phases.sh --only 7d      # run only phase 7d (no prompt)
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

# --------------------------------------------------------------------------
# action_cmd - print a command the OPERATOR must type inside an unmistakable
# block, so "your turn" steps never blend into the explanation text around
# them. Each argument is one command line.
# --------------------------------------------------------------------------
action_cmd() {
    echo ""
    echo "${BOLD}${GREEN}════════════════ 👉 YOUR TURN — run this ════════════════${RESET}"
    for _c in "$@"; do echo "${BOLD}${GREEN}    ${_c}${RESET}"; done
    echo "${BOLD}${GREEN}═════════════════════════════════════════════════════════${RESET}"
    echo ""
}

# --------------------------------------------------------------------------
# answer_box - print a yellow "the script is waiting on YOU" banner before a
# read prompt, so questions never blend into the explanation. $1 = question.
# --------------------------------------------------------------------------
answer_box() {
    echo ""
    echo "${BOLD}${YELLOW}──────────────────── ❓ ANSWER ────────────────────${RESET}"
    echo "${BOLD}${YELLOW}  $1${RESET}"
}

# ============================================================================
# Banner - printed first, before any pre-flight output, so the script
# always identifies itself as the first thing on screen.
# ============================================================================
echo ""
echo "${BOLD}${CYAN}============================================================${RESET}"
echo "${BOLD}${CYAN}  RUN-PHASES - automated phase chain${RESET}"
echo "${BOLD}${CYAN}  Started: $(date "+%Y-%m-%d %H:%M:%S %Z")${RESET}"
echo "${BOLD}${CYAN}============================================================${RESET}"
echo ""

# ============================================================================
# DEFAULTS
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
TENANT_FILE="$REPO_ROOT/tenant.local"
SECRETS_FILE="$REPO_ROOT/secrets.local"

# Ordered list of phases. Each entry is "label:script-filename".
# Ordered list of phases. Each entry is "label:script-filename".
# The Plone phases (7a/7b/7c/7d) are part of this array so that --from and
# --only can target them, but the default run stops after CORE_LAST_LABEL
# and prompts the user whether to continue.
PHASES=(
    "1:phase1.sh"
    "2:phase2.sh"
    "3:phase3.sh"
    "4:phase4.sh"
    "4b:phase4b-smtp-relay.sh"
    "post-dkim:phase-post-hetzner-dkim.sh"
    "5:phase5.sh"
    "5a:phase5a-rc-plus.sh"
    "5b:phase5b-globaladdressbook.sh"
    "5c:phase5c-email-ai.sh"
    "6:phase6.sh"
    "help:phase-help.sh"
    "7a:phase7a-plone-prereqs.sh"
    "7b:phase7b-plone-buildout.sh"
    "7c:phase7c-plone-frontend.sh"
    "7d:phase7d-plone-products.sh"
    "7e:phase7e-plone-activate.sh"
)
# After this label completes in the default run, the script prompts before
# running anything past it. (Phases past this point are the Plone install,
# which is optional and slow.)
CORE_LAST_LABEL="6"

# Set of phase labels that belong to the Plone chain. Used to format the
# prompt and to detect whether an explicit --from or --only is targeting
# Plone (so we don't prompt redundantly).
PLONE_LABELS=" 7a 7b 7c 7d "

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
# Pre-flight: REFUSE to run on the build/control (template) host
# ============================================================================
# These phases provision a TARGET server and will harden/convert whatever box
# they run on. They must NEVER run on the control box (the machine you run
# phase-pre-hetzner.sh from). Two guards:
#   1) /etc/docent-control-host sentinel  -> create it once on the control box
#   2) automatic: this machine's IP must match SERVER_IP from tenant.local
if [ -f /etc/docent-control-host ]; then
    echo "${RED}REFUSING: this is the docent build/control host"
    echo "(marker /etc/docent-control-host is present).${RESET}"
    echo "Provisioning phases must run ON THE TARGET server, not here."
    echo "Hand off: scp the files to root@<target>, ssh in, run bootstrap there."
    exit 1
fi
if [ -f "$TENANT_FILE" ]; then . "$TENANT_FILE"; fi
if [ -n "${SERVER_IP:-}" ]; then
    _MY_IPS="$(hostname -I 2>/dev/null) $(curl -s --max-time 5 https://ifconfig.me 2>/dev/null)"
    if [ -n "$(printf '%s' "$_MY_IPS" | tr -d '[:space:]')" ]; then
        case " $_MY_IPS " in
            *" $SERVER_IP "*) : ;;   # this machine IS the target - good
            *)
                echo "${RED}REFUSING: this machine's IP is not SERVER_IP ($SERVER_IP)"
                echo "from tenant.local.${RESET}"
                echo "These phases must run ON THE TARGET ($SERVER_IP), not on this box."
                echo "If you are on the build/control box, hand off to the target and run there."
                exit 1
                ;;
        esac
    fi
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
        echo "Valid phase labels: 1 2 3 4 4b post-dkim 5 5a 5b 5c 6 help 7a 7b 7c 7d 7e"
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
        echo "Valid phase labels: 1 2 3 4 4b post-dkim 5 5a 5b 5c 6 help 7a 7b 7c 7d 7e"
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
# Phases-to-run summary + confirmation
# ============================================================================
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
answer_box "Start the build now?"
read -r -p "${BOLD}${YELLOW}❓ type yes to start: ${RESET}" confirm
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
        action_cmd "sudo bash $0 --from $label"
        exit "$rc"
    fi

    # Heuristic: if the log says "FAIL" in the verification block, the phase
    # technically exited 0 but had failing checks. Surface that loudly.
    if grep -qE '^\s*\[FAIL\]' "$log_path"; then
        echo ""
        echo "${YELLOW}  WARNING: Phase $label had [FAIL] checks in its verification block.${RESET}"
        echo "${YELLOW}  Review the log before continuing.${RESET}"
        echo ""
        answer_box "Continue anyway?"
        read -r -p "${BOLD}${YELLOW}❓ type yes to proceed: ${RESET}" keep_going
        # Normalize to lowercase so YES/Yes/yes are all accepted
        keep_going=$(echo "$keep_going" | tr '[:upper:]' '[:lower:]')
        if [ "$keep_going" != "yes" ]; then
            echo "Stopped at user request. Resume with:"
            action_cmd "sudo bash $0 --from $label"
            exit 1
        fi
    fi

    echo ""
    echo "${GREEN}  ✓ Phase $label completed.${RESET}"
done

# ============================================================================
# Optional: continue into Plone (phases 7a/7b/7c), then add-on products (7d)
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
    action_cmd "sudo bash $0 --from 7a"
    echo ""
    while true; do
        answer_box "Run phase 7 (Plone) now?"
        read -r -p "${BOLD}${YELLOW}❓ type yes or no: ${RESET}" ans
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
            # 7d (add-on products) has its own separate prompt below, and 7e
            # (activation) chains off 7d, so both are deliberately excluded
            # from this 7a/7b/7c auto-run list.
            [ "$label" = "7d" ] && continue
            [ "$label" = "7e" ] && continue
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
                action_cmd "sudo bash $0 --from $label"
                exit "$rc"
            fi

            if grep -qE '^\s*\[FAIL\]' "$log_path"; then
                echo ""
                echo "${YELLOW}  WARNING: Phase $label had [FAIL] checks.${RESET}"
                echo "${YELLOW}  Review the log before continuing.${RESET}"
                echo ""
                answer_box "Continue anyway?"
                read -r -p "${BOLD}${YELLOW}❓ type yes to proceed: ${RESET}" keep_going
                keep_going=$(echo "$keep_going" | tr '[:upper:]' '[:lower:]')
                if [ "$keep_going" != "yes" ]; then
                    echo "Stopped at user request. Resume with:"
                    action_cmd "sudo bash $0 --from $label"
                    exit 1
                fi
            fi

            echo ""
            echo "${GREEN}  ✓ Phase $label completed.${RESET}"
            TO_RUN+=("$entry")   # so the summary banner includes 7a/7b/7c
        done

        # --------------------------------------------------------------
        # Optional: phase 7d - install the Plone add-on products.
        # Offered as its own yes/no prompt, only after 7a/7b/7c succeeded.
        # --------------------------------------------------------------
        echo ""
        echo "${BOLD}${CYAN}============================================================${RESET}"
        echo "${BOLD}${CYAN}  PLONE ADD-ON PRODUCTS (phase 7d) IS OPTIONAL${RESET}"
        echo "${BOLD}${CYAN}============================================================${RESET}"
        echo ""
        echo "  Phase 7d installs the Docent add-on products onto the Plone"
        echo "  site you just built. It downloads the product list (products.cfg)"
        echo "  from the docent-plone-addons GitHub repo and builds those add-ons"
        echo "  in. Plone itself is not reinstalled. (~3-8 min.)"
        echo ""
        echo "  You can always run it later via:  sudo bash $0 --only 7d"
        echo ""
        while true; do
            answer_box "Install the Plone add-on products (from the GitHub buildout)?"
            read -r -p "${BOLD}${YELLOW}❓ type yes or no: ${RESET}" ans7d
            ans7d_norm=$(echo "$ans7d" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
            case "$ans7d_norm" in
                yes) PRODUCTS_OPT_IN="yes"; break ;;
                no)  PRODUCTS_OPT_IN="no";  break ;;
                *)   echo "${RED}Please type 'yes' or 'no' (full word).${RESET}" ;;
            esac
        done

        if [ "$PRODUCTS_OPT_IN" = "yes" ]; then
            label="7d"
            script="phase7d-plone-products.sh"
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
                action_cmd "sudo bash $0 --only $label"
                exit "$rc"
            fi

            if grep -qE '^\s*\[FAIL\]' "$log_path"; then
                echo ""
                echo "${YELLOW}  WARNING: Phase $label had [FAIL] checks.${RESET}"
                echo "${YELLOW}  Review the log before continuing.${RESET}"
                echo ""
                answer_box "Continue anyway?"
                read -r -p "${BOLD}${YELLOW}❓ type yes to proceed: ${RESET}" keep_going
                keep_going=$(echo "$keep_going" | tr '[:upper:]' '[:lower:]')
                if [ "$keep_going" != "yes" ]; then
                    echo "Stopped at user request. Resume with:"
                    action_cmd "sudo bash $0 --only $label"
                    exit 1
                fi
            fi

            echo ""
            echo "${GREEN}  ✓ Phase $label completed.${RESET}"
            TO_RUN+=("7d:phase7d-plone-products.sh")   # include 7d in the summary

            # ----------------------------------------------------------
            # Phase 7e - activate the add-ons in the site, in dependency
            # order. Chains automatically off a successful 7d (activation
            # is the completion of "install products"). Run later on its
            # own with: sudo bash $0 --only 7e
            # ----------------------------------------------------------
            label="7e"
            script="phase7e-plone-activate.sh"
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
                action_cmd "sudo bash $0 --only $label"
                exit "$rc"
            fi

            if grep -qE '^\s*\[FAIL\]' "$log_path"; then
                echo ""
                echo "${YELLOW}  WARNING: Phase $label had [FAIL] checks.${RESET}"
                echo "${YELLOW}  Review the log before continuing.${RESET}"
                echo ""
                answer_box "Continue anyway?"
                read -r -p "${BOLD}${YELLOW}❓ type yes to proceed: ${RESET}" keep_going
                keep_going=$(echo "$keep_going" | tr '[:upper:]' '[:lower:]')
                if [ "$keep_going" != "yes" ]; then
                    echo "Stopped at user request. Resume with:"
                    action_cmd "sudo bash $0 --only $label"
                    exit 1
                fi
            fi

            echo ""
            echo "${GREEN}  ✓ Phase $label completed.${RESET}"
            TO_RUN+=("7e:phase7e-plone-activate.sh")   # include 7e in the summary
        else
            echo ""
            echo "${YELLOW}  Skipping phase 7d (Plone add-on products). Run later with:${RESET}"
            action_cmd "sudo bash $0 --only 7d"
        fi
    else
        echo ""
        echo "${YELLOW}  Skipping phase 7 (Plone). Run later with:${RESET}"
        action_cmd "sudo bash $0 --from 7a"
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
# Phase 8 banner: UptimeRobot monitoring runs on docenttemplate (not on the
# client server). Placed above the manual verification checklist so the next
# concrete action stands out before the longer post-build to-do list.
# ----------------------------------------------------------------------------
echo ""
echo "${BOLD}${YELLOW}============================================================${RESET}"
echo "${BOLD}${YELLOW}  PHASE 8 — CREATE MONITORS ON UPTIMEROBOT${RESET}"
echo "${BOLD}${YELLOW}============================================================${RESET}"
echo ""
echo "  This process creates these monitors:"
echo ""
echo "      wordpress   ${DOMAIN}"
echo "      plone       ${DOMAIN}"
echo "      mail        ${DOMAIN}"
echo "      smtp        ${DOMAIN}"
echo ""
echo "  To proceed, go to the template server and run:"
echo ""
echo "    ${BOLD}cd ~/server-build/scripts && ./phase8-monitoring.sh ${DOMAIN}${RESET}"
echo ""

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
echo "    [ ] DNS records (MX, SPF, DKIM, DMARC, CAA) are created automatically"
echo "        in Hetzner DNS by phase-pre-hetzner.sh and the post-dkim phase."
echo "        Nothing to add by hand - just confirm them in the"
echo "        Hetzner Cloud Console -> DNS -> ${DOMAIN}."
echo "    [ ] Return to Hetzner and manually activate a PTR (reverse DNS) record:"
echo "          ${IP} -> mail.${DOMAIN}"
echo "        Hetzner Cloud Console -> select this server -> set the reverse"
echo "        DNS on the IPv4 address."
echo "    [ ] After PTR is set, test email deliver, including to docentims@gmail.com"
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
echo "${BOLD}  UptimeRobot monitoring (run on docenttemplate, NOT here)${RESET}"
echo "    [ ] On the template server, run:"
echo "          ${BOLD}cd ~/server-build/scripts && ./phase8-monitoring.sh ${DOMAIN}${RESET}"
echo "        Creates 4 monitors (WordPress, Plone, Roundcube, SMTP)"
echo "        wired to email + SMS alerts. Skip if ${DOMAIN} is in monitoring-exclusions.txt."
echo ""

echo "${BOLD}  Cleanup (do AFTER all of the above succeed)${RESET}"
echo "    [ ] Save CREDENTIALS.txt to your password manager."
echo "    [ ] Do NOT delete CREDENTIALS.txt or QUICK-REFERENCE.txt yet."
echo "          The Plone phases (7b/7c/7d) read PLONE_ADMIN_PW from"
echo "          CREDENTIALS.txt. Keep both files on the server until the"
echo "          Plone install is finished and verified. Only then is it"
echo "          safe to remove them."
echo ""
echo "  See QUICK-REFERENCE.txt for day-to-day commands and recovery procedures."
echo ""

# ----------------------------------------------------------------------------
# Final: print the full credentials list. By this point CREDENTIALS.txt is
# complete - phase 7b has appended the Plone admin password - so this is the
# single copy-and-save moment (phase 0 deliberately no longer dumps the list).
# ----------------------------------------------------------------------------
CRED_FILE="$REPO_ROOT/CREDENTIALS.txt"
if [ -f "$CRED_FILE" ]; then
    echo ""
    echo "${BOLD}${YELLOW}============================================================${RESET}"
    echo "${BOLD}${YELLOW}  CREDENTIALS - SAVE TO PASSWORD MANAGER NOW${RESET}"
    echo "${BOLD}${YELLOW}============================================================${RESET}"
    echo ""
    cat "$CRED_FILE"
    echo ""
fi
