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
QUICK_REFERENCE_FILE="$REPO_ROOT/QUICK-REFERENCE.txt"

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
            echo "${RED}This field is required.${RESET}" >&2
        fi
    done
    echo "$response"
}

# ask_domain - prompt for a valid FQDN that includes a TLD.
# Rejects bare hostnames (e.g. "myproject" without ".com") because phase 0's
# output propagates into mail hostnames, certbot, DKIM/DMARC, etc. and a
# missing TLD breaks every downstream phase silently.
ask_domain() {
    local prompt="$1"
    local response=""
    while true; do
        response=$(ask_required "$prompt")
        # Lowercase, strip whitespace
        response=$(echo "$response" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
        # Must look like name.tld (or sub.name.tld) - at least one dot, TLD
        # at least 2 chars, only letters/digits/hyphens in labels, no leading
        # or trailing hyphen in any label.
        if echo "$response" | grep -qE '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\.[a-z]{2,}$'; then
            echo "$response"
            return 0
        fi
        echo "${RED}Invalid domain: '$response'${RESET}" >&2
        echo "${RED}Must be a fully-qualified domain like 'acmemuseum.com' (with TLD).${RESET}" >&2
    done
}

# ask_yes_no - prompt for an explicit "yes" or "no" answer. No bare-Enter
# acceptance. Returns 0 on yes, 1 on no. Loops until a valid answer.
#
# IMPORTANT: This function may be called from inside another function whose
# output is captured (e.g. SERVER_IP=$(ask_server_ip), where ask_server_ip
# itself calls ask_yes_no). The error message for invalid input MUST go to
# stderr (>&2) so it doesn't pollute the outer capture. Same pattern as the
# fix in ask_server_ip from commit 922c6ab.
ask_yes_no() {
    local prompt="$1"
    local response=""
    while true; do
        read -r -p "${YELLOW}${prompt}${RESET} ${BOLD}(type yes or no)${RESET}: " response
        response=$(echo "$response" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
        case "$response" in
            yes) return 0 ;;
            no)  return 1 ;;
            *)   echo "${RED}Please type 'yes' or 'no' (full word).${RESET}" >&2 ;;
        esac
    done
}

