#!/bin/bash
# ============================================================================
# bootstrap.sh - Step Zero entry point for a fresh Docent server build.
#
# Run this on a freshly-provisioned Hetzner Cloud server (Ubuntu 26.04 LTS),
# as root on the default SSH port 22. phase-pre-hetzner.sh creates that
# server with your SSH key attached and leaves a clean root@22 baseline -
# it does NOT create users or change the SSH port (phase 1 does that).
#
# bootstrap.sh walks the SSH-key-to-GitHub flow, clones the build repo,
# moves any phase-pre-hetzner handoff files (tenant.local, hetzner.local,
# org-secrets.local) sitting beside it into the repo, then chains into phase 0.
#
# How to get this script onto a new server:
#   On the docenttemplate (build) server, from the repo root, copy
#   bootstrap.sh together with the three handoff files phase-pre-hetzner
#   produced:
#     scp scripts/bootstrap.sh tenant.local hetzner.local org-secrets.local \
#         root@<new-server-ip>:/root/
#
# Then SSH into the new server and run:
#   ssh root@<new-server-ip>
#   bash /root/bootstrap.sh
#
# This script is idempotent - safe to re-run if something goes wrong.
# ============================================================================

set -e

# ============================================================================
# COSMETICS
# ============================================================================
# Use $'\e[...]' bash ANSI-C quoting to get REAL escape characters.
# Plain "\033[..." (literal) only renders correctly when used with `echo -e`,
# and we use plain `echo` everywhere - so the literal form would print the
# raw \033 codes to the screen instead of changing colors.
if [ -t 1 ]; then
    RESET=$'\e[0m'
    BOLD=$'\e[1m'
    RED=$'\e[31m'
    GREEN=$'\e[32m'
    YELLOW=$'\e[33m'
    CYAN=$'\e[36m'
else
    RESET=""
    BOLD=""
    RED=""
    GREEN=""
    YELLOW=""
    CYAN=""
fi

step() { echo ""; echo "${BOLD}=== $1 ===${RESET}"; }

# ============================================================================
# DEFAULTS
# ============================================================================
REPO_URL="git@github.com:DocentIMS/docent-server-build.git"
REPO_DIR="/root/server-build"
SSH_KEY_PATH="/root/.ssh/id_ed25519"
SSH_KEY_COMMENT="$(hostname)"

# ============================================================================
# Pre-flight: must be root
# ============================================================================
if [ "$(id -u)" -ne 0 ]; then
    echo "${RED}ERROR: bootstrap.sh must be run as root.${RESET}"
    echo "Try:  sudo bash $0"
    exit 1
fi

# ============================================================================
# Pre-flight: REFUSE to run on the build/control (template) host
# ============================================================================
# bootstrap.sh provisions a TARGET server. Never run it on the control box
# (where phase-pre-hetzner.sh runs) or it will convert/harden it. The control
# box is marked with /etc/docent-control-host.
if [ -f /etc/docent-control-host ]; then
    echo "${RED}REFUSING: this is the docent build/control host"
    echo "(marker /etc/docent-control-host is present).${RESET}"
    echo "bootstrap.sh runs on the NEW target server - scp it there and run it on that box."
    exit 1
fi

# answer_box - yellow banner before a read prompt so questions stand out.
answer_box() {
    echo ""
    echo "${BOLD}${YELLOW}──────────────────── ❓ ANSWER ────────────────────${RESET}"
    echo "${BOLD}${YELLOW}  $1${RESET}"
}

echo ""
echo "${BOLD}${CYAN}============================================================${RESET}"
echo "${BOLD}${CYAN}  DOCENT SERVER BUILD${RESET}"
echo "${BOLD}${CYAN}============================================================${RESET}"
echo ""
echo "  ${BOLD}Tip:${RESET} you can safely abort with Ctrl-C any time before"
echo "  phase 1 finishes. Nothing on the system changes irreversibly"
echo "  until then."
echo ""

# ============================================================================
# Step 1: OS sanity check
# ============================================================================
step "Step 1: OS sanity check"

if [ ! -f /etc/os-release ]; then
    echo "${RED}ERROR: /etc/os-release missing - cannot verify OS.${RESET}"
    exit 1
fi
. /etc/os-release

