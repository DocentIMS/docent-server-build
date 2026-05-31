#!/bin/bash
#
# phase4b-smtp-relay.sh - Phase 4b: outbound SMTP relay via SMTP2GO (port 587)
#
# Why this phase exists:
#   Hetzner Cloud blocks outbound ports 25 and 465 by default and won't unblock
#   25 on request for a while. Direct Postfix -> recipient-MX delivery silently
#   fails (mail queues, looks "sent", never arrives). Ports 587 and 2525 stay
#   open, so we relay all outbound mail through SMTP2GO on 587 with SASL auth.
#
# Runs AFTER phase4.sh (the Postfix/Dovecot stack must already exist) and
# before phase-post-hetzner-dkim.sh / phase5.sh.
#
# Idempotent. Safe to re-run.
#
# Operator prerequisites:
#   1. SMTP2GO account, with an SMTP user (username + password) defined in
#      org-secrets.local:
#          SMTP2GO_USER="..."
#          SMTP2GO_PASS="..."
#      Use an ALPHANUMERIC password - symbols (':', '(', ')', '~', etc.) make
#      sasl_passwd quoting fragile. Resetting to an alphanumeric in SMTP2GO
#      was the single biggest time-saver during the initial chelseamallproject
#      relay setup.
#   2. The tenant's $DOMAIN must be a Verified Sender in SMTP2GO so SPF and
#      domain-aligned DKIM can authenticate. This phase prompts the operator
#      with the exact CNAME + SPF records to add at the authoritative DNS host
#      (Hetzner in our setup) - the values are per-account from SMTP2GO and
#      can't be auto-fetched without an SMTP2GO API key.
#
# Run as root: sudo bash phase4b-smtp-relay.sh
#

set -u

# ============================================================================
# CONFIGURATION
# ============================================================================
RELAY_HOST="${SMTP2GO_RELAY_HOST:-mail.smtp2go.com}"
RELAY_PORT="${SMTP2GO_RELAY_PORT:-587}"
SPF_INCLUDE="${SMTP2GO_SPF_INCLUDE:-spf.smtp2go.com}"
SASL_PASSWD_FILE="/etc/postfix/sasl_passwd"
MAIN_CF="/etc/postfix/main.cf"
RELAY_MARKER="# phase4b-marker"
POSTFIX_BACKUP="/etc/postfix/main.cf.phase4b.bak"

# Load shared helpers + per-tenant config (sources tenant.local, secrets.local).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

# Org-wide secrets (SMTP2GO_USER / SMTP2GO_PASS shared across all tenants).
if [ -f "$REPO_ROOT/org-secrets.local" ]; then
    # shellcheck disable=SC1091
    source "$REPO_ROOT/org-secrets.local"
fi

# ============================================================================
# REPORT TRACKING
# ============================================================================
REPORT=()

# Local prompt helper (kept local to avoid coupling to phase-pre-hetzner).
ask_yes_no() {
    local prompt="$1" reply
    while true; do
        read -r -p "${prompt} (type yes or no): " reply
        case "$reply" in
            [Yy][Ee][Ss]) return 0 ;;
            [Nn][Oo])     return 1 ;;
            *) echo "Please type yes or no." >&2 ;;
        esac
    done
}

# ============================================================================
# SAFETY CHECKS
# ============================================================================
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root (use sudo)."
    exit 1
fi

if [ -z "${DOMAIN:-}" ]; then
    echo "ERROR: DOMAIN is not set. tenant.local must define it (phase 0 writes it)."
    exit 1
fi

if ! command -v postconf >/dev/null 2>&1; then
    echo "ERROR: Postfix not installed. Phase 4 must run first."
    exit 1
fi

if [ -z "${SMTP2GO_USER:-}" ] || [ -z "${SMTP2GO_PASS:-}" ]; then
    cat <<EOF
ERROR: SMTP2GO_USER and SMTP2GO_PASS must be set in $REPO_ROOT/org-secrets.local.

Add (alphanumeric password recommended):
    SMTP2GO_USER="<your-smtp2go-smtp-user>"
    SMTP2GO_PASS="<your-smtp2go-smtp-password>"
EOF
    exit 1
fi

# Soft-warn on non-alphanumeric SMTP password (sasl_passwd quoting fragility).
if [[ ! "$SMTP2GO_PASS" =~ ^[A-Za-z0-9._-]+$ ]]; then
    log_warn "SMTP2GO_PASS contains non-alphanumeric characters; sasl_passwd quoting can be fragile. An alphanumeric password is strongly recommended."
