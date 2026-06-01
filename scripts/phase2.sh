#!/bin/bash
#
# phase2.sh - Phase 2: Web server (Apache) and TLS (Let's Encrypt) foundation
#
# Idempotent. Safe to re-run. Each step checks current state before acting.
# Produces a summary report and runs automated verification at the end.
#
# Run as root: sudo bash phase2.sh
#

set -u

# ============================================================================
# CONFIGURATION
# ============================================================================
DOMAIN="docenttemplate.com"
ALT_DOMAINS=("www.docenttemplate.com")
CERTBOT_EMAIL="wglover@docentims.com"

WEB_ROOT="/srv/www"
DEFAULT_SITE_DIR="$WEB_ROOT/default"
PLONE_HOME="/home/plone"
VMAIL_HOME="/var/vmail"
PLONE_USER="plone"

APACHE_REQUIRED_MODULES=(
    rewrite
    ssl
    headers
    proxy
    proxy_http
    proxy_wstunnel
)

# Load shared helpers and per-tenant config. lib/common.sh sources
# tenant.local/secrets.local (overriding the hardcoded defaults above) and
# provides colors, logging helpers, and verification helpers.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

# ============================================================================
# REPORT TRACKING
# ============================================================================
REPORT=()



# wait_for_dpkg_lock - block until /var/lib/dpkg/lock-frontend is released.
# unattended-upgrades (enabled by phase 1) can hold the lock for several
# minutes after a fresh server boot. Without this guard, apt commands fail
# silently with "E: Unable to acquire the dpkg frontend lock" and the script
# continues past the failed install, leading to confusing cascade errors
# downstream (configtest fails, services won't start, certbot can't validate).
# Hit on a real rebuild May 2026.
wait_for_dpkg_lock() {
    local max_wait=300
    local waited=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        if [ "$waited" -eq 0 ]; then
            echo "  Waiting for dpkg lock (held by another apt/dpkg process)..."
        fi
        sleep 5
        waited=$((waited + 5))
        if [ "$waited" -ge "$max_wait" ]; then
            echo "  Timeout: dpkg lock still held after ${max_wait}s. Aborting."
            exit 1
        fi
    done
    if [ "$waited" -gt 0 ]; then
        echo "  dpkg lock released after ${waited}s, continuing."
    fi
}


# ============================================================================
# SAFETY CHECK
# ============================================================================
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root (use sudo)."
    exit 1
fi

echo "==================================================================="
echo "  Phase 2 - Web server + TLS foundation for $DOMAIN"
echo "  $(date)"
echo "==================================================================="

# ============================================================================
# STEP 1: Install Apache
# ============================================================================
step "Step 1: Installing Apache"

export DEBIAN_FRONTEND=noninteractive
if dpkg -l apache2 2>/dev/null | grep -q "^ii"; then
    log_skip "Apache already installed"
else
    wait_for_dpkg_lock
    apt-get update -qq
    if ! apt-get install -y -qq -o Dpkg::Use-Pty=0 apache2 < /dev/null; then
        log_fail "apt-get install apache2 failed - see output above"
        exit 1
    fi
    log_done "Apache installed"
fi

# ============================================================================
# STEP 2: Enable required Apache modules
# ============================================================================
step "Step 2: Enabling required Apache modules"

MODULES_CHANGED=0
for mod in "${APACHE_REQUIRED_MODULES[@]}"; do
    if apache2ctl -M 2>/dev/null | grep -qE "^\s+${mod}_module"; then
        log_skip "Module $mod already enabled"
    else
        a2enmod -q "$mod" >/dev/null 2>&1
        log_done "Enabled module $mod"
        MODULES_CHANGED=1
    fi
done

# ============================================================================
# STEP 3: Install certbot
# ============================================================================
step "Step 3: Installing certbot + Apache plugin"

if dpkg -l certbot 2>/dev/null | grep -q "^ii" && dpkg -l python3-certbot-apache 2>/dev/null | grep -q "^ii"; then
    log_skip "certbot and python3-certbot-apache already installed"
else
    wait_for_dpkg_lock
    if ! apt-get install -y -qq -o Dpkg::Use-Pty=0 certbot python3-certbot-apache < /dev/null; then
        log_fail "apt-get install certbot failed - see output above"
        exit 1
    fi
    log_done "certbot + Apache plugin installed"
