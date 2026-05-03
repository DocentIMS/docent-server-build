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
PRIMARY_DOMAIN="docenttemplate.com"
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

# === BEGIN tenant.local/secrets.local source block (added by phase0 design) ===
# Source per-tenant config and secrets if they exist. These files are created
# by phase0-bootstrap.sh. If they are not present, the hardcoded defaults
# above remain in effect (preserving original standalone behavior).
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
unset __PHASE_SCRIPT_DIR __PHASE_REPO_ROOT
# === END tenant.local/secrets.local source block ===

# ============================================================================
# REPORT TRACKING
# ============================================================================
REPORT=()

log_done() { REPORT+=("[DONE]    $1"); echo "  ✓ $1"; }
log_skip() { REPORT+=("[SKIPPED] $1 (already done)"); echo "  - $1 (already done)"; }
log_warn() { REPORT+=("[WARN]    $1"); echo "  ! $1"; }
log_fail() { REPORT+=("[FAIL]    $1"); echo "  ✗ $1"; }

step() { echo ""; echo "=== $1 ==="; }

# ============================================================================
# SAFETY CHECK
# ============================================================================
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root (use sudo)."
    exit 1
fi

echo "==================================================================="
echo "  Phase 2 - Web server + TLS foundation for $PRIMARY_DOMAIN"
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
    apt-get update -qq
    apt-get install -y -qq -o Dpkg::Use-Pty=0 apache2 < /dev/null
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
    apt-get install -y -qq -o Dpkg::Use-Pty=0 certbot python3-certbot-apache < /dev/null
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
<title>$PRIMARY_DOMAIN</title>
<style>
  body { font-family: system-ui, sans-serif; max-width: 600px; margin: 4em auto; padding: 1em; color: #333; }
  h1 { color: #2a4d7a; }
  code { background: #f0f0f0; padding: 0.1em 0.4em; border-radius: 3px; }
</style>
</head>
<body>
<h1>$PRIMARY_DOMAIN</h1>
<p>This server is online and serving HTTPS.</p>
<p>Status: template server, ready for site provisioning.</p>
</body>
</html>
EOF
    chown www-data:www-data "$INDEX_FILE"
    log_done "Wrote placeholder index page"
fi

# ============================================================================
# STEP 6: Configure default Apache vhost
# ============================================================================
step "Step 6: Configuring default Apache vhost"

DEFAULT_VHOST="/etc/apache2/sites-available/000-default.conf"
DEFAULT_VHOST_BACKUP="/etc/apache2/sites-available/000-default.conf.phase2.bak"

# Backup the original once
if [ ! -f "$DEFAULT_VHOST_BACKUP" ] && [ -f "$DEFAULT_VHOST" ]; then
    cp "$DEFAULT_VHOST" "$DEFAULT_VHOST_BACKUP"
    log_done "Backed up original $DEFAULT_VHOST"
fi

# Write our vhost (idempotent: identical content overwrite is harmless)
cat > "$DEFAULT_VHOST" <<EOF
# phase2-marker - managed by phase2.sh
<VirtualHost *:80>
    ServerName $PRIMARY_DOMAIN
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
log_done "Wrote default vhost ($DEFAULT_VHOST)"

# Make sure it's enabled
if [ -L /etc/apache2/sites-enabled/000-default.conf ]; then
    log_skip "Default vhost already enabled"
else
    a2ensite -q 000-default >/dev/null 2>&1
    log_done "Enabled default vhost"
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

CERT_DIR="/etc/letsencrypt/live/$PRIMARY_DOMAIN"

if [ -d "$CERT_DIR" ] && [ -f "$CERT_DIR/fullchain.pem" ]; then
    log_skip "Certificate for $PRIMARY_DOMAIN already exists"
    EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_DIR/fullchain.pem" | cut -d= -f2)
    echo "         (expires: $EXPIRY)"
else
    # Build the -d arguments
    DOMAIN_ARGS="-d $PRIMARY_DOMAIN"
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
        log_done "Certificate issued for $PRIMARY_DOMAIN${ALT_DOMAINS:+ + ${ALT_DOMAINS[*]}}"
    else
        log_fail "certbot certonly failed - see output above. Check DNS, firewall, and try again."
    fi
fi

# ============================================================================
# STEP 7b: Install certificate into Apache (with HTTP->HTTPS redirect)
# ============================================================================
step "Step 7b: Installing certificate into Apache"

# Detect whether the cert is already wired into Apache by looking for an
# enabled SSL vhost referencing our cert path.
SSL_VHOST_FILE="/etc/apache2/sites-enabled/000-default-le-ssl.conf"
if [ -f "$SSL_VHOST_FILE" ] && grep -q "$CERT_DIR" "$SSL_VHOST_FILE" 2>/dev/null; then
    log_skip "Certificate already installed in Apache"
elif [ -f "$CERT_DIR/fullchain.pem" ]; then
    if certbot install \
        --cert-name "$PRIMARY_DOMAIN" \
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

verify() {
    local description="$1"
    local expected="$2"
    local actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  [PASS] $description"
        VERIFY_PASS=$((VERIFY_PASS + 1))
    else
        echo "  [FAIL] $description"
        echo "         expected: $expected"
        echo "         actual:   $actual"
        VERIFY_FAIL=$((VERIFY_FAIL + 1))
    fi
}

verify_contains() {
    local description="$1"
    local haystack="$2"
    local needle="$3"
    if echo "$haystack" | grep -q "$needle"; then
        echo "  [PASS] $description"
        VERIFY_PASS=$((VERIFY_PASS + 1))
    else
        echo "  [FAIL] $description"
        VERIFY_FAIL=$((VERIFY_FAIL + 1))
    fi
}

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
    local expected_owner="$2"
    if [ -d "$d" ]; then
        local actual_owner
        actual_owner=$(stat -c '%U' "$d")
        if [ "$actual_owner" = "$expected_owner" ]; then
            echo "  [PASS] Directory $d exists (owner: $expected_owner)"
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
verify_dir "$VMAIL_HOME" "root"

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
       grep -qE "DNS:$PRIMARY_DOMAIN(,|$)"; then
        echo "  [PASS] Certificate covers $PRIMARY_DOMAIN"
        VERIFY_PASS=$((VERIFY_PASS + 1))
    else
        echo "  [FAIL] Certificate does NOT cover $PRIMARY_DOMAIN"
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
HTTPS_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "https://$PRIMARY_DOMAIN/" 2>/dev/null || echo "000")
if [ "$HTTPS_CODE" = "200" ]; then
    echo "  [PASS] HTTPS request to https://$PRIMARY_DOMAIN/ returned 200"
    VERIFY_PASS=$((VERIFY_PASS + 1))
else
    echo "  [FAIL] HTTPS request to https://$PRIMARY_DOMAIN/ returned $HTTPS_CODE"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# HTTP redirects to HTTPS
HTTP_REDIRECT=$(curl -s -o /dev/null -w "%{http_code} %{redirect_url}" --max-time 10 "http://$PRIMARY_DOMAIN/" 2>/dev/null || echo "000")
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

# ============================================================================
# MANUAL VERIFICATION
# ============================================================================
echo "==================================================================="
echo "  MANUAL VERIFICATION STEPS (cannot be automated)"
echo "==================================================================="
cat <<EOF

  These steps require an external connection / human eyes and CANNOT
  be checked by this script. Do them from your Windows machine.

  1. Open https://$PRIMARY_DOMAIN/ in a web browser.
     - You should see the placeholder page with the domain name.
     - The lock icon next to the URL should be CLOSED (green/secure).
     - No certificate warnings.

  2. Open http://$PRIMARY_DOMAIN/ (no https) in the browser.
     - The browser should automatically redirect you to https://.

  3. Open https://www.$PRIMARY_DOMAIN/ in the browser.
     - Should also work, with no cert warnings.

  4. (Optional) Run an SSL check at:
       https://www.ssllabs.com/ssltest/analyze.html?d=$PRIMARY_DOMAIN
     A grade of A or A+ is expected for a default Let's Encrypt setup.

  Once these checks pass, Phase 2 is fully complete and you are ready
  for Phase 3 (Database - MySQL/MariaDB).

EOF
echo "==================================================================="

# Exit non-zero if any automated check failed
if [ "$VERIFY_FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
