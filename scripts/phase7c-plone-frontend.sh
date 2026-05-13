#!/bin/bash
#
# phase7c-plone-frontend.sh - Phase 7c: Make Plone reachable on the public web
#
# What this phase does:
#   1. Rewrite buildout.cfg http-address to 127.0.0.1:8080 (lock down to loopback)
#   2. Re-run buildout so bin/instance picks up the new address
#   3. Install a systemd unit: plone-<sitename>.service
#   4. Issue a Let's Encrypt cert for team.<domain> via certbot
#   5. Install Apache vhost at /etc/apache2/sites-available/team.<domain>.conf
#      that reverse-proxies to 127.0.0.1:8080 via Plone's VirtualHostMonster
#   6. Reload Apache, start the systemd unit, verify end-to-end
#
# Prerequisites:
#   - Phases 0-2 ran (Apache + Let's Encrypt + ufw)
#   - Phase 7a ran (plone user + OS deps)
#   - Phase 7b ran (Plone buildout, bin/instance exists)
#   - Wildcard DNS *.<domain> resolves to this server's public IP
#
# End state:
#   - Plone running as a systemd service, bound to 127.0.0.1:8080 only
#   - https://team.<MAIL_DOMAIN>/ serves Plone via Apache reverse proxy
#   - WordPress at https://<MAIL_DOMAIN>/ is untouched
#   - Roundcube at https://<MAIL_DOMAIN>/mail/ is untouched
#   - The operator's last manual step: create the Plone Site object in the
#     Zope instance via https://team.<MAIL_DOMAIN>/ (admin / PLONE_ADMIN_PW)
#
# Idempotent. Safe to re-run. Each step checks current state before acting.
# Run as root via run-phases.sh, or directly: sudo bash phase7c-plone-frontend.sh
#

set -u

# ============================================================================
# CONFIGURATION
# ============================================================================
PLONE_USER="plone"
PLONE_HOME="/home/plone"
PLONE_INSTANCE_DIR=""  # Set after tenant.local is sourced (see below)
PLONE_SITE_ID="Plone"  # Site ID inside the Zope instance (Plone's default)

# === BEGIN tenant.local/secrets.local source block ===
__PHASE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
__PHASE_REPO_ROOT="$(dirname "$__PHASE_SCRIPT_DIR")"
if [ -f "$__PHASE_REPO_ROOT/tenant.local" ]; then
    # shellcheck disable=SC1091
    source "$__PHASE_REPO_ROOT/tenant.local"
fi
if [ -f "$__PHASE_REPO_ROOT/secrets.local" ]; then
    # shellcheck disable=SC1091
    source "$__PHASE_REPO_ROOT/secrets.local"
fi
REPO_ROOT="$__PHASE_REPO_ROOT"
unset __PHASE_SCRIPT_DIR __PHASE_REPO_ROOT
# === END tenant.local/secrets.local source block ===

# Compute Plone path values now that tenant.local has been sourced.
if [ -z "${MAIL_DOMAIN:-}" ]; then
    echo "FATAL: MAIL_DOMAIN is not set. tenant.local must define it before phase 7c runs."
    exit 1
fi
if [ -z "${NOTIFICATION_EMAIL:-}" ]; then
    echo "FATAL: NOTIFICATION_EMAIL is not set. Needed for certbot."
    exit 1
fi

PLONE_SITE_NAME="${PLONE_SITE_NAME:-$(echo "$MAIL_DOMAIN" | cut -d. -f1)}"
PLONE_INSTANCE_DIR="${PLONE_HOME}/${PLONE_SITE_NAME}"

# Subdomain Plone is published at
PLONE_PUBLIC_HOST="team.${MAIL_DOMAIN}"

# systemd unit name
PLONE_SYSTEMD_UNIT="plone-${PLONE_SITE_NAME}"

# Apache vhost paths
APACHE_VHOST_FILE="/etc/apache2/sites-available/${PLONE_PUBLIC_HOST}.conf"

# Buildout config + Zope listen port
BUILDOUT_CFG="$PLONE_INSTANCE_DIR/buildout.cfg"
ZOPE_LOOPBACK_PORT=8080

# ============================================================================
# REPORT TRACKING
# ============================================================================
REPORT=()