fi

echo "==================================================================="
echo "  Phase 4b - SMTP relay via SMTP2GO ($RELAY_HOST:$RELAY_PORT)"
echo "  Domain: $DOMAIN"
echo "  Date:   $(date)"
echo "==================================================================="

# Back up main.cf once (so we have a pre-relay snapshot to roll back to).
if [ ! -f "$POSTFIX_BACKUP" ]; then
    cp "$MAIN_CF" "$POSTFIX_BACKUP"
    log_done "Backed up $MAIN_CF -> $POSTFIX_BACKUP"
fi

# ============================================================================
# STEP 1: Write /etc/postfix/sasl_passwd (relay credentials)
# ============================================================================
step "Step 1: Writing $SASL_PASSWD_FILE"

EXPECTED_LINE="[$RELAY_HOST]:$RELAY_PORT $SMTP2GO_USER:$SMTP2GO_PASS"
if [ -f "$SASL_PASSWD_FILE" ] && grep -qxF "$EXPECTED_LINE" "$SASL_PASSWD_FILE"; then
    log_skip "sasl_passwd already contains the expected entry"
else
    # Quoted heredoc: preserves password chars literally (no $ expansion etc.).
    tee "$SASL_PASSWD_FILE" > /dev/null <<EOF
$EXPECTED_LINE
EOF
    log_done "Wrote $SASL_PASSWD_FILE"
fi

chmod 600 "$SASL_PASSWD_FILE"
chown root:root "$SASL_PASSWD_FILE"

# Postfix reads the compiled .db, not the text file. Run postmap on every
# write (cheap, idempotent).
if ! postmap "$SASL_PASSWD_FILE"; then
    log_fail "postmap $SASL_PASSWD_FILE failed"
    exit 1
fi
if [ -f "${SASL_PASSWD_FILE}.db" ]; then
    chmod 600 "${SASL_PASSWD_FILE}.db"
    chown root:root "${SASL_PASSWD_FILE}.db"
fi
log_done "Compiled $SASL_PASSWD_FILE (mode 600 owner root)"

# ============================================================================
# STEP 2: Configure Postfix main.cf for the SMTP2GO relay
# ============================================================================
step "Step 2: Configuring Postfix relay settings in $MAIN_CF"

# postconf -e replaces an existing setting or adds it. This avoids duplicate
# lines (which produce "repeating overriding earlier entry" warnings that
# flood the log).
postconf -e "relayhost = [$RELAY_HOST]:$RELAY_PORT"
postconf -e "smtp_sasl_auth_enable = yes"
postconf -e "smtp_sasl_password_maps = hash:$SASL_PASSWD_FILE"
postconf -e "smtp_sasl_security_options = noanonymous"
postconf -e "smtp_tls_security_level = encrypt"
postconf -e "smtp_sasl_mechanism_filter = plain, login"

# Drop a marker block (commented) so a future re-run / human reader can see
# this script owns the relay settings. Idempotent: only added once.
if ! grep -qF "$RELAY_MARKER" "$MAIN_CF"; then
    {
        echo ""
        echo "$RELAY_MARKER - SMTP relay via SMTP2GO on :$RELAY_PORT (phase4b-smtp-relay.sh)"
    } >> "$MAIN_CF"
fi
log_done "Applied relay settings (relayhost, smtp_sasl_*, smtp_tls_security_level=encrypt)"

# ============================================================================
# STEP 3: Reload Postfix
# ============================================================================
step "Step 3: Reloading Postfix"

if systemctl reload postfix; then
    log_done "Postfix reloaded"
else
    log_fail "Postfix reload failed - check 'journalctl -u postfix -n 50' for details"
    exit 1
fi

# ============================================================================
# STEP 4: Flush the queue through the new relay
# ============================================================================
step "Step 4: Flushing the mail queue through the new relay"

postqueue -f >/dev/null 2>&1 || true
sleep 5
QSTATUS="$(postqueue -p 2>/dev/null | tail -1)"
if echo "$QSTATUS" | grep -q "Mail queue is empty"; then
    log_done "Mail queue is empty (relay path is working)"
else
    log_warn "Queue is not empty after flush. Inspect with:  sudo postqueue -p"
    log_warn "If you see '535 Incorrect authentication data', that means we reached the"
    log_warn "relay - credentials are wrong (re-check SMTP2GO_USER / SMTP2GO_PASS)."
fi