fi

# ============================================================================
# STEP 4: Create base directory structure
# ============================================================================
step "Step 4: Creating base directory structure"

# /srv/www
if [ -d "$WEB_ROOT" ]; then
    log_skip "$WEB_ROOT already exists"
else
    mkdir -p "$WEB_ROOT"
    chown root:root "$WEB_ROOT"
    chmod 755 "$WEB_ROOT"
    log_done "Created $WEB_ROOT"
fi

# /srv/www/default (placeholder site)
if [ -d "$DEFAULT_SITE_DIR" ]; then
    log_skip "$DEFAULT_SITE_DIR already exists"
else
    mkdir -p "$DEFAULT_SITE_DIR"
    chown -R www-data:www-data "$DEFAULT_SITE_DIR"
    log_done "Created $DEFAULT_SITE_DIR"
fi

# Create plone system user (no login shell, no password)
if id "$PLONE_USER" &>/dev/null; then
    log_skip "User $PLONE_USER already exists"
else
    useradd --system --home-dir "$PLONE_HOME" --shell /usr/sbin/nologin "$PLONE_USER"
    log_done "Created system user $PLONE_USER (no shell login)"
fi

# /home/plone
if [ -d "$PLONE_HOME" ]; then
    log_skip "$PLONE_HOME already exists"
else
    mkdir -p "$PLONE_HOME"
    chown "$PLONE_USER":"$PLONE_USER" "$PLONE_HOME"
    chmod 755 "$PLONE_HOME"
    log_done "Created $PLONE_HOME (owned by $PLONE_USER)"
fi

# /var/vmail
if [ -d "$VMAIL_HOME" ]; then
    log_skip "$VMAIL_HOME already exists"
else
    mkdir -p "$VMAIL_HOME"
    # Ownership will be set in Phase 4 when vmail user is created
    log_done "Created $VMAIL_HOME (ownership deferred to Phase 4)"
fi

# ============================================================================
# STEP 5: Create placeholder index page
# ============================================================================
step "Step 5: Creating placeholder index page"

INDEX_FILE="$DEFAULT_SITE_DIR/index.html"
if [ -f "$INDEX_FILE" ] && grep -q "phase2-marker" "$INDEX_FILE"; then
    log_skip "Placeholder index page already exists"
else
    cat > "$INDEX_FILE" <<EOF
