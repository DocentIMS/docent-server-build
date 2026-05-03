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
if [ -f "$TENANT_FILE" ] || [ -f "$SECRETS_FILE" ] || [ -f "$CREDENTIALS_FILE" ] || [ -f "$QUICK_REFERENCE_FILE" ]; then
    echo ""
    echo "${RED}WARNING:${RESET} Existing config files found:"
    [ -f "$TENANT_FILE" ] && echo "  $TENANT_FILE"
    [ -f "$SECRETS_FILE" ] && echo "  $SECRETS_FILE"
    [ -f "$CREDENTIALS_FILE" ] && echo "  $CREDENTIALS_FILE"
    [ -f "$QUICK_REFERENCE_FILE" ] && echo "  $QUICK_REFERENCE_FILE"
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
    phase2.sh                  Apache + Let's Encrypt TLS
    phase3.sh                  MariaDB + daily backups
    phase4.sh                  Postfix + Dovecot + DKIM + DMARC + Spam
    phase5.sh                  Roundcube webmail
    phase5b-rc-plus.sh         Roundcube Plus skin and plugins
    phase5c-globaladdressbook.sh Project Contacts shared address book
    phase6.sh                  WordPress

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
  ${CYAN}${QUICK_REFERENCE_FILE}${RESET}

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