# ============================================================================
# STEP 5: DNS records the operator must add at the authoritative DNS host
# ============================================================================
step "Step 5: DNS records to add (manual, at the authoritative DNS host)"

cat <<EOF

  Postfix is now relaying through $RELAY_HOST:$RELAY_PORT. For mail to land in
  the inbox at Gmail/Outlook/etc., add these records at the host that's
  AUTHORITATIVE for $DOMAIN. Verify the authoritative host with:

      nslookup -type=ns $DOMAIN

  In our setup that's Hetzner DNS. The selector IDs below (emXXXXXXX,
  sXXXXXXX) are per-account, shown by SMTP2GO under:
      Verified Senders -> $DOMAIN -> DNS configuration

  1) Three CNAMEs (Name = subdomain only, Value ends with a trailing dot):

         CNAME   emXXXXXXX              return.smtp2go.net.
         CNAME   sXXXXXXX._domainkey    dkim.smtp2go.net.
         CNAME   linktrack              smtp2go.net.   (optional - open/click tracking)

  2) SPF: edit the @ TXT record to include SMTP2GO's senders:

         v=spf1 mx include:$SPF_INCLUDE ~all

  DMARC (_dmarc) and MX records do NOT need to change.

EOF

if ! ask_yes_no "Have you added these DNS records?"; then
    log_warn "DNS records not confirmed. Mail will relay but will likely land in spam at major providers until SPF + DKIM align with $DOMAIN."
else
    log_done "Operator confirmed DNS records are in place"
fi

# ============================================================================
# STEP 6: Recommended deliverability test (operator-run)
# ============================================================================
step "Step 6: Recommended deliverability test"

cat <<EOF

  Once DNS has propagated (5 minutes to about an hour) send a test message
  to a Gmail address:

      echo "relay test from $DOMAIN" | mail -s "relay test" -r postmaster@$DOMAIN you@gmail.com

  Open the message at Gmail and use "Show original". You want both of these:

      SPF:  PASS  with the relay's IP
      DKIM: PASS  with the s=sXXXXXXX selector aligned to $DOMAIN

  If both pass, deliverability is good. If only SPF passes, DKIM CNAMEs aren't
  in DNS yet (or haven't propagated). If neither, the SPF TXT update hasn't
  taken effect.

EOF

# ============================================================================
# SUMMARY
# ============================================================================
echo ""
echo "==================================================================="
echo "  SUMMARY"
echo "==================================================================="
for line in "${REPORT[@]}"; do
    echo "  $line"
done

# ============================================================================
# AUTOMATED VERIFICATION
# ============================================================================
echo ""
echo "==================================================================="
echo "  AUTOMATED VERIFICATION"
echo "==================================================================="
echo ""

VERIFY_PASS=0
VERIFY_FAIL=0

verify "relayhost is [$RELAY_HOST]:$RELAY_PORT" \
    "[$RELAY_HOST]:$RELAY_PORT" \
    "$(postconf -h relayhost 2>/dev/null)"
verify "smtp_sasl_auth_enable" "yes" "$(postconf -h smtp_sasl_auth_enable 2>/dev/null)"
verify "smtp_sasl_password_maps" "hash:$SASL_PASSWD_FILE" "$(postconf -h smtp_sasl_password_maps 2>/dev/null)"
verify "smtp_sasl_security_options" "noanonymous" "$(postconf -h smtp_sasl_security_options 2>/dev/null)"
verify "smtp_tls_security_level (outbound) is encrypt" "encrypt" "$(postconf -h smtp_tls_security_level 2>/dev/null)"
verify "smtp_sasl_mechanism_filter" "plain, login" "$(postconf -h smtp_sasl_mechanism_filter 2>/dev/null)"

if [ -f "${SASL_PASSWD_FILE}.db" ]; then
    verify "${SASL_PASSWD_FILE}.db is mode 600" "600" "$(stat -c '%a' "${SASL_PASSWD_FILE}.db")"
fi

verify_cmd "postfix service is active" systemctl is-active --quiet postfix

echo ""
echo "  Verification: $VERIFY_PASS passed, $VERIFY_FAIL failed"
echo ""

if [ "$VERIFY_FAIL" -gt 0 ]; then
    echo "  *** $VERIFY_FAIL CHECK(S) FAILED. Review failures above before proceeding. ***"
    exit 1
fi

echo "  Phase 4b complete. Outbound mail now relays through $RELAY_HOST:$RELAY_PORT."
echo "  Next: run phase-post-hetzner-dkim.sh (server DKIM) and then phase 5 (Roundcube)."
echo ""
exit 0
