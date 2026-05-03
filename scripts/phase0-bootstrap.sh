#!/bin/bash
#
# phase0-bootstrap.sh - Phase 0: Interactive bootstrap for tenant configuration
#
# Collects all per-tenant configuration via interactive prompts, auto-derives
# values that follow the standard convention, generates strong random passwords,
# and writes three files:
#
#   - tenant.local      non-secret per-tenant config (domain, usernames, etc.)
#   - secrets.local     passwords and API keys (gitignored, machine-readable)
#   - CREDENTIALS.txt   human-readable summary for the user (gitignored)
#
# Each subsequent phase script (1, 2, 3, 4, 5, 5b, 5c, 6) sources the .local
# files at the top, falling back to its existing hardcoded defaults if either
# file is missing (so old behavior is preserved when phase0 is not used).
#
# After this script completes, save CREDENTIALS.txt to your password manager,
# then proceed to: sudo bash scripts/phase1.sh

set -u

# ============================================================================
# PATHS
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
TENANT_FILE="$REPO_ROOT/tenant.local"
SECRETS_FILE="$REPO_ROOT/secrets.local"
CREDENTIALS_FILE="$REPO_ROOT/CREDENTIALS.txt"

# ============================================================================
# COLORS (only if terminal supports them)
# ============================================================================
if [ -t 1 ]; then
    BOLD=$'\e[1m'
    DIM=$'\e[2m'
    YELLOW=$'\e[1;33m'
    CYAN=$'\e[1;36m'
    GREEN=$'\e[1;32m'
    RED=$'\e[1;31m'
    RESET=$'\e[0m'
else
    BOLD=""; DIM=""; YELLOW=""; CYAN=""; GREEN=""; RED=""; RESET=""
fi

# ============================================================================
# HELPERS
# ============================================================================

gen_pw() {
    openssl rand -base64 "$1" | tr -d '/+=' | head -c "$1"
}

ask() {
    local prompt="$1"
    local default="${2:-}"
    local response
    if [ -n "$default" ]; then
        read -r -p "${YELLOW}${prompt}${RESET} [${CYAN}${default}${RESET}]: " response
        echo "${response:-$default}"
    else
        read -r -p "${YELLOW}${prompt}${RESET}: " response
        echo "$response"
    fi
}

ask_required() {
    local prompt="$1"
    local default="${2:-}"
    local response=""
    while [ -z "$response" ]; do
        response=$(ask "$prompt" "$default")
        if [ -z "$response" ]; then
            echo "${RED}This field is required.${RESET}"
        fi
    done
    echo "$response"
}

step() {
    echo ""
    echo "${BOLD}=== $1 ===${RESET}"
}

# ============================================================================
# WELCOME / OVERVIEW
# ============================================================================
clear
cat <<EOF
${BOLD}=============================================================
  PHASE 0 - SERVER BUILD BOOTSTRAP
=============================================================${RESET}

This script collects everything needed to build a new server.

You will be asked for ${BOLD}10 things${RESET}. For each item with a default,
just press Enter to accept; otherwise type a value.

After this completes, three files will be created in this repo:
  ${CYAN}tenant.local${RESET}     - non-secret tenant config (used by scripts)
  ${CYAN}secrets.local${RESET}    - passwords (used by scripts)
  ${CYAN}CREDENTIALS.txt${RESET}  - human-readable credentials summary

You can safely abort with Ctrl+C at any time before the final
write step. Nothing on the system changes until you run phase 1.

Press Enter to begin, or Ctrl+C to abort.
EOF
read -r

# ============================================================================
# CHECK FOR EXISTING FILES
# ============================================================================
if [ -f "$TENANT_FILE" ] || [ -f "$SECRETS_FILE" ] || [ -f "$CREDENTIALS_FILE" ]; then
    echo ""
    echo "${RED}WARNING:${RESET} Existing config files found:"
    [ -f "$TENANT_FILE" ] && echo "  $TENANT_FILE"
    [ -f "$SECRETS_FILE" ] && echo "  $SECRETS_FILE"
    [ -f "$CREDENTIALS_FILE" ] && echo "  $CREDENTIALS_FILE"
    echo ""
    read -r -p "Overwrite them? Type ${BOLD}yes${RESET} to continue: " confirm
    if [ "$confirm" != "yes" ]; then
        echo "Aborted."
        exit 1
    fi
fi

# ============================================================================
# COLLECT USER INPUT
# ============================================================================
step "Tenant identity"

PRIMARY_DOMAIN=$(ask_required "Primary domain (e.g., acmemuseum.com)")
SERVER_IP=$(ask_required "Server public IPv4 address")

step "Purpose"

echo "One-line description of what this server is for."
echo "This will appear at the top of CREDENTIALS.txt as a reminder."
echo ""
SERVER_PURPOSE=$(ask_required "Purpose")