log_done()    { REPORT+=("[DONE]    $1"); echo "  ✓ $1"; }
log_skip()    { REPORT+=("[SKIPPED] $1 (already done)"); echo "  - $1 (already done)"; }
log_warn()    { REPORT+=("[WARN]    $1"); echo "  ! $1"; }
log_fail()    { REPORT+=("[FAIL]    $1"); echo "  ✗ $1"; }

step() { echo ""; echo "=== $1 ==="; }

# ============================================================================
# Must run as root
# ============================================================================
if [ "$EUID" -ne 0 ]; then
    echo "This phase must run as root. Try: sudo bash $0"
    exit 1
fi

echo ""
echo "==================================================================="
echo "  PHASE 7C: Expose Plone on the public web"
echo "==================================================================="
echo "  Public host:    https://$PLONE_PUBLIC_HOST/"
echo "  Site ID (Zope): $PLONE_SITE_ID"
echo "  Loopback port:  127.0.0.1:$ZOPE_LOOPBACK_PORT"
echo "  Systemd unit:   $PLONE_SYSTEMD_UNIT.service"
echo "  Apache vhost:   $APACHE_VHOST_FILE"
echo ""

# ============================================================================
# STEP 1: Verify prerequisites
# ============================================================================
step "Step 1: Verifying prerequisites from phases 0-2 + 7a/7b"

# Apache + certbot must be installed (phase 2)
for cmd in apache2 certbot; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_fail "$cmd not found. Did phase 2 run?"
        exit 1
    fi
done
log_done "apache2 and certbot are installed"

# Apache is running
if ! systemctl is-active --quiet apache2; then
    log_fail "apache2 is not running"
    exit 1
fi
log_done "apache2 service is active"

# plone user exists (phase 7a)
if ! id "$PLONE_USER" >/dev/null 2>&1; then
    log_fail "User '$PLONE_USER' does not exist. Did phase 7a run?"
    exit 1
fi

# bin/instance exists (phase 7b)
if [ ! -x "$PLONE_INSTANCE_DIR/bin/instance" ]; then
    log_fail "$PLONE_INSTANCE_DIR/bin/instance does not exist. Did phase 7b run?"
    exit 1
fi
log_done "Plone install from phase 7b is present"

# Required Apache modules
for mod in proxy proxy_http rewrite ssl headers; do
    if ! apache2ctl -M 2>/dev/null | grep -q "${mod}_module"; then
        log_warn "Apache module '$mod' not enabled. Enabling now."
        a2enmod "$mod" >/dev/null 2>&1 || { log_fail "Failed to enable apache2 mod $mod"; exit 1; }
    fi
done
log_done "Required Apache modules are enabled (proxy, proxy_http, rewrite, ssl, headers)"

# ============================================================================
# STEP 2: Rewrite buildout.cfg http-address to 127.0.0.1:8080
# ============================================================================
step "Step 2: Locking Plone to loopback (127.0.0.1:$ZOPE_LOOPBACK_PORT)"

if ! [ -f "$BUILDOUT_CFG" ]; then
    log_fail "$BUILDOUT_CFG missing. Did phase 7b run?"
    exit 1
fi

CURRENT_HTTP_ADDR=$(grep -E "^http-address" "$BUILDOUT_CFG" | head -1 | sed 's/^[^=]*=[[:space:]]*//')
DESIRED_HTTP_ADDR="127.0.0.1:$ZOPE_LOOPBACK_PORT"

if [ "$CURRENT_HTTP_ADDR" = "$DESIRED_HTTP_ADDR" ]; then
    log_skip "buildout.cfg http-address already set to $DESIRED_HTTP_ADDR"
    REBUILD_BUILDOUT=false
else
    # In-place edit, anchored to start-of-line and the literal http-address key
    sed -i "s|^http-address = .*$|http-address = $DESIRED_HTTP_ADDR|" "$BUILDOUT_CFG"
    # Verify the edit took
    NEW_HTTP_ADDR=$(grep -E "^http-address" "$BUILDOUT_CFG" | head -1 | sed 's/^[^=]*=[[:space:]]*//')
    if [ "$NEW_HTTP_ADDR" != "$DESIRED_HTTP_ADDR" ]; then
        log_fail "Failed to rewrite http-address in $BUILDOUT_CFG (got: $NEW_HTTP_ADDR)"
        exit 1
    fi
    log_done "Rewrote http-address from '$CURRENT_HTTP_ADDR' to '$DESIRED_HTTP_ADDR'"
    REBUILD_BUILDOUT=true
fi