if [ "$ID" != "ubuntu" ] || [ "$VERSION_ID" != "26.04" ]; then
    echo "${RED}ERROR: This server is not Ubuntu 26.04 LTS.${RESET}"
    echo "  Detected: $PRETTY_NAME"
    echo ""
    echo "  The Docent server build requires Ubuntu 26.04 LTS for Dovecot 2.4"
    echo "  and a few other version-specific things."
    echo ""
    echo "  Re-provision the server in Hetzner Cloud with the correct image."
    exit 1
fi
echo "  ✓ OS verified: $PRETTY_NAME"

# ============================================================================
# Step 2: Confirm context
# ============================================================================
step "Step 2: Confirm this is the right server"

CURRENT_HOSTNAME="$(hostname)"
CURRENT_IP="$(hostname -I | awk '{print $1}')"

echo ""
echo "  Hostname: ${CYAN}${CURRENT_HOSTNAME}${RESET}"
echo "  IP:       ${CYAN}${CURRENT_IP}${RESET}"
echo "  OS:       ${CYAN}${PRETTY_NAME}${RESET}"
echo ""
answer_box "Is this the server you intend to build?"
read -r -p "${BOLD}${YELLOW}❓ type yes to continue: ${RESET}" confirm
if [ "$confirm" != "yes" ]; then
    echo "${YELLOW}Aborted. Run bootstrap.sh again on the correct server.${RESET}"
    exit 1
fi

# ============================================================================
# Step 3: SSH key for GitHub
# ============================================================================
step "Step 3: SSH key for GitHub"

mkdir -p /root/.ssh
chmod 700 /root/.ssh

if [ -f "$SSH_KEY_PATH" ]; then
    echo "  ✓ SSH key already exists at $SSH_KEY_PATH (reusing)"
else
    ssh-keygen -t ed25519 -C "$SSH_KEY_COMMENT" -f "$SSH_KEY_PATH" -N "" >/dev/null
    echo "  ✓ Generated new ed25519 SSH key"
fi

PUBKEY="$(cat "${SSH_KEY_PATH}.pub")"

echo ""
echo "${BOLD}${YELLOW}=============================================================${RESET}"
echo "${BOLD}${YELLOW}  ADD THIS PUBLIC KEY TO GITHUB${RESET}"
echo "${BOLD}${YELLOW}=============================================================${RESET}"
echo ""
echo "  Copy the line below (the entire 'ssh-ed25519 ...' line):"
echo ""
echo "${CYAN}${PUBKEY}${RESET}"
echo ""
echo "  Then in your browser:"
echo "    1. Go to: ${BOLD}https://github.com/settings/keys${RESET}"
echo "    2. Delete any OLD keys named '${SSH_KEY_COMMENT}' (stale from prior servers)"
echo "    3. Click ${BOLD}New SSH key${RESET}"
echo "    4. Title: ${SSH_KEY_COMMENT}"
echo "    5. ${BOLD}Paste the key${RESET} into the Key field. Copy"
echo "       ${BOLD}everything from 'ssh-ed25519' through '${SSH_KEY_COMMENT}'${RESET}"
echo "       on the cyan line above - no extra characters before or after."
echo "    6. Click ${BOLD}Add SSH key${RESET}"
echo ""
echo "${BOLD}${YELLOW}=============================================================${RESET}"
echo ""
# Explicit yes/no after key paste - too easy to hit Enter without actually
# pasting and saving the key in GitHub.
while true; do
    answer_box "Have you added the key to GitHub?"
    read -r -p "${BOLD}${YELLOW}❓ type yes or no: ${RESET}" ans
    case "$(echo "$ans" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
        yes) break ;;
        no)  echo "${YELLOW}Take your time - re-run bootstrap.sh after adding the key.${RESET}"
             exit 0 ;;
        *)   echo "${RED}Please type 'yes' or 'no' (full word).${RESET}" ;;
    esac
done

# ============================================================================
# Step 4: Verify GitHub auth (with retries)
# ============================================================================
step "Step 4: Verify GitHub authentication"

# Pre-accept GitHub's host key so the user doesn't get an interactive prompt.
# Only add it if it isn't already known, so re-runs don't pile up duplicates.
if ! ssh-keygen -F github.com -f /root/.ssh/known_hosts >/dev/null 2>&1; then
    ssh-keyscan -t ed25519 github.com >> /root/.ssh/known_hosts 2>/dev/null || true
fi