step "Admin accounts"

echo "Two admin users will be created. Both have full sudo."
echo "  - Your personal account (default 'wayne')"
echo "  - A shareable account (default 'admin')"
echo ""

ADMIN_USER=$(ask "Personal admin username" "wayne")
SHARED_ADMIN_USER=$(ask "Shareable admin username" "admin")
SSH_PORT=$(ask "SSH port" "2222")
TIMEZONE=$(ask "Timezone" "America/Los_Angeles")

step "Notification email"

echo "This single email gets used for: Let's Encrypt cert renewal,"
echo "DMARC reports, CAA reports, and WordPress admin contact."
echo ""
NOTIFICATION_EMAIL=$(ask_required "Notification email")

step "Mail"

echo "This is the test email address. You'll use it to verify that mail"
echo "works. This test email is autocreated as:  test@${PRIMARY_DOMAIN}"

TEST_MAILBOX_LOCAL="test"

step "Roundcube Plus"

echo "${BOLD}REQUIRED:${RESET} Roundcube Plus license key (purchased from roundcubeplus.com)"
echo "Format: RCP-xxxxxxxxxxxxxxxx"
echo ""
RC_PLUS_LICENSE_KEY=$(ask_required "License key")

step "AI Assistant (optional)"

echo "Optional: API key for the xai (AI Assistant) Roundcube plugin."
echo "Press Enter to skip if you don't want AI features."
echo ""
XAI_API_KEY=$(ask "AI API key (e.g., sk-...)" "")

# ============================================================================
# AUTO-DERIVE
# ============================================================================
step "Auto-deriving values from primary domain"

DOMAIN_STEM="${PRIMARY_DOMAIN%%.*}"
HOSTNAME_SHORT="$DOMAIN_STEM"
WP_DB_NAME="wordpress_${DOMAIN_STEM}"
WP_DB_USER="wp_$(echo "$DOMAIN_STEM" | head -c 2)_user"
TEST_MAILBOX="${TEST_MAILBOX_LOCAL}@${PRIMARY_DOMAIN}"

cat <<EOF

${DIM}The following are auto-derived from your primary domain:${RESET}
  Hostname (short):       ${CYAN}${HOSTNAME_SHORT}${RESET}
  Mail hostname:          ${CYAN}mail.${PRIMARY_DOMAIN}${RESET}
  WWW alias:              ${CYAN}www.${PRIMARY_DOMAIN}${RESET}
  Test mailbox:           ${CYAN}${TEST_MAILBOX}${RESET}
  WordPress database:     ${CYAN}${WP_DB_NAME}${RESET}
  WordPress DB user:      ${CYAN}${WP_DB_USER}${RESET}

EOF

# ============================================================================
# GENERATE SECRETS
# ============================================================================
step "Generating strong random passwords"

ADMIN_PW=$(gen_pw 22)
SHARED_ADMIN_PW=$(gen_pw 22)
ROOT_DB_PW=$(gen_pw 28)
MAIL_DB_PW=$(gen_pw 28)
TEST_MAILBOX_PW=$(gen_pw 22)
ROUNDCUBE_DB_PW=$(gen_pw 28)
ROUNDCUBE_DES_KEY=$(gen_pw 24)
WP_DB_PW=$(gen_pw 28)

echo "${GREEN}Generated 8 random passwords (22-28 chars each)${RESET}"

# ============================================================================
# CONFIRMATION
# ============================================================================
step "Review"

cat <<EOF
${BOLD}Tenant config to be written:${RESET}
  Primary domain:          ${CYAN}${PRIMARY_DOMAIN}${RESET}
  Server IP:               ${CYAN}${SERVER_IP}${RESET}
  Personal admin user:     ${CYAN}${ADMIN_USER}${RESET}
  Shareable admin user:    ${CYAN}${SHARED_ADMIN_USER}${RESET}
  SSH port:                ${CYAN}${SSH_PORT}${RESET}
  Timezone:                ${CYAN}${TIMEZONE}${RESET}
  Notification email:      ${CYAN}${NOTIFICATION_EMAIL}${RESET}
  Test mailbox:            ${CYAN}${TEST_MAILBOX}${RESET}

${BOLD}Secrets to be written:${RESET}
  RC+ license key:         ${CYAN}${RC_PLUS_LICENSE_KEY}${RESET}
  AI API key:              ${CYAN}${XAI_API_KEY:-(skipped)}${RESET}
  Plus 8 auto-generated passwords.

EOF

read -r -p "Write these files? Type ${BOLD}yes${RESET}: " confirm
if [ "$confirm" != "yes" ]; then
    echo "Aborted. No files written."
    exit 1
fi

# ============================================================================
# WRITE FILES
# ============================================================================
step "Writing files"