# ============================================================================
# STEP 3: Re-run buildout if config changed
# ============================================================================
step "Step 3: Re-running buildout to apply http-address change"

if [ "$REBUILD_BUILDOUT" = "true" ]; then
    if ! sudo -u "$PLONE_USER" bash -c "cd '$PLONE_INSTANCE_DIR' && bin/buildout"; then
        log_fail "bin/buildout failed when re-running with new http-address"
        exit 1
    fi
    log_done "Re-ran buildout; bin/instance now binds to $DESIRED_HTTP_ADDR"
else
    log_skip "No buildout rerun needed (http-address was already correct)"
fi

# ============================================================================
# STEP 4: Install systemd unit
# ============================================================================
step "Step 4: Installing systemd unit $PLONE_SYSTEMD_UNIT.service"

SYSTEMD_UNIT_FILE="/etc/systemd/system/${PLONE_SYSTEMD_UNIT}.service"

if [ -f "$SYSTEMD_UNIT_FILE" ] && grep -q "phase7c-marker" "$SYSTEMD_UNIT_FILE" 2>/dev/null; then
    log_skip "systemd unit $PLONE_SYSTEMD_UNIT.service already exists"
else
    cat > "$SYSTEMD_UNIT_FILE" <<EOF
# phase7c-marker - managed by phase7c-plone-frontend.sh
[Unit]
Description=Plone instance for $PLONE_SITE_NAME ($PLONE_PUBLIC_HOST)
After=network.target

[Service]
Type=forking
User=$PLONE_USER
Group=$PLONE_USER
WorkingDirectory=$PLONE_INSTANCE_DIR
ExecStart=$PLONE_INSTANCE_DIR/bin/instance start
ExecStop=$PLONE_INSTANCE_DIR/bin/instance stop
ExecReload=$PLONE_INSTANCE_DIR/bin/instance restart
PIDFile=$PLONE_INSTANCE_DIR/var/instance/Z4.pid
Restart=on-failure
RestartSec=10
TimeoutStartSec=120
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$SYSTEMD_UNIT_FILE"

    # Belt and suspenders: catch silent zero-byte heredoc failures
    if [ ! -s "$SYSTEMD_UNIT_FILE" ]; then
        log_fail "Heredoc wrote zero bytes to $SYSTEMD_UNIT_FILE"
        exit 1
    fi
    log_done "Wrote $SYSTEMD_UNIT_FILE"
fi

# Reload systemd daemon and enable the unit
systemctl daemon-reload
if systemctl is-enabled --quiet "$PLONE_SYSTEMD_UNIT"; then
    log_skip "systemd unit $PLONE_SYSTEMD_UNIT already enabled"
else
    systemctl enable "$PLONE_SYSTEMD_UNIT" >/dev/null 2>&1
    log_done "Enabled $PLONE_SYSTEMD_UNIT.service (will start on boot)"
fi

# Stop any foreground bin/instance that might still be running from manual tests
# (look for a process running as plone with bin/instance in the cmdline).
# pkill returns 1 if nothing matched; that's fine, we ignore it.
pkill -u "$PLONE_USER" -f "$PLONE_INSTANCE_DIR/parts/instance/bin/interpreter" 2>/dev/null || true
sleep 1

# Start (or restart) the service
if systemctl is-active --quiet "$PLONE_SYSTEMD_UNIT"; then
    systemctl restart "$PLONE_SYSTEMD_UNIT"
    log_done "Restarted $PLONE_SYSTEMD_UNIT.service"
else
    if ! systemctl start "$PLONE_SYSTEMD_UNIT"; then
        log_fail "Failed to start $PLONE_SYSTEMD_UNIT.service. Check: journalctl -u $PLONE_SYSTEMD_UNIT -n 50"
        exit 1
    fi
    log_done "Started $PLONE_SYSTEMD_UNIT.service"
fi

# Wait for Plone to actually accept connections on the loopback port.
# Zope takes ~10-20 seconds to start; give it up to 60.
echo "  Waiting for Plone to accept connections on 127.0.0.1:$ZOPE_LOOPBACK_PORT..."
WAIT=0
while [ "$WAIT" -lt 60 ]; do
    if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$ZOPE_LOOPBACK_PORT/" 2>/dev/null | grep -qE "^[2-4]"; then
        break
    fi
    sleep 2
    WAIT=$((WAIT + 2))