# ask_server_ip - try to auto-derive the public IPv4 from hostname -I. If
# exactly one IPv4 address is bound (the typical Kamatera single-interface
# case), display it and ask for confirmation. If multiple IPs are present
# or detection fails, fall back to a typed prompt. Either way, the result
# is validated as a plausible IPv4.
ask_server_ip() {
    local detected_ips
    detected_ips=$(hostname -I 2>/dev/null | tr ' ' '\n' \
        | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' \
        | grep -vE '^(127\.|169\.254\.)')
    local ip_count
    ip_count=$(echo "$detected_ips" | grep -c .)

    if [ "$ip_count" -eq 1 ]; then
        local detected_ip
        detected_ip=$(echo "$detected_ips" | head -1)
        echo "  Detected public IPv4: ${CYAN}${detected_ip}${RESET}"
        if ask_yes_no "Use this as the server IP?"; then
            echo "$detected_ip"
            return 0
        fi
        echo "  OK, enter the correct IP manually."
    elif [ "$ip_count" -gt 1 ]; then
        echo "  Multiple IPv4 addresses detected on this server:"
        echo "$detected_ips" | sed 's/^/    /'
        echo "  Auto-detection skipped - please type the correct one."
    fi

    # Fallback: typed prompt with basic IPv4 sanity check
    local response=""
    while true; do
        response=$(ask_required "Server public IPv4 address")
        response=$(echo "$response" | tr -d '[:space:]')
        if echo "$response" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
            echo "$response"
            return 0
        fi
        echo "${RED}Invalid IPv4: '$response'. Expected format: a.b.c.d (each 0-255).${RESET}"
    done
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

This script collects the per-tenant configuration needed to build
this server. For each prompt, type a value and press Enter.

After this completes, four files will be written on this server
in ${CYAN}${REPO_ROOT}/${RESET}:

  ${CYAN}${TENANT_FILE}${RESET}
    non-secret tenant config (used by phase scripts)

  ${CYAN}${SECRETS_FILE}${RESET}
    passwords (used by phase scripts) - gitignored, mode 600

  ${CYAN}${CREDENTIALS_FILE}${RESET}
    human-readable credentials summary - gitignored, mode 600

  ${CYAN}${QUICK_REFERENCE_FILE}${RESET}
    day-to-day commands and password quick reference - mode 600

You can safely abort with Ctrl+C at any time before the final
write step. Nothing on the system changes until you run phase 1.

EOF
if ! ask_yes_no "Begin?"; then
    echo "Aborted. Re-run phase0-bootstrap.sh when ready."
    exit 0
fi

# ============================================================================
# CHECK FOR EXISTING FILES
# ============================================================================
if [ -f "$TENANT_FILE" ] || [ -f "$SECRETS_FILE" ] || [ -f "$CREDENTIALS_FILE" ] || [ -f "$QUICK_REFERENCE_FILE" ]; then
    echo ""
    echo "${RED}WARNING:${RESET} Existing config files found:"
    [ -f "$TENANT_FILE" ] && echo "  $TENANT_FILE"
    [ -f "$SECRETS_FILE" ] && echo "  $SECRETS_FILE"
    [ -f "$CREDENTIALS_FILE" ] && echo "  $CREDENTIALS_FILE"
    [ -f "$QUICK_REFERENCE_FILE" ] && echo "  $QUICK_REFERENCE_FILE"
    echo ""
    if ! ask_yes_no "Overwrite them?"; then
        echo "Aborted."
        exit 1
    fi
fi

# ============================================================================
# COLLECT USER INPUT
# ============================================================================
step "Tenant identity"

PRIMARY_DOMAIN=$(ask_domain "Primary domain (e.g., acmemuseum.com)")
SERVER_IP=$(ask_server_ip)

step "Purpose"

echo "One-line description of what this server is for."
echo "This will appear at the top of CREDENTIALS.txt as a reminder."
echo ""
SERVER_PURPOSE=$(ask_required "Purpose")

step "Admin accounts and host settings (hardcoded)"

ADMIN_USER="wayne"
SHARED_ADMIN_USER="admin"
SSH_PORT="2222"
TIMEZONE="America/Los_Angeles"

echo "  Personal admin user:    ${CYAN}${ADMIN_USER}${RESET}"
echo "  Shareable admin user:   ${CYAN}${SHARED_ADMIN_USER}${RESET}"
echo "  SSH port:               ${CYAN}${SSH_PORT}${RESET}"
echo "  Timezone:               ${CYAN}${TIMEZONE}${RESET}"
echo ""
echo "  These values are hardcoded. To change, edit phase0-bootstrap.sh."

step "Notification email"

echo "This single email gets used for: Let's Encrypt cert renewal,"
echo "DMARC reports, CAA reports, and WordPress admin contact."
echo ""
NOTIFICATION_EMAIL=$(ask_required "Notification email")

# Test mailbox is auto-conventioned, never user-configurable. Phase 4 creates
# it. It will appear in the auto-derived display below.
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

if ! ask_yes_no "Write these files?"; then
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
  *** NOT YET ACTIVE - wait for phase 1 to complete ***
  These credentials will work AFTER phase 1 has run successfully.
  Until then: SSH is still on port 22 with the original Kamatera
  root password (section 2). Phase 1 creates these users, opens
  port ${SSH_PORT}, and locks down port 22.
  This warning will be removed automatically once phase 1 completes.
  --------------------------------------------------------------
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
# QUICK-REFERENCE.txt - day-to-day commands and recovery
# ============================================================================
cat > "$QUICK_REFERENCE_FILE" << QUICKREF_EOF
==============================================================
  QUICK REFERENCE - ${PRIMARY_DOMAIN}
  Generated: $(date -u "+%Y-%m-%d %H:%M UTC")
==============================================================
  Day-to-day commands and recovery procedures.
  Sensitive: contains the same passwords as CREDENTIALS.txt.
  Permissions: mode 600 (root-only readable).

==============================================================
  CONNECTING TO THIS SERVER
==============================================================

  SSH (after phase 1 completes):
    ssh -p ${SSH_PORT} ${ADMIN_USER}@${SERVER_IP}
    Password: ${ADMIN_PW}

  SSH (alternative shareable account):
    ssh -p ${SSH_PORT} ${SHARED_ADMIN_USER}@${SERVER_IP}
    Password: ${SHARED_ADMIN_PW}

  Web (placeholder/WordPress site):
    https://${PRIMARY_DOMAIN}/

  Webmail (Roundcube):
    https://${PRIMARY_DOMAIN}/mail/
    Username: ${TEST_MAILBOX_LOCAL}    (or full: ${TEST_MAILBOX})
    Password: ${TEST_MAILBOX_PW}

  WordPress admin (after install wizard):
    https://${PRIMARY_DOMAIN}/wp-admin/

  Kamatera console (when SSH is broken):
    https://console.kamatera.com
    Then open the server's console - login as 'root' with the
    password Kamatera emailed you when the server was created.

==============================================================
  PHASE COMMANDS (re-run if needed; all phases idempotent)
==============================================================

  All phase scripts live in: /root/server-build/scripts/
  Run as: sudo bash /root/server-build/scripts/phaseN.sh

    phase0-bootstrap.sh        Generate config + this file
    phase1.sh                  OS hardening, users, SSH, firewall, fail2ban
    phase2.sh                    Apache + Let's Encrypt TLS
    phase3.sh                    MariaDB + daily backups
    phase4.sh                    Postfix + Dovecot + DKIM + DMARC + Spam
    phase5.sh                    Roundcube webmail
    phase5a-rc-plus.sh           Roundcube Plus skin and plugins
    phase5b-globaladdressbook.sh Project Contacts shared address book
    phase5c-email-ai.sh          Email AI (xai plugin) - placeholder
    phase6.sh                    WordPress

  Tip: tee output to a log so you can search for errors later:
    sudo bash /root/server-build/scripts/phase4.sh 2>&1 | tee /tmp/phase4-run.log

==============================================================
  CHECKING SERVICE HEALTH
==============================================================

  All services at once:
    systemctl status apache2 mariadb postfix dovecot opendkim opendmarc spamd spamass-milter --no-pager

  Restart a single service:
    sudo systemctl restart <service-name>

  Last 50 lines of the mail log:
    sudo tail -50 /var/log/mail.log

  Last 50 lines of the Apache error log:
    sudo tail -50 /var/log/apache2/error.log

  Roundcube error log:
    sudo tail -50 /var/log/roundcube/errors.log

  Firewall status:
    sudo ufw status verbose

  fail2ban status (which IPs are banned):
    sudo fail2ban-client status sshd

==============================================================
  RECOVERY: I LOCKED MYSELF OUT WITH FAIL2BAN
==============================================================

  Three wrong SSH password attempts = 1-hour ban from your IP.

  RECOVERY (from Kamatera console as root):
    sudo fail2ban-client unban <your-IP>
  Or unban everyone (after a typo storm):
    sudo fail2ban-client unban --all

  Find your current public IP from your laptop:
    Browser: https://whatismyipaddress.com/

==============================================================
  RECOVERY: SSH WON'T CONNECT
==============================================================

  If wayne can't connect on port ${SSH_PORT}, log in to the
  Kamatera console (browser, no SSH needed) as root with the
  Kamatera-emailed password, then:

    1. Confirm SSH is running:
         systemctl status ssh.socket
         ss -tlnp | grep ${SSH_PORT}

    2. Confirm firewall lets ${SSH_PORT}/tcp through:
         ufw status verbose

    3. Confirm fail2ban hasn't banned you (see section above).

    4. Restart SSH if needed:
         systemctl daemon-reload
         systemctl restart ssh.socket

==============================================================
  RECOVERY: TLS CERTIFICATE EXPIRED OR BROKEN
==============================================================

  Force a renewal (will only renew if cert is < 30 days from expiry):
    sudo certbot renew

  Force a renewal NOW regardless of expiry (use sparingly - rate
  limited by Let's Encrypt to 5 per week per domain):
    sudo certbot renew --force-renewal

  After renewal, reload Apache:
    sudo systemctl reload apache2

  Auto-renewal status:
    systemctl status certbot.timer --no-pager
    sudo systemctl list-timers certbot.timer

==============================================================
  TESTING MAIL
==============================================================

  Send a local test message:
    echo "test body" | mail -s "test subject" ${TEST_MAILBOX}

  Confirm it arrived:
    sudo find /var/vmail/${PRIMARY_DOMAIN} -name 'new' -type d
    sudo ls -la /var/vmail/${PRIMARY_DOMAIN}/${TEST_MAILBOX_LOCAL}/new/

  GTUBE spam test (should land in Junk folder, not Inbox):
    Send to ${TEST_MAILBOX} from any external account with this in
    the body (single line, no quotes):
      XJS*C4JDBQADN1.NSBN3*2IDNEN*GTUBE-STANDARD-ANTI-UBE-TEST-EMAIL*C.34X

  External mail tester (verifies SPF/DKIM/DMARC/blacklists):
    https://www.mail-tester.com/

==============================================================
  VERIFYING DNS
==============================================================

  From your Windows PowerShell:
    nslookup ${PRIMARY_DOMAIN}
    nslookup www.${PRIMARY_DOMAIN}
    nslookup mail.${PRIMARY_DOMAIN}

  From the server (more detail):
    dig @8.8.8.8 ${PRIMARY_DOMAIN}
    dig @8.8.8.8 MX ${PRIMARY_DOMAIN}
    dig @8.8.8.8 TXT ${PRIMARY_DOMAIN}
    dig @8.8.8.8 TXT default._domainkey.${PRIMARY_DOMAIN}
    dig @8.8.8.8 TXT _dmarc.${PRIMARY_DOMAIN}

==============================================================
  BACKEND PASSWORDS (used by software, listed for recovery)
==============================================================

  MariaDB root:        ${ROOT_DB_PW}
  Mail database:       ${MAIL_DB_PW}
  Roundcube database:  ${ROUNDCUBE_DB_PW}
  Roundcube DES key:   ${ROUNDCUBE_DES_KEY}
  WordPress database:  ${WP_DB_PW}

  Connect to MariaDB as root (no password prompt - uses /root/.my.cnf):
    sudo mysql

  List databases:
    sudo mysql -e 'SHOW DATABASES;'

==============================================================
  MOBAXTERM TIPS (Windows SSH client)
==============================================================

  - Right-click the session tab to color-code it
    (suggestion: green = production, red = test, yellow = staging).
  - Left panel = SFTP browser of the server you're connected to.
    Drag files between Windows and the server here.
  - Files coming FROM Windows often have CRLF line endings. After
    uploading scripts, run on the server:
      sed -i 's/\\r\$//' /path/to/script.sh
  - To paste in a session, use right-click (Ctrl+V often doesn't
    work in terminals).

==============================================================
  CLEANING UP AFTER VERIFIED BUILD
==============================================================

  Once you've confirmed the build works end-to-end, delete the
  sensitive files (passwords are in your password manager):

    rm /root/server-build/CREDENTIALS.txt
    rm /root/server-build/QUICK-REFERENCE.txt

  The tenant.local and secrets.local files stay - phase scripts
  read from secrets.local for idempotent re-runs.

==============================================================
QUICKREF_EOF

chmod 600 "$QUICK_REFERENCE_FILE"
echo "${GREEN}Wrote $QUICK_REFERENCE_FILE (mode 0600)${RESET}"

# ============================================================================
# COPY CREDENTIAL FILES TO ADMIN HOME (downloadable without sudo)
# ============================================================================
# /root/ is mode 700 - wayne can't read files there without sudo. Copy the
# two human-readable credential files to /home/$ADMIN_USER/ so wayne can
# download them straight from MobaXterm's SFTP browser. Owner is set to
# the admin user so they can read AND delete after saving.
#
# If /home/$ADMIN_USER/ doesn't exist yet (because phase 1 hasn't run and
# the wayne user hasn't been created), we set DOWNLOAD_LOCATION to the
# fallback path and adjust the user-facing instructions below.
ADMIN_HOME="/home/${ADMIN_USER}"
ADMIN_CRED_FILE="${ADMIN_HOME}/CREDENTIALS.txt"
ADMIN_QREF_FILE="${ADMIN_HOME}/QUICK-REFERENCE.txt"

if [ -d "$ADMIN_HOME" ]; then
    cp "$CREDENTIALS_FILE" "$ADMIN_CRED_FILE"
    cp "$QUICK_REFERENCE_FILE" "$ADMIN_QREF_FILE"
    chown "${ADMIN_USER}:${ADMIN_USER}" "$ADMIN_CRED_FILE" "$ADMIN_QREF_FILE"
    chmod 600 "$ADMIN_CRED_FILE" "$ADMIN_QREF_FILE"
    echo "${GREEN}Copied credential files to ${ADMIN_HOME}/ (owner ${ADMIN_USER}, mode 0600)${RESET}"
    DOWNLOAD_DIR="${ADMIN_HOME}"
    DOWNLOAD_CRED_FILE="${ADMIN_CRED_FILE}"
    DOWNLOAD_QREF_FILE="${ADMIN_QREF_FILE}"
    DOWNLOAD_AS_USER="${ADMIN_USER} (no sudo needed)"
else
    echo "${YELLOW}NOTE: ${ADMIN_HOME} does not exist yet - phase 1 will create it.${RESET}"
    echo "${YELLOW}For now, download credentials directly from ${REPO_ROOT}/ as root.${RESET}"
    DOWNLOAD_DIR="${REPO_ROOT}"
    DOWNLOAD_CRED_FILE="${CREDENTIALS_FILE}"
    DOWNLOAD_QREF_FILE="${QUICK_REFERENCE_FILE}"
    DOWNLOAD_AS_USER="root (you are root right now, since phase 1 has not run)"
fi

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
# FORCING FUNCTION: block until user confirms download
# ============================================================================
# This is intentional friction. Without it, on a long session you might
# move on, lose the scrollback, and find yourself unable to read
# /root/CREDENTIALS.txt because you've already lost the wayne password.
# Phase 0 will not exit until you type DOWNLOADED.
echo ""
echo "${BOLD}${YELLOW}=============================================================${RESET}"
echo "${BOLD}${YELLOW}  ACTION REQUIRED - DOWNLOAD CREDENTIALS BEFORE CONTINUING${RESET}"
echo "${BOLD}${YELLOW}=============================================================${RESET}"
cat <<EOF

  Two files are ready for download. They are readable as
  ${BOLD}${DOWNLOAD_AS_USER}${RESET}:

    ${CYAN}${DOWNLOAD_CRED_FILE}${RESET}
    ${CYAN}${DOWNLOAD_QREF_FILE}${RESET}

  ${BOLD}Do this now, before continuing:${RESET}

    1. Open MobaXterm's left sidebar (SFTP browser).
    2. Navigate to ${CYAN}${DOWNLOAD_DIR}/${RESET}
    3. Right-click each file -> Download. Save them somewhere
       you control (password manager, encrypted folder, etc).

  Phase 0 will not finish until you confirm.

EOF

while true; do
    read -r -p "  When BOTH files are downloaded, type DOWNLOADED and press Enter: " CONFIRM
    if [ "$CONFIRM" = "DOWNLOADED" ]; then
        echo ""
        echo "${GREEN}  Confirmed. Continuing.${RESET}"
        echo ""
        break
    fi
    echo "${YELLOW}  (Type the word DOWNLOADED exactly, in capital letters.)${RESET}"
done

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
  ${CYAN}${QUICK_REFERENCE_FILE}${RESET}

Downloaded copies (saved during the action-required step):
  ${CYAN}${DOWNLOAD_CRED_FILE}${RESET}
  ${CYAN}${DOWNLOAD_QREF_FILE}${RESET}

${BOLD}NEXT STEPS:${RESET}

1. Add DNS records at your DNS provider (if not already done):
     A     ${PRIMARY_DOMAIN}       -> ${SERVER_IP}
     A     www.${PRIMARY_DOMAIN}   -> ${SERVER_IP}
     A     mail.${PRIMARY_DOMAIN}  -> ${SERVER_IP}

2. Run the build. RECOMMENDED: chain all phases at once
   (stops on first failure):

     ${BOLD}sudo bash ${REPO_ROOT}/scripts/run-phases.sh${RESET}

   Or run them one at a time, in order:

     sudo bash ${REPO_ROOT}/scripts/phase1.sh
     sudo bash ${REPO_ROOT}/scripts/phase2.sh
     sudo bash ${REPO_ROOT}/scripts/phase3.sh
     sudo bash ${REPO_ROOT}/scripts/phase4.sh
     sudo bash ${REPO_ROOT}/scripts/phase5.sh
     sudo bash ${REPO_ROOT}/scripts/phase5a-rc-plus.sh
     sudo bash ${REPO_ROOT}/scripts/phase5b-globaladdressbook.sh
     sudo bash ${REPO_ROOT}/scripts/phase5c-email-ai.sh
     sudo bash ${REPO_ROOT}/scripts/phase6.sh

   Each phase reads from tenant.local and secrets.local.

EOF