attempt=1
max_attempts=3
while [ "$attempt" -le "$max_attempts" ]; do
    set +e
    output=$(ssh -T -o BatchMode=yes -o StrictHostKeyChecking=accept-new git@github.com 2>&1)
    rc=$?
    set -e

    # GitHub's "Hi <user>! You've successfully authenticated..." message exits 1
    # by design (no shell access), but the message itself confirms success.
    if echo "$output" | grep -q "successfully authenticated"; then
        github_user="$(echo "$output" | sed -n 's/^Hi \([^!]*\)!.*/\1/p')"
        echo "  ✓ Authenticated to GitHub as: ${CYAN}${github_user}${RESET}"
        break
    fi

    echo ""
    echo "${RED}  GitHub authentication failed (attempt ${attempt}/${max_attempts}).${RESET}"
    echo "  GitHub said:"
    echo "  ----------"
    echo "$output" | sed 's/^/    /'
    echo "  ----------"
    echo ""
    echo "  Common causes:"
    echo "    - Key wasn't pasted into GitHub yet, or pasted with extra whitespace"
    echo "    - Key was added to a DIFFERENT GitHub account than DocentIMS"
    echo "    - DNS resolving github.com is broken"
    echo ""
    if [ "$attempt" -lt "$max_attempts" ]; then
        answer_box "Try again (after fixing the issue)?"
        read -r -p "${BOLD}${YELLOW}❓ type yes to retry: ${RESET}" retry
        if [ "$retry" != "yes" ]; then
            echo "${YELLOW}Aborted. Re-run bootstrap.sh when ready.${RESET}"
            exit 1
        fi
    fi
    attempt=$((attempt + 1))
done

if [ "$attempt" -gt "$max_attempts" ]; then
    echo ""
    echo "${RED}Giving up after $max_attempts attempts. Investigate manually:${RESET}"
    echo "    ssh -T git@github.com"
    exit 1
fi

# ============================================================================
# Step 5: Clone repo (or pull if exists)
# ============================================================================
step "Step 5: Clone build repo"

if [ -d "$REPO_DIR/.git" ]; then
    echo "  Repo already exists at $REPO_DIR - refreshing to latest..."
    if git -C "$REPO_DIR" pull --ff-only; then
        echo "  ✓ Refreshed $REPO_DIR to latest commit"
    else
        echo "${RED}  ERROR: git pull failed (uncommitted local changes?).${RESET}"
        echo "  Resolve manually then re-run, or delete $REPO_DIR and re-run."
        exit 1
    fi
elif [ -d "$REPO_DIR" ]; then
    echo "${RED}  ERROR: $REPO_DIR exists but isn't a git repo.${RESET}"
    echo "  Move or delete it, then re-run bootstrap.sh:"
    echo "    mv $REPO_DIR ${REPO_DIR}.bak"
    exit 1
else
    git clone "$REPO_URL" "$REPO_DIR"
    echo "  ✓ Cloned $REPO_URL to $REPO_DIR"
fi

echo ""
echo "  Latest commit:"
git -C "$REPO_DIR" log --oneline -1 | sed 's/^/    /'

# ============================================================================
# Step 6: Stage phase-pre-hetzner handoff files
# ============================================================================
# phase-pre-hetzner.sh produces tenant.local (a stub with DOMAIN + SERVER_IP),
# hetzner.local (Hetzner API token + zone IDs) and org-secrets.local (the RC+
# license key). They are scp'd to this server alongside bootstrap.sh. phase 0
# and the phase scripts read them from the repo root, so move any that are
# sitting next to this script into the repo. A purely manual build has none
# of these, which is fine - phase 0 simply prompts for the values instead.
step "Step 6: Stage handoff files"

BOOTSTRAP_DIR="$(cd "$(dirname "$0")" && pwd)"
staged=0
for handoff in tenant.local hetzner.local org-secrets.local; do
    src="$BOOTSTRAP_DIR/$handoff"
    dst="$REPO_DIR/$handoff"
    if [ -f "$src" ] && [ ! "$src" -ef "$dst" ]; then
        mv "$src" "$dst"
        echo "  ✓ moved $handoff into $REPO_DIR"
        staged=$((staged + 1))
    fi
done
if [ "$staged" -eq 0 ]; then
    echo "  - no handoff files beside bootstrap.sh (manual build - phase 0 will prompt)"
fi

# ============================================================================
# Step 7: Hand off to phase 0
# ============================================================================
step "Step 7: Bootstrap complete - launching phase 0"

echo ""
echo "${GREEN}  Bootstrap finished successfully. Launching phase 0...${RESET}"
echo ""

exec bash "$REPO_DIR/scripts/phase0-bootstrap.sh"