done
if [ "$WAIT" -ge 60 ]; then
    log_fail "Plone did not start responding on 127.0.0.1:$ZOPE_LOOPBACK_PORT after 60 seconds"
    log_fail "Check: journalctl -u $PLONE_SYSTEMD_UNIT -n 50"
    exit 1
fi
log_done "Plone is responding on 127.0.0.1:$ZOPE_LOOPBACK_PORT (took ${WAIT}s)"

# ============================================================================
# STEP 5: Obtain Let's Encrypt cert for team.<MAIL_DOMAIN>
# ============================================================================
step "Step 5: Obtaining Let's Encrypt cert for $PLONE_PUBLIC_HOST"

LE_CERT_DIR="/etc/letsencrypt/live/$PLONE_PUBLIC_HOST"
if [ -d "$LE_CERT_DIR" ] && [ -f "$LE_CERT_DIR/fullchain.pem" ]; then
    log_skip "Certificate for $PLONE_PUBLIC_HOST already exists at $LE_CERT_DIR"
else
    # certbot certonly with --webroot: gets the cert without touching Apache
    # config. Use the WordPress site's webroot since Apache's default vhost
    # already serves the ACME challenge from there regardless of hostname.
    # This matches phase 2's certbot pattern. We avoid the --apache plugin
    # because it has a known bug on certbot 4.x in Ubuntu 26.04 (vhost
    # ambiguity errors in non-interactive mode).
    WEBROOT_PATH="/srv/www/$MAIL_DOMAIN"
    if ! certbot certonly \
            --webroot \
            --webroot-path "$WEBROOT_PATH" \
            --non-interactive \
            --agree-tos \
            --email "$NOTIFICATION_EMAIL" \
            -d "$PLONE_PUBLIC_HOST"; then
        log_fail "certbot failed to obtain cert for $PLONE_PUBLIC_HOST"
        log_fail "Common causes: DNS not pointing at this server, port 80 blocked,"
        log_fail "or Let's Encrypt rate limit on this domain."
        exit 1
    fi
    log_done "Obtained Let's Encrypt cert for $PLONE_PUBLIC_HOST"
fi

# ============================================================================
# STEP 6: Install Apache vhost for team.<MAIL_DOMAIN>
# ============================================================================
step "Step 6: Installing Apache vhost $APACHE_VHOST_FILE"

# certbot's --apache plugin may have created a vhost for us. We'll overwrite
# it with our own that includes the VirtualHostMonster proxy configuration.
if [ -f "$APACHE_VHOST_FILE" ] && grep -q "phase7c-marker" "$APACHE_VHOST_FILE" 2>/dev/null; then
    log_skip "Apache vhost $APACHE_VHOST_FILE already managed by phase7c"
else
    cat > "$APACHE_VHOST_FILE" <<EOF
# phase7c-marker - managed by phase7c-plone-frontend.sh
# Reverse proxy for Plone instance at /home/plone/$PLONE_SITE_NAME
# Plone listens on 127.0.0.1:$ZOPE_LOOPBACK_PORT (locked down in phase 7c step 2)

<VirtualHost *:80>
    ServerName $PLONE_PUBLIC_HOST
    RewriteEngine On
    RewriteCond %{HTTPS} !=on
    RewriteRule ^/?(.*) https://$PLONE_PUBLIC_HOST/\$1 [R=301,L]
</VirtualHost>

<VirtualHost *:443>
    ServerName $PLONE_PUBLIC_HOST

    SSLEngine on
    SSLCertificateFile $LE_CERT_DIR/fullchain.pem
    SSLCertificateKeyFile $LE_CERT_DIR/privkey.pem

    # Plone VirtualHostMonster reverse proxy.
    # The URL inside Zope says "this request actually came from
    # https://\$PLONE_PUBLIC_HOST/" so Plone generates correct absolute URLs
    # in links, redirects, and CSS references.
    #
    # Path translation:
    #   browser hits https://$PLONE_PUBLIC_HOST/SOMEPATH
    #   apache proxies to http://127.0.0.1:$ZOPE_LOOPBACK_PORT/VirtualHostBase/https/$PLONE_PUBLIC_HOST:443/$PLONE_SITE_ID/VirtualHostRoot/SOMEPATH
    #   zope serves /$PLONE_SITE_ID/SOMEPATH but believes its public URL is https://$PLONE_PUBLIC_HOST/SOMEPATH
    RewriteEngine On
    RewriteRule ^/(.*)\$ http://127.0.0.1:$ZOPE_LOOPBACK_PORT/VirtualHostBase/https/$PLONE_PUBLIC_HOST:443/$PLONE_SITE_ID/VirtualHostRoot/\$1 [L,P]

    # Pass the real client IP and proto to Plone for logging / security checks
    RequestHeader set X-Forwarded-Proto "https"
    RequestHeader set X-Forwarded-Port "443"

    ProxyPreserveHost On
    ProxyTimeout 300

    ErrorLog \${APACHE_LOG_DIR}/$PLONE_PUBLIC_HOST-error.log
    CustomLog \${APACHE_LOG_DIR}/$PLONE_PUBLIC_HOST-access.log combined