# tenant.local - sourced by phase scripts
cat > "$TENANT_FILE" << TENANT_LOCAL_EOF
# ============================================================================
# tenant.local - Generated by phase0-bootstrap.sh on $(date '+%Y-%m-%d %H:%M:%S %Z')
# ============================================================================
# Non-secret per-tenant configuration. Sourced by phase scripts.
# This file is gitignored - safe to keep here.
# ============================================================================

PRIMARY_DOMAIN="${PRIMARY_DOMAIN}"
SERVER_IP="${SERVER_IP}"
SERVER_PURPOSE="${SERVER_PURPOSE}"
ADMIN_USER="${ADMIN_USER}"
SHARED_ADMIN_USER="${SHARED_ADMIN_USER}"
SSH_PORT="${SSH_PORT}"
TIMEZONE="${TIMEZONE}"
NOTIFICATION_EMAIL="${NOTIFICATION_EMAIL}"
TEST_MAILBOX_LOCAL="${TEST_MAILBOX_LOCAL}"

# Backward compat: phase scripts still reference STAFF_USER
# (resolves to the shareable admin so existing logic keeps working)
STAFF_USER="${SHARED_ADMIN_USER}"

HOSTNAME_FQDN="${PRIMARY_DOMAIN}"
HOSTNAME_SHORT="${HOSTNAME_SHORT}"
ALT_DOMAINS=("www.${PRIMARY_DOMAIN}")
MAIL_DOMAIN="${PRIMARY_DOMAIN}"
MAIL_HOSTNAME="mail.${PRIMARY_DOMAIN}"
WP_DOMAIN="${PRIMARY_DOMAIN}"
WP_DOMAIN_ALT="www.${PRIMARY_DOMAIN}"
WP_DB_NAME="${WP_DB_NAME}"
WP_DB_USER="${WP_DB_USER}"
TEST_MAILBOX="${TEST_MAILBOX}"

CERTBOT_EMAIL="${NOTIFICATION_EMAIL}"
DMARC_RUA_EMAIL="${NOTIFICATION_EMAIL}"
CAA_IODEF_EMAIL="${NOTIFICATION_EMAIL}"
WP_ADMIN_EMAIL="${NOTIFICATION_EMAIL}"
TENANT_LOCAL_EOF

chmod 644 "$TENANT_FILE"
echo "${GREEN}Wrote $TENANT_FILE${RESET}"

# secrets.local - machine-readable, sourced by phase scripts
cat > "$SECRETS_FILE" << SECRETS_LOCAL_EOF
# ============================================================================
# secrets.local - Generated by phase0-bootstrap.sh on $(date '+%Y-%m-%d %H:%M:%S %Z')
# ============================================================================
# Machine-readable secrets file. Sourced by phase scripts.
# This file is gitignored.
# Human-readable version is CREDENTIALS.txt
# ============================================================================

RC_PLUS_LICENSE_KEY="${RC_PLUS_LICENSE_KEY}"
XAI_API_KEY="${XAI_API_KEY}"

ADMIN_PW="${ADMIN_PW}"
SHARED_ADMIN_PW="${SHARED_ADMIN_PW}"
# Backward compat: STAFF_PW maps to the shareable admin's password
STAFF_PW="${SHARED_ADMIN_PW}"

ROOT_DB_PW="${ROOT_DB_PW}"
MAIL_DB_PW="${MAIL_DB_PW}"
TEST_MAILBOX_PW="${TEST_MAILBOX_PW}"
ROUNDCUBE_DB_PW="${ROUNDCUBE_DB_PW}"
ROUNDCUBE_DES_KEY="${ROUNDCUBE_DES_KEY}"
WP_DB_PW="${WP_DB_PW}"
SECRETS_LOCAL_EOF

chmod 600 "$SECRETS_FILE"
echo "${GREEN}Wrote $SECRETS_FILE (mode 0600)${RESET}"

# CREDENTIALS.txt - human-readable summary
XAI_DISPLAY="${XAI_API_KEY}"
[ -z "$XAI_DISPLAY" ] && XAI_DISPLAY="(not configured)"

cat > "$CREDENTIALS_FILE" << CREDENTIALS_EOF
==============================================================
  CREDENTIALS FOR ${PRIMARY_DOMAIN} (${SERVER_IP})
  Generated: $(date '+%Y-%m-%d %H:%M %Z')
==============================================================

==============================================================
  PURPOSE OF THIS SERVER
==============================================================
  ${SERVER_PURPOSE}

==============================================================
  1. KAMATERA ACCOUNT (your account at kamatera.com)
