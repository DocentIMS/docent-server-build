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
# IMPORTANT: error message goes to stderr (>&2). When ask_yes_no is called
# from inside a function whose output is captured, e.g.:
#     SERVER_IP=$(ask_server_ip)         # ask_server_ip internally calls ask_yes_no
# any stdout from ask_yes_no would be captured into SERVER_IP. A user typo
# (e.g. typing the IP at the "Use this as the server IP?" prompt instead of
# 'yes') would push the error message into the captured value, polluting
# everything downstream. Same pattern as ask_required / ask_domain /
# ask_server_ip - all three already redirect their errors to stderr.
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
#
# IMPORTANT: this function is used as SERVER_IP=$(ask_server_ip), which
# means anything written to stdout becomes part of $SERVER_IP. All display
# output MUST go to stderr (>&2). Only the final IP value goes to stdout.
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
        echo "  Detected public IPv4: ${CYAN}${detected_ip}${RESET}" >&2
        if ask_yes_no "Use this as the server IP?"; then
            echo "$detected_ip"
            return 0
        fi
        echo "  OK, enter the correct IP manually." >&2
    elif [ "$ip_count" -gt 1 ]; then
        echo "  Multiple IPv4 addresses detected on this server:" >&2
        echo "$detected_ips" | sed 's/^/    /' >&2
        echo "  Auto-detection skipped - please type the correct one." >&2
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
        echo "${RED}Invalid IPv4: '$response'. Expected format: a.b.c.d (each 0-255).${RESET}" >&2
    done
}

# check_dns_resolution - sanity-check that the user-entered domain and IP
# actually match in public DNS. Looks up the A records for the apex domain,
# www., and mail. subdomains and compares to SERVER_IP. Each is independent:
# any can be missing, any can mismatch, the user gets a single warning with
# the actual results and an explicit yes/no to continue.
#
# This is advisory, not blocking. Common reasons to continue anyway:
#   - DNS not yet propagated (brand new domain or just changed records)
#   - Building before DNS is set up (test/dev servers)
#   - Using a registrar that's slow to publish
#
# Common reasons to STOP and fix:
#   - Typo in DOMAIN
#   - Typo in SERVER_IP
#   - DNS still pointing at an old server
#
# Uses 'dig' if available (preferred), falls back to 'host', falls back to
# 'getent ahosts'. On a fresh Ubuntu, dnsutils may not be installed yet,
# so we degrade gracefully if no lookup tool is found.
check_dns_resolution() {
    local domain="$1"
    local expected_ip="$2"

    # Find a usable lookup tool. Quote the result of 'command -v' to swallow
    # the "not found" output cleanly.
    local lookup_cmd=""
    if command -v dig >/dev/null 2>&1; then
        lookup_cmd="dig"
    elif command -v host >/dev/null 2>&1; then
        lookup_cmd="host"
    elif command -v getent >/dev/null 2>&1; then
        lookup_cmd="getent"
    else
        echo "${YELLOW}  No DNS lookup tool found (dig/host/getent) - skipping cross-check.${RESET}" >&2
        return 0
    fi

    # Look up an A record. Returns the resolved IP, or empty if no answer.
    local resolved=""
    _resolve() {
        local name="$1"
        case "$lookup_cmd" in
            dig)
                dig +short +time=3 +tries=1 A "$name" 2>/dev/null \
                    | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | head -1
                ;;
            host)
                host -t A "$name" 2>/dev/null \
                    | awk '/has address/ {print $4; exit}'
                ;;
            getent)
                getent ahosts "$name" 2>/dev/null \
                    | awk '/STREAM/ {print $1; exit}'
                ;;
        esac
    }

    echo "" >&2
    echo "${BOLD}  Checking DNS resolution for ${domain}, www.${domain}, mail.${domain}${RESET}" >&2
    echo "  (using $lookup_cmd, against your system's resolver)" >&2

    local mismatch=0
    local name
    for name in "$domain" "www.$domain" "mail.$domain"; do
        resolved=$(_resolve "$name")
        if [ -z "$resolved" ]; then
            echo "  ${YELLOW}!${RESET} ${name} -> ${YELLOW}no A record found${RESET}" >&2
            mismatch=1
        elif [ "$resolved" = "$expected_ip" ]; then
            echo "  ${GREEN}✓${RESET} ${name} -> ${resolved}" >&2
        else
            echo "  ${RED}✗${RESET} ${name} -> ${resolved} ${RED}(expected ${expected_ip})${RESET}" >&2
            mismatch=1
        fi
    done

    if [ "$mismatch" -eq 0 ]; then
        echo "  ${GREEN}All three records resolve correctly.${RESET}" >&2
        return 0
    fi

    echo "" >&2
    echo "${YELLOW}  DNS records do not yet match what you entered.${RESET}" >&2
    echo "${YELLOW}  This is OK if DNS hasn't propagated yet, or if you're${RESET}" >&2
    echo "${YELLOW}  building before setting up DNS. Phases 2 (cert) and 4 (mail)${RESET}" >&2
    echo "${YELLOW}  WILL fail without correct DNS, but you can fix DNS first${RESET}" >&2
    echo "${YELLOW}  and re-run those phases - they're idempotent.${RESET}" >&2
    echo "" >&2

    if ask_yes_no "Continue anyway?"; then
        return 0
    else
        echo "" >&2
        echo "  Aborted. Fix DNS and re-run phase0-bootstrap.sh." >&2
        exit 1
    fi
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