</VirtualHost>
EOF
    chmod 644 "$APACHE_VHOST_FILE"

    if [ ! -s "$APACHE_VHOST_FILE" ]; then
        log_fail "Heredoc wrote zero bytes to $APACHE_VHOST_FILE"
        exit 1
    fi
    if ! grep -q "phase7c-marker" "$APACHE_VHOST_FILE"; then
        log_fail "Apache vhost was written but does not contain phase7c-marker"
        exit 1
    fi
    log_done "Wrote $APACHE_VHOST_FILE"
fi

# Enable the vhost
if [ -L "/etc/apache2/sites-enabled/${PLONE_PUBLIC_HOST}.conf" ]; then
    log_skip "Apache vhost $PLONE_PUBLIC_HOST is already enabled"
else
    a2ensite "${PLONE_PUBLIC_HOST}.conf" >/dev/null 2>&1
    log_done "Enabled apache2 site $PLONE_PUBLIC_HOST"
fi

# Test config and reload
if ! apache2ctl configtest 2>&1 | grep -qE "Syntax OK|Syntax ok"; then
    log_fail "apache2ctl configtest failed. Not reloading."
    apache2ctl configtest 2>&1 | tail -10
    exit 1
fi
systemctl reload apache2
log_done "Reloaded apache2 with new vhost"

# ============================================================================
# STEP 7: Verify ufw posture (port 8080 stays blocked from outside)
# ============================================================================
step "Step 7: Verifying ufw posture (port 8080 must NOT be open externally)"

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    if ufw status | grep -E "^\s*8080" | grep -vq "DENY\|REJECT" 2>/dev/null; then
        if ufw status | grep -qE "^\s*8080.*ALLOW"; then
            log_warn "ufw appears to ALLOW port 8080 externally. Plone should only be reached via Apache."
            log_warn "Consider: sudo ufw delete allow 8080  (after verifying Apache works)"
        fi
    fi
    log_done "ufw is active. Port 8080 reachability checked."
else
    log_warn "ufw is not active. Port 8080 may be reachable from the internet."
fi

# ============================================================================
# VERIFICATION
# ============================================================================
echo ""
echo "==================================================================="
echo "  AUTOMATED VERIFICATION"
echo "==================================================================="
echo ""

VERIFY_PASSED=0
VERIFY_FAILED=0

vp() { echo "  [PASS] $1"; VERIFY_PASSED=$((VERIFY_PASSED + 1)); }
vf() { echo "  [FAIL] $1"; VERIFY_FAILED=$((VERIFY_FAILED + 1)); }

# buildout.cfg http-address is 127.0.0.1:8080
if grep -qE "^http-address = 127\.0\.0\.1:$ZOPE_LOOPBACK_PORT$" "$BUILDOUT_CFG"; then
    vp "buildout.cfg http-address bound to 127.0.0.1:$ZOPE_LOOPBACK_PORT"
else
    vf "buildout.cfg http-address NOT bound to 127.0.0.1:$ZOPE_LOOPBACK_PORT"
fi

# systemd unit exists and is enabled
if [ -f "$SYSTEMD_UNIT_FILE" ] && grep -q "phase7c-marker" "$SYSTEMD_UNIT_FILE" 2>/dev/null; then
    vp "systemd unit $PLONE_SYSTEMD_UNIT.service exists and is phase7c-managed"
else
    vf "systemd unit $PLONE_SYSTEMD_UNIT.service missing or not managed by phase7c"
fi

if systemctl is-enabled --quiet "$PLONE_SYSTEMD_UNIT"; then
    vp "systemd unit $PLONE_SYSTEMD_UNIT is enabled at boot"
else
    vf "systemd unit $PLONE_SYSTEMD_UNIT is NOT enabled at boot"
fi