<!DOCTYPE html>
<!-- phase2-marker -->
<html lang="en">
<head>
<meta charset="UTF-8">
<title>$DOMAIN</title>
<style>
  body { font-family: system-ui, sans-serif; max-width: 600px; margin: 4em auto; padding: 1em; color: #333; }
  h1 { color: #2a4d7a; }
  code { background: #f0f0f0; padding: 0.1em 0.4em; border-radius: 3px; }
</style>
</head>
<body>
<h1>$DOMAIN</h1>
<p>This server is online and serving HTTPS.</p>
<p>Status: template server, ready for site provisioning.</p>
</body>
</html>
EOF
    chown www-data:www-data "$INDEX_FILE"
    log_done "Wrote placeholder index page"
fi

# ============================================================================
# STEP 6: Configure Apache vhosts
# ============================================================================
# We write TWO separate vhost files:
#
#   000-default.conf   = catch-all (ServerName _default_)
#                        Serves the placeholder page for any request whose
#                        Host header doesn't match a more specific vhost
#                        (e.g., 'mail.${DOMAIN}' which has no Apache
#                        service - mail goes through Postfix/Dovecot).
#                        Stays enabled forever; phase 6 should NOT disable
#                        this when it takes over the primary domain for WP.
#
#   ${DOMAIN}.conf   = placeholder for the primary domain.
#                        Serves the same placeholder page until phase 6
#                        overwrites this file with the WordPress vhost.
#                        certbot will use this vhost to install the SSL
#                        version (${DOMAIN}-le-ssl.conf).
# ============================================================================
step "Step 6: Configuring Apache vhosts (catch-all + primary domain placeholder)"

DEFAULT_VHOST="/etc/apache2/sites-available/000-default.conf"
DEFAULT_VHOST_BACKUP="/etc/apache2/sites-available/000-default.conf.phase2.bak"
DOMAIN_VHOST="/etc/apache2/sites-available/${DOMAIN}.conf"

# Backup the original once
if [ ! -f "$DEFAULT_VHOST_BACKUP" ] && [ -f "$DEFAULT_VHOST" ]; then
    cp "$DEFAULT_VHOST" "$DEFAULT_VHOST_BACKUP"
    log_done "Backed up original $DEFAULT_VHOST"
fi

# --- 6a: Catch-all vhost (000-default.conf) ---------------------------------
cat > "$DEFAULT_VHOST" <<EOF
# phase2-marker - managed by phase2.sh
# Catch-all vhost: handles requests whose Host header doesn't match any
# other vhost. Serves the placeholder page from $DEFAULT_SITE_DIR.
# Phase 6 (WordPress) should NOT disable this - it's the fallback for
# mail.* and any other unknown subdomain.
<VirtualHost *:80>
    ServerName _default_
    DocumentRoot $DEFAULT_SITE_DIR

    <Directory $DEFAULT_SITE_DIR>
        Options -Indexes +FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF
log_done "Wrote catch-all vhost ($DEFAULT_VHOST)"

# --- 6b: Primary domain placeholder vhost (<domain>.conf) -------------------
# Phase 6 will overwrite this file when WordPress takes over.
# IMPORTANT: if phase 6 already ran (file has 'phase6-marker'), we MUST NOT
# overwrite it. Re-running phase 2 on a phase-6-built server would otherwise
# clobber the WordPress vhost.
if [ -f "$DOMAIN_VHOST" ] && grep -q "phase6-marker" "$DOMAIN_VHOST" 2>/dev/null; then
    log_skip "Primary domain vhost is owned by phase 6 (WordPress) - leaving it alone"
else
    cat > "$DOMAIN_VHOST" <<EOF
# phase2-marker - managed by phase2.sh
# Placeholder vhost for the primary domain. Phase 6 overwrites this
# file with the WordPress vhost.
<VirtualHost *:80>
    ServerName $DOMAIN
    ServerAlias ${ALT_DOMAINS[*]}
    DocumentRoot $DEFAULT_SITE_DIR

    <Directory $DEFAULT_SITE_DIR>
        Options -Indexes +FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF
    log_done "Wrote primary domain placeholder vhost ($DOMAIN_VHOST)"
fi

# Enable both
if [ -L /etc/apache2/sites-enabled/000-default.conf ]; then
    log_skip "Catch-all vhost already enabled"
else
    a2ensite -q 000-default >/dev/null 2>&1
    log_done "Enabled catch-all vhost"
fi

if [ -L "/etc/apache2/sites-enabled/${DOMAIN}.conf" ]; then
    log_skip "Primary domain placeholder vhost already enabled"
else
    a2ensite -q "${DOMAIN}" >/dev/null 2>&1
    log_done "Enabled primary domain placeholder vhost"
fi

# Validate config before reloading
if apache2ctl configtest >/dev/null 2>&1; then
    log_done "Apache config validated"
else
    log_fail "Apache config has errors. Check with: apache2ctl configtest"
fi

# Reload Apache to apply changes
systemctl reload apache2 || systemctl restart apache2
if systemctl is-active --quiet apache2; then
    log_done "Apache running"
else
    log_fail "Apache failed to start"
fi

# ============================================================================
# STEP 7a: Acquire Let's Encrypt certificate via webroot
# ============================================================================
# NOTE: We deliberately use --webroot rather than --apache here.
# certbot 4.0.0 (Ubuntu 26.04 default) has a bug in the --apache plugin
# that causes "No such authorization" errors during cert acquisition.
# The --webroot plugin works correctly: it drops the challenge file in the
# document root and lets Apache serve it (which we already confirmed works).
step "Step 7a: Acquiring Let's Encrypt certificate (webroot method)"

CERT_DIR="/etc/letsencrypt/live/$DOMAIN"

if [ -d "$CERT_DIR" ] && [ -f "$CERT_DIR/fullchain.pem" ]; then
    log_skip "Certificate for $DOMAIN already exists"
    EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_DIR/fullchain.pem" | cut -d= -f2)
    echo "         (expires: $EXPIRY)"
else
    # Build the -d arguments
    DOMAIN_ARGS="-d $DOMAIN"
    for alt in "${ALT_DOMAINS[@]}"; do
        DOMAIN_ARGS="$DOMAIN_ARGS -d $alt"
    done

    if certbot certonly \
        --webroot \
        --webroot-path "$DEFAULT_SITE_DIR" \
        --non-interactive \
        --agree-tos \
        --email "$CERTBOT_EMAIL" \
        $DOMAIN_ARGS; then
        log_done "Certificate issued for $DOMAIN${ALT_DOMAINS:+ + ${ALT_DOMAINS[*]}}"
    else
        log_fail "certbot certonly failed - see output above. Check DNS, firewall, and try again."
        exit 1
    fi
fi

# ============================================================================
# STEP 7b: Install certificate into Apache (with HTTP->HTTPS redirect)
# ============================================================================
step "Step 7b: Installing certificate into Apache"

# certbot --apache --install picks up the <domain>.conf vhost (because it
# matches the cert's ServerName) and generates an SSL twin at
# <domain>-le-ssl.conf with the cert wired in. It also adds an HTTP->HTTPS
# redirect to <domain>.conf.
SSL_VHOST_FILE="/etc/apache2/sites-enabled/${DOMAIN}-le-ssl.conf"
if [ -f "$SSL_VHOST_FILE" ] && grep -q "$CERT_DIR" "$SSL_VHOST_FILE" 2>/dev/null; then
    log_skip "Certificate already installed in Apache"
elif [ -f "$CERT_DIR/fullchain.pem" ]; then
    if certbot install \
        --cert-name "$DOMAIN" \
        --apache \
        --redirect \
        --non-interactive 2>&1 | tail -20; then
        log_done "Certificate installed in Apache (HTTP redirects to HTTPS)"
        # Reload Apache to make sure new vhost is active
        systemctl reload apache2
    else
        log_fail "certbot install failed - see output above"
    fi
else
    log_fail "No certificate to install (Step 7a must have failed)"
fi

# ============================================================================
# STEP 7c: Catch-all SSL vhost for unknown hostnames on port 443
# ============================================================================
# Without this, an HTTPS request for an unknown hostname (e.g.,
# https://mail.${DOMAIN}/) falls through to the FIRST :443 vhost
# Apache loaded - which is the one for the real domain. Better to have
# an explicit catch-all that serves the placeholder page. The cert is the
# real domain's cert (browsers will warn on hostname mismatch, which is
# fine - this fallback shouldn't be the destination anyone intends to hit).
step "Step 7c: Configuring catch-all SSL vhost (port 443 fallback)"

CATCHALL_SSL_VHOST="/etc/apache2/sites-available/000-default-le-ssl.conf"
if [ -f "$CERT_DIR/fullchain.pem" ]; then
    cat > "$CATCHALL_SSL_VHOST" <<EOF
# phase2-marker - managed by phase2.sh
# Catch-all SSL vhost: handles HTTPS requests whose Host header doesn't
# match a more specific :443 vhost. Uses the primary domain's cert as a
# fallback (browser will show a hostname mismatch warning - that's fine).
<VirtualHost *:443>
    ServerName _default_
    DocumentRoot $DEFAULT_SITE_DIR

    SSLEngine on
    SSLCertificateFile $CERT_DIR/fullchain.pem
    SSLCertificateKeyFile $CERT_DIR/privkey.pem

    <Directory $DEFAULT_SITE_DIR>
        Options -Indexes +FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF
    log_done "Wrote catch-all SSL vhost ($CATCHALL_SSL_VHOST)"

    if [ -L /etc/apache2/sites-enabled/000-default-le-ssl.conf ]; then
        log_skip "Catch-all SSL vhost already enabled"
    else
        a2ensite -q 000-default-le-ssl >/dev/null 2>&1
        log_done "Enabled catch-all SSL vhost"
    fi

    if apache2ctl configtest >/dev/null 2>&1; then
        systemctl reload apache2
        log_done "Apache reloaded with catch-all SSL vhost active"
    else
        log_fail "Apache config invalid after adding catch-all SSL vhost"
    fi
else
    log_warn "Skipping catch-all SSL vhost (no cert from step 7a)"
fi

# ============================================================================
# STEP 8: Verify certbot auto-renewal timer
# ============================================================================
step "Step 8: Verifying cert auto-renewal"

if systemctl list-timers --all 2>/dev/null | grep -q certbot; then
    if systemctl is-enabled --quiet certbot.timer 2>/dev/null; then
        log_done "certbot.timer is enabled (auto-renewal active)"
    else
        systemctl enable certbot.timer >/dev/null 2>&1
        log_done "certbot.timer enabled"
    fi
else
    log_warn "certbot.timer not found - renewal may need manual cron setup"
fi

# ============================================================================
# REPORT
# ============================================================================
echo ""
echo "==================================================================="
echo "  PHASE 2 COMPLETE - SUMMARY REPORT"
echo "==================================================================="
echo ""
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



verify_pkg() {
    local pkg="$1"
    if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        echo "  [PASS] Package $pkg is installed"
        VERIFY_PASS=$((VERIFY_PASS + 1))
    else
        echo "  [FAIL] Package $pkg is NOT installed"
        VERIFY_FAIL=$((VERIFY_FAIL + 1))
    fi
}

verify_dir() {
    local d="$1"
    # expected_owner can be a single owner ("root") or pipe-separated list of
    # acceptable owners ("root|vmail") for cases where ownership legitimately
    # changes between phases.
    local expected_owner="$2"
    if [ -d "$d" ]; then
        local actual_owner
        actual_owner=$(stat -c '%U' "$d")
        # Build a regex anchor so "root" doesn't match "rooto" etc.
        if echo "$actual_owner" | grep -qxE "$expected_owner"; then
            echo "  [PASS] Directory $d exists (owner: $actual_owner, accepted: $expected_owner)"
            VERIFY_PASS=$((VERIFY_PASS + 1))
        else
            echo "  [FAIL] Directory $d owner is $actual_owner, expected $expected_owner"
            VERIFY_FAIL=$((VERIFY_FAIL + 1))
        fi
    else
        echo "  [FAIL] Directory $d does not exist"
        VERIFY_FAIL=$((VERIFY_FAIL + 1))
    fi
}

verify_module() {
    local mod="$1"
    if apache2ctl -M 2>/dev/null | grep -qE "^\s+${mod}_module"; then
        echo "  [PASS] Apache module '$mod' is enabled"
        VERIFY_PASS=$((VERIFY_PASS + 1))
    else
        echo "  [FAIL] Apache module '$mod' is NOT enabled"
        VERIFY_FAIL=$((VERIFY_FAIL + 1))
    fi
}

# Packages
verify_pkg apache2
verify_pkg certbot
verify_pkg python3-certbot-apache

# Apache running
if systemctl is-active --quiet apache2; then
    echo "  [PASS] apache2 service is active"
    VERIFY_PASS=$((VERIFY_PASS + 1))
else
    echo "  [FAIL] apache2 service is NOT active"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

if systemctl is-enabled --quiet apache2; then
    echo "  [PASS] apache2 service is enabled at boot"
    VERIFY_PASS=$((VERIFY_PASS + 1))
else
    echo "  [FAIL] apache2 service is NOT enabled at boot"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# Apache modules
for mod in "${APACHE_REQUIRED_MODULES[@]}"; do
    verify_module "$mod"
done

# Apache config valid
if apache2ctl configtest >/dev/null 2>&1; then
    echo "  [PASS] Apache config is valid"
    VERIFY_PASS=$((VERIFY_PASS + 1))
else
    echo "  [FAIL] Apache config has errors"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# Directories
verify_dir "$WEB_ROOT" "root"
verify_dir "$DEFAULT_SITE_DIR" "www-data"
verify_dir "$PLONE_HOME" "$PLONE_USER"
verify_dir "$VMAIL_HOME" "root|vmail"

# Plone user
if id "$PLONE_USER" &>/dev/null; then
    echo "  [PASS] User '$PLONE_USER' exists"
    VERIFY_PASS=$((VERIFY_PASS + 1))
    PLONE_SHELL=$(getent passwd "$PLONE_USER" | cut -d: -f7)
    if [ "$PLONE_SHELL" = "/usr/sbin/nologin" ] || [ "$PLONE_SHELL" = "/sbin/nologin" ] || [ "$PLONE_SHELL" = "/bin/false" ]; then
        echo "  [PASS] User '$PLONE_USER' has no login shell ($PLONE_SHELL)"
        VERIFY_PASS=$((VERIFY_PASS + 1))
    else
        echo "  [FAIL] User '$PLONE_USER' has login shell: $PLONE_SHELL"
        VERIFY_FAIL=$((VERIFY_FAIL + 1))
    fi
else
    echo "  [FAIL] User '$PLONE_USER' does not exist"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# Listening on 80 and 443
LISTENING=$(ss -tlnp 2>/dev/null)
verify_contains "Apache listening on port 80" "$LISTENING" ":80 "
verify_contains "Apache listening on port 443" "$LISTENING" ":443 "

# Cert exists
if [ -f "$CERT_DIR/fullchain.pem" ] && [ -f "$CERT_DIR/privkey.pem" ]; then
    echo "  [PASS] Let's Encrypt certificate files exist"
    VERIFY_PASS=$((VERIFY_PASS + 1))

    # Cert covers primary domain
    if openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -text 2>/dev/null | \
       grep -qE "DNS:$DOMAIN(,|$)"; then
        echo "  [PASS] Certificate covers $DOMAIN"
        VERIFY_PASS=$((VERIFY_PASS + 1))
    else
        echo "  [FAIL] Certificate does NOT cover $DOMAIN"
        VERIFY_FAIL=$((VERIFY_FAIL + 1))
    fi

    # Cert covers each alt domain
    for alt in "${ALT_DOMAINS[@]}"; do
        if openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -text 2>/dev/null | \
           grep -qE "DNS:$alt(,|$)"; then
            echo "  [PASS] Certificate covers $alt"
            VERIFY_PASS=$((VERIFY_PASS + 1))
        else
            echo "  [FAIL] Certificate does NOT cover $alt"
            VERIFY_FAIL=$((VERIFY_FAIL + 1))
        fi
    done

    # Cert validity
    if openssl x509 -checkend 86400 -noout -in "$CERT_DIR/fullchain.pem" >/dev/null 2>&1; then
        echo "  [PASS] Certificate is valid (not expiring within 24 hours)"
        VERIFY_PASS=$((VERIFY_PASS + 1))
    else
        echo "  [FAIL] Certificate is expired or expiring within 24 hours"
        VERIFY_FAIL=$((VERIFY_FAIL + 1))
    fi
else
    echo "  [FAIL] Let's Encrypt certificate files missing"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# certbot timer enabled
if systemctl is-enabled --quiet certbot.timer 2>/dev/null; then
    echo "  [PASS] certbot.timer is enabled"
    VERIFY_PASS=$((VERIFY_PASS + 1))
else
    echo "  [FAIL] certbot.timer is NOT enabled"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# HTTPS responds locally with valid cert
HTTPS_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "https://$DOMAIN/" 2>/dev/null || echo "000")
if [ "$HTTPS_CODE" = "200" ]; then
    echo "  [PASS] HTTPS request to https://$DOMAIN/ returned 200"
    VERIFY_PASS=$((VERIFY_PASS + 1))
else
    echo "  [FAIL] HTTPS request to https://$DOMAIN/ returned $HTTPS_CODE"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# HTTP redirects to HTTPS
HTTP_REDIRECT=$(curl -s -o /dev/null -w "%{http_code} %{redirect_url}" --max-time 10 "http://$DOMAIN/" 2>/dev/null || echo "000")
if echo "$HTTP_REDIRECT" | grep -qE "^30[12]"; then
    echo "  [PASS] HTTP redirects to HTTPS (got: $HTTP_REDIRECT)"
    VERIFY_PASS=$((VERIFY_PASS + 1))
else
    echo "  [FAIL] HTTP does not redirect to HTTPS (got: $HTTP_REDIRECT)"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

echo ""
echo "  Verification: $VERIFY_PASS passed, $VERIFY_FAIL failed"
echo ""

if [ "$VERIFY_FAIL" -gt 0 ]; then
    echo "  *** $VERIFY_FAIL CHECK(S) FAILED. Review failures above before proceeding. ***"
    echo ""
fi

# Exit non-zero if any automated check failed
if [ "$VERIFY_FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