EOF

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

DOMAIN=$(ask_domain "Primary domain (e.g., acmemuseum.com)")
SERVER_IP=$(ask_server_ip)

# Sanity-check that DNS is set up before we go on. This catches typos
# in the domain or IP, and DNS that's still pointing at an old server.
# Advisory: user can override with a yes if they're building before DNS.
check_dns_resolution "$DOMAIN" "$SERVER_IP"

step "Purpose"

echo "One-line description of what this server is for."
echo "This will appear at the top of CREDENTIALS.txt as a reminder."
echo ""
SERVER_PURPOSE=$(ask_required "Purpose")

# Hardcoded admin accounts and host settings (assigned silently;
# documented in CREDENTIALS.txt after write).
ADMIN_USER="wayne"
SHARED_ADMIN_USER="admin"
ESPEN_USER="espen"
SSH_PORT="2222"
TIMEZONE="America/Los_Angeles"

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
# Values auto-derived from primary domain (assigned silently).

DOMAIN_STEM="${DOMAIN%%.*}"
HOSTNAME_SHORT="$DOMAIN_STEM"
WP_DB_NAME="wordpress_${DOMAIN_STEM}"
WP_DB_USER="wp_$(echo "$DOMAIN_STEM" | head -c 2)_user"
WP_ADMIN_USERNAME="wpadmin"
WP_SITE_TITLE="Docent IMS"
TEST_MAILBOX="${TEST_MAILBOX_LOCAL}@${DOMAIN}"

# ============================================================================
# GENERATE SECRETS
# ============================================================================
# 10 strong random passwords (assigned silently).

ADMIN_PW=$(gen_pw 22)
SHARED_ADMIN_PW=$(gen_pw 22)
ESPEN_PW=$(gen_pw 22)
ROOT_DB_PW=$(gen_pw 28)
MAIL_DB_PW=$(gen_pw 28)
TEST_MAILBOX_PW=$(gen_pw 22)
ROUNDCUBE_DB_PW=$(gen_pw 28)
ROUNDCUBE_DES_KEY=$(gen_pw 24)
WP_DB_PW=$(gen_pw 28)
WP_ADMIN_PW=$(gen_pw 22)

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

DOMAIN="${DOMAIN}"
SERVER_IP="${SERVER_IP}"
SERVER_PURPOSE="${SERVER_PURPOSE}"
ADMIN_USER="${ADMIN_USER}"
SHARED_ADMIN_USER="${SHARED_ADMIN_USER}"
ESPEN_USER="${ESPEN_USER}"
SSH_PORT="${SSH_PORT}"
TIMEZONE="${TIMEZONE}"
NOTIFICATION_EMAIL="${NOTIFICATION_EMAIL}"
TEST_MAILBOX_LOCAL="${TEST_MAILBOX_LOCAL}"

# Backward compat: phase scripts still reference STAFF_USER
# (resolves to the shareable admin so existing logic keeps working)
STAFF_USER="${SHARED_ADMIN_USER}"

HOSTNAME_FQDN="${DOMAIN}"
HOSTNAME_SHORT="${HOSTNAME_SHORT}"
ALT_DOMAINS=("www.${DOMAIN}")
MAIL_HOSTNAME="mail.${DOMAIN}"
WP_DOMAIN_ALT="www.${DOMAIN}"
WP_DB_NAME="${WP_DB_NAME}"
WP_DB_USER="${WP_DB_USER}"
WP_ADMIN_USERNAME="${WP_ADMIN_USERNAME}"
WP_SITE_TITLE="${WP_SITE_TITLE}"
TEST_MAILBOX="${TEST_MAILBOX}"

CERTBOT_EMAIL="${NOTIFICATION_EMAIL}"
DMARC_RUA_EMAIL="${NOTIFICATION_EMAIL}"
CAA_IODEF_EMAIL="${NOTIFICATION_EMAIL}"
WP_ADMIN_EMAIL="${NOTIFICATION_EMAIL}"

# Web-root paths. Phase 2 creates these directories and uses them as Apache's
# default-vhost docroot and certbot --webroot-path. Later phases that need to
# place files reachable via HTTP (e.g. phase 7c, when certbot issues the
# team.<domain> cert) read DEFAULT_SITE_DIR from here. Keep these in sync with
# phase 2's declarations - they MUST match.
WEB_ROOT="/srv/www"
DEFAULT_SITE_DIR="/srv/www/default"
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
ESPEN_PW="${ESPEN_PW}"
# Backward compat: STAFF_PW maps to the shareable admin's password
STAFF_PW="${SHARED_ADMIN_PW}"