if systemctl is-active --quiet "$PLONE_SYSTEMD_UNIT"; then
    vp "systemd unit $PLONE_SYSTEMD_UNIT is currently active"
else
    vf "systemd unit $PLONE_SYSTEMD_UNIT is NOT active"
fi

# Plone responds on loopback
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$ZOPE_LOOPBACK_PORT/" 2>/dev/null || echo "000")
if echo "$HTTP_CODE" | grep -qE "^[2-4]"; then
    vp "Plone responds on http://127.0.0.1:$ZOPE_LOOPBACK_PORT/ (HTTP $HTTP_CODE)"
else
    vf "Plone does NOT respond on http://127.0.0.1:$ZOPE_LOOPBACK_PORT/ (got: $HTTP_CODE)"
fi

# Apache vhost exists and is enabled
if [ -L "/etc/apache2/sites-enabled/${PLONE_PUBLIC_HOST}.conf" ]; then
    vp "Apache vhost $PLONE_PUBLIC_HOST is enabled"
else
    vf "Apache vhost $PLONE_PUBLIC_HOST is NOT enabled"
fi

# Apache vhost is phase7c-managed
if [ -f "$APACHE_VHOST_FILE" ] && grep -q "phase7c-marker" "$APACHE_VHOST_FILE" 2>/dev/null; then
    vp "Apache vhost is managed by phase7c"
else
    vf "Apache vhost is NOT managed by phase7c"
fi

# Let's Encrypt cert exists
if [ -f "$LE_CERT_DIR/fullchain.pem" ]; then
    vp "Let's Encrypt cert exists for $PLONE_PUBLIC_HOST"
else
    vf "Let's Encrypt cert NOT found for $PLONE_PUBLIC_HOST"
fi

# Apache responds on https://team.<domain>/
# Use -k since LE certs are real and should validate, but also fail-safe
# if there's a chain issue, we still want to know if Apache routes the request.
HTTPS_CODE=$(curl -s -o /dev/null -w "%{http_code}" "https://$PLONE_PUBLIC_HOST/" --resolve "$PLONE_PUBLIC_HOST:443:127.0.0.1" 2>/dev/null || echo "000")
if echo "$HTTPS_CODE" | grep -qE "^[2-4]"; then
    vp "https://$PLONE_PUBLIC_HOST/ responds via Apache reverse proxy (HTTP $HTTPS_CODE)"
else
    vf "https://$PLONE_PUBLIC_HOST/ does NOT respond (got: $HTTPS_CODE). Apache may not be routing correctly."
fi

echo ""
echo "  Verification: $VERIFY_PASSED passed, $VERIFY_FAILED failed"
echo ""

if [ "$VERIFY_FAILED" -gt 0 ]; then
    echo "  *** $VERIFY_FAILED CHECK(S) FAILED. Review failures above before proceeding. ***"
fi

# ============================================================================
# MANUAL NEXT STEPS
# ============================================================================
echo ""
echo "==================================================================="
echo "  MANUAL NEXT STEPS"
echo "==================================================================="
echo ""
echo "  Plone is now publicly reachable. The last manual step is to create"
echo "  the actual Plone Site object inside the Zope instance:"
echo ""
echo "  1. Open: https://$PLONE_PUBLIC_HOST/"
echo "  2. Click 'Create Classic UI Plone Site' on the welcome page."
echo "  3. When prompted for Zope credentials, log in as:"
echo "       Username: admin"
echo "       Password: (in $REPO_ROOT/CREDENTIALS.txt under PLONE_ADMIN_PW)"
echo "  4. On the create-site form, set:"
echo "       Path identifier:  $PLONE_SITE_ID"
echo "       Title:            Whatever you want"
echo "       Language:         English (or your preference)"
echo "  5. Click 'Create Plone Site'. After ~30 seconds, you'll have a"
echo "     working themed Plone site at https://$PLONE_PUBLIC_HOST/"
echo ""
echo "  WordPress at https://$MAIL_DOMAIN/ is untouched."
echo "  Roundcube at https://$MAIL_DOMAIN/mail/ is untouched."
echo ""
echo "  Useful commands going forward:"
echo "    sudo systemctl status  $PLONE_SYSTEMD_UNIT"
echo "    sudo systemctl restart $PLONE_SYSTEMD_UNIT"
echo "    sudo journalctl -u $PLONE_SYSTEMD_UNIT -f"
echo ""
echo "==================================================================="
echo ""