==============================================================
  WHAT IT'S FOR:    Logging into kamatera.com to manage your
                    servers, view your billing,
                    your server list, or reset passwords.
  WHERE YOU USE IT: https://console.kamatera.com (in browser)
  Username:         (your Kamatera account email)
  Password:         (your Kamatera account password)

  >>> NOT GENERATED BY THIS SCRIPT - this is your account
      with Kamatera, set up when you signed up. <<<

==============================================================
  2. KAMATERA SERVER ROOT (this specific server's root password)
==============================================================
  WHAT IT'S FOR:    Logging into the Kamatera browser console
                    when SSH is broken. Emergency recovery only.
  WHERE YOU USE IT: Kamatera console (the black-screen browser
                    window that says "${HOSTNAME_SHORT} login:")
  Username:         root
  Password:         (the password Kamatera emailed you when
                    the server was created)

  >>> NOT GENERATED BY THIS SCRIPT - Kamatera set this when
      they created the server. <<<

==============================================================
  3. SSH ADMIN LOGIN  (your day-to-day server access)
==============================================================
  WHAT IT'S FOR:    Logging into the server via SSH using
                    MobaXterm, PuTTY, or any SSH client.
  WHERE YOU USE IT: ssh -p ${SSH_PORT} ${ADMIN_USER}@${SERVER_IP}

                    Note: SSH is set to port ${SSH_PORT} (not the
                    default 22) in an attempt to reduce spam
                    attacks.

  Username:  ${ADMIN_USER}
  Password:  ${ADMIN_PW}

  Username:  ${SHARED_ADMIN_USER}
  Password:  ${SHARED_ADMIN_PW}

  Either user works. Both have full sudo. Use '${SHARED_ADMIN_USER}' if you
  need to give someone else access without sharing your ${ADMIN_USER}
  account.

==============================================================
  4. WEBMAIL TEST MAILBOX  (logging into Roundcube)
==============================================================
  WHAT IT'S FOR:    Logging into the Roundcube webmail to
                    test that email works.
  WHERE YOU USE IT: https://${PRIMARY_DOMAIN}/mail/

  Email address: ${TEST_MAILBOX}
  Password:      ${TEST_MAILBOX_PW}

==============================================================
  BACKEND PASSWORDS (you don't type these — software uses them)
==============================================================
  These are used by software internally. You don't ever type
  these into a login screen. Listed here only so they exist
  in your password manager in case you need to recover them.

  MariaDB root:        ${ROOT_DB_PW}
  Mail database:       ${MAIL_DB_PW}
  Roundcube database:  ${ROUNDCUBE_DB_PW}
  Roundcube DES key:   ${ROUNDCUBE_DES_KEY}
  WordPress database:  ${WP_DB_PW}

==============================================================
  PURCHASED LICENSE KEYS
==============================================================
  Roundcube Plus:      ${RC_PLUS_LICENSE_KEY}
  AI API key:          ${XAI_DISPLAY}

==============================================================
  *** SAVE THIS FILE TO YOUR PASSWORD MANAGER NOW. ***

  After the build is verified working, delete this file
  from the server with:  rm ${CREDENTIALS_FILE}
==============================================================
CREDENTIALS_EOF

chmod 600 "$CREDENTIALS_FILE"
echo "${GREEN}Wrote $CREDENTIALS_FILE (mode 0600)${RESET}"

# ============================================================================
# DISPLAY CREDENTIALS
# ============================================================================
echo ""
echo "${BOLD}${YELLOW}=============================================================${RESET}"
echo "${BOLD}${YELLOW}  CREDENTIALS - SAVE TO PASSWORD MANAGER NOW${RESET}"
echo "${BOLD}${YELLOW}=============================================================${RESET}"
echo ""
cat "$CREDENTIALS_FILE"
echo ""

# ============================================================================
# DONE
# ============================================================================
cat <<EOF

${BOLD}=============================================================
  BOOTSTRAP COMPLETE
=============================================================${RESET}

Files written:
  ${CYAN}${TENANT_FILE}${RESET}
  ${CYAN}${SECRETS_FILE}${RESET}
  ${CYAN}${CREDENTIALS_FILE}${RESET}

${BOLD}NEXT STEPS:${RESET}

1. ${YELLOW}Save CREDENTIALS.txt above to your password manager NOW.${RESET}
   Highlight it with your mouse and copy. After the build is verified
   working, delete the file from the server.

2. Add DNS records at your DNS provider (if not already done):
     A     ${PRIMARY_DOMAIN}       -> ${SERVER_IP}
     A     www.${PRIMARY_DOMAIN}   -> ${SERVER_IP}
     A     mail.${PRIMARY_DOMAIN}  -> ${SERVER_IP}

3. Run phase 1 to begin the build:
     ${BOLD}sudo bash scripts/phase1.sh${RESET}

4. Continue through phases 2, 3, 4, 5, 5b, 5c, 6 in order.
   Each phase reads from tenant.local and secrets.local.

EOF