ROOT_DB_PW="${ROOT_DB_PW}"
MAIL_DB_PW="${MAIL_DB_PW}"
TEST_MAILBOX_PW="${TEST_MAILBOX_PW}"
ROUNDCUBE_DB_PW="${ROUNDCUBE_DB_PW}"
ROUNDCUBE_DES_KEY="${ROUNDCUBE_DES_KEY}"
WP_DB_PW="${WP_DB_PW}"
WP_ADMIN_PW="${WP_ADMIN_PW}"
SECRETS_LOCAL_EOF

chmod 600 "$SECRETS_FILE"
echo "${GREEN}Wrote $SECRETS_FILE (mode 0600)${RESET}"

# CREDENTIALS.txt - human-readable summary
XAI_DISPLAY="${XAI_API_KEY}"
[ -z "$XAI_DISPLAY" ] && XAI_DISPLAY="(not configured)"

cat > "$CREDENTIALS_FILE" << CREDENTIALS_EOF
==============================================================
  CREDENTIALS FOR ${DOMAIN} (${SERVER_IP})
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

  Username:  ${ESPEN_USER}     (Plone developer access)
  Password:  ${ESPEN_PW}

  ${ESPEN_USER} has NO sudo. Member of 'plone' group, can do all Plone
  work in /home/plone/ as themselves (no sudo needed thanks to
  group-writable setgid permissions on /home/plone/<tenant>/).

==============================================================
  4. WEBMAIL TEST MAILBOX  (logging into Roundcube)
==============================================================
  WHAT IT'S FOR:    Logging into the Roundcube webmail to
                    test that email works.
  WHERE YOU USE IT: https://${DOMAIN}/mail/

  Email address: ${TEST_MAILBOX}
  Password:      ${TEST_MAILBOX_PW}

==============================================================
  BACKEND PASSWORDS (mostly software-only, listed for recovery)
==============================================================
  Most of these are used by software internally and you'll never
  type them into a login screen. The exception is WordPress admin,
  which IS a login you'll use - it lives here for convenience so all
  generated passwords are in one place.

  MariaDB root:        ${ROOT_DB_PW}
  Mail database:       ${MAIL_DB_PW}
  Roundcube database:  ${ROUNDCUBE_DB_PW}
  Roundcube DES key:   ${ROUNDCUBE_DES_KEY}
  WordPress database:  ${WP_DB_PW}
  WordPress admin:     ${WP_ADMIN_PW}    (user: ${WP_ADMIN_USERNAME})
                                          login: https://${DOMAIN}/wp-admin/

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
  QUICK REFERENCE - ${DOMAIN}
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

  SSH (Plone developer, no sudo, plone group member):
    ssh -p ${SSH_PORT} ${ESPEN_USER}@${SERVER_IP}
    Password: ${ESPEN_PW}

  Web (placeholder/WordPress site):
    https://${DOMAIN}/

  Webmail (Roundcube):
    https://${DOMAIN}/mail/
    Username: ${TEST_MAILBOX_LOCAL}    (or full: ${TEST_MAILBOX})
    Password: ${TEST_MAILBOX_PW}

  WordPress admin:
    https://${DOMAIN}/wp-admin/
    Username: ${WP_ADMIN_USERNAME}
    Password: ${WP_ADMIN_PW}

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
    sudo find /var/vmail/${DOMAIN} -name 'new' -type d
    sudo ls -la /var/vmail/${DOMAIN}/${TEST_MAILBOX_LOCAL}/new/

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
    nslookup ${DOMAIN}
    nslookup www.${DOMAIN}
    nslookup mail.${DOMAIN}

  From the server (more detail):
    dig @8.8.8.8 ${DOMAIN}
    dig @8.8.8.8 MX ${DOMAIN}
    dig @8.8.8.8 TXT ${DOMAIN}
    dig @8.8.8.8 TXT default._domainkey.${DOMAIN}
    dig @8.8.8.8 TXT _dmarc.${DOMAIN}

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

echo ""
echo "${BOLD}${YELLOW}=============================================================${RESET}"
echo "${BOLD}${YELLOW}  IMPORTANT - DOWNLOAD CREDENTIALS BEFORE NUKING THIS SERVER${RESET}"
echo "${BOLD}${YELLOW}=============================================================${RESET}"
cat <<EOF
  Two files are ready for download. They are readable as
  ${BOLD}${DOWNLOAD_AS_USER}${RESET}:
    ${CYAN}${DOWNLOAD_CRED_FILE}${RESET}
    ${CYAN}${DOWNLOAD_QREF_FILE}${RESET}
  ${BOLD}When convenient, do this:${RESET}
    1. Open MobaXterm's left sidebar (SFTP browser).
    2. Navigate to ${CYAN}${DOWNLOAD_DIR}/${RESET}
    3. Right-click each file -> Download. Save them somewhere
       you control (password manager, encrypted folder, etc).
  These files will not be regenerated. Build continues automatically.
EOF
echo ""

# ============================================================================
# DONE
# ============================================================================
cat <<EOF

${BOLD}${GREEN}=============================================================
  PHASE 0 COMPLETE
=============================================================${RESET}

Next:  ${BOLD}sudo bash ${REPO_ROOT}/scripts/run-phases.sh${RESET}

EOF
