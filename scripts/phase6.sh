#!/bin/bash
#
# phase6.sh - Phase 6: WordPress core install on $WP_DOMAIN
#
# This script installs vanilla WordPress core, creates its database, and
# configures Apache to serve it at https://$WP_DOMAIN/. After this script
# runs, you finish setup interactively at https://$WP_DOMAIN/wp-admin/install.php
# (set the site title, admin user, password, etc.) and then theme/configure
# the site by hand.
#
# Idempotent. Safe to re-run. Each step checks current state before acting.
#
# Run as root: sudo bash phase6.sh
#

set -u

# ============================================================================
# CONFIGURATION
# ============================================================================
# Non-domain-dependent constants and defaults.
WP_DOMAIN="docenttemplate.com"      # default - overridden by tenant.local
WP_DOMAIN_ALT="www.docenttemplate.com"  # default - overridden by tenant.local
WP_DB_NAME="wordpress_docenttemplate"   # default - overridden by tenant.local
WP_DB_USER="wp_dt_user"             # default - overridden by tenant.local
WP_ADMIN_USERNAME="wadmin"          # used as a hint only; you set the real one in wp-admin
WP_ADMIN_EMAIL="wglover@docentims.com"  # default - overridden by tenant.local
ROOT_DEFAULTS_FILE="/root/.my.cnf"

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

# Domain-dependent paths. Computed AFTER sourcing so they pick up the
# correct WP_DOMAIN value.
WP_DIR="/srv/www/$WP_DOMAIN"
WP_VHOST_FILE="/etc/apache2/sites-available/${WP_DOMAIN}.conf"
WP_CONFIG="$WP_DIR/wp-config.php"

# ============================================================================
# REPORT TRACKING
# ============================================================================
REPORT=()
# DO NOT initialize WP_DB_PW here - it was already set by sourcing
# secrets.local above. Setting it to "" would wipe out the canonical
# value from CREDENTIALS.txt and force the script to generate a new one,
# breaking the canonical-credentials design.

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

if [ ! -f "$ROOT_DEFAULTS_FILE" ]; then
    echo "ERROR: $ROOT_DEFAULTS_FILE not found. Phase 3 (database) must run first."
    exit 1
fi

echo "==================================================================="
echo "  Phase 6 - WordPress core install for $WP_DOMAIN"
echo "  $(date)"
echo "==================================================================="

# ============================================================================
# STEP 1: Install PHP + WordPress prerequisites
# ============================================================================
step "Step 1: Installing PHP and WordPress prerequisites"

export DEBIAN_FRONTEND=noninteractive

PHP_PACKAGES=(
    php
    libapache2-mod-php
    php-mysql
    php-curl
    php-gd
    php-mbstring
    php-xml
    php-zip
    php-imagick
    php-intl
    php-bcmath
)

# Also useful: ImageMagick (for php-imagick to actually do anything)
TOOL_PACKAGES=(
    imagemagick
    ghostscript
    unzip
    wget
)

MISSING=""
for pkg in "${PHP_PACKAGES[@]}" "${TOOL_PACKAGES[@]}"; do
    if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        MISSING="$MISSING $pkg"
    fi
done

if [ -z "$MISSING" ]; then
    log_skip "All PHP/WordPress prerequisites installed"
else
    apt-get update -qq
    apt-get install -y -qq -o Dpkg::Use-Pty=0 $MISSING < /dev/null
    log_done "Installed:$MISSING"
fi

# ============================================================================
# STEP 2: Create WordPress database and DB user
# ============================================================================
step "Step 2: Creating WordPress database and DB user"

# Does database already exist?
DB_EXISTS=$(mysql --defaults-file="$ROOT_DEFAULTS_FILE" -Nse \
    "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$WP_DB_NAME';" 2>/dev/null || echo "0")

if [ "$DB_EXISTS" -gt 0 ]; then
    log_skip "Database $WP_DB_NAME already exists"
else
    mysql --defaults-file="$ROOT_DEFAULTS_FILE" -e \
        "CREATE DATABASE \`$WP_DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    log_done "Created database $WP_DB_NAME"
fi

# Does DB user already exist?
USER_EXISTS=$(mysql --defaults-file="$ROOT_DEFAULTS_FILE" -Nse \
    "SELECT COUNT(*) FROM mysql.user WHERE User='$WP_DB_USER' AND Host='localhost';" 2>/dev/null || echo "0")

if [ "$USER_EXISTS" -gt 0 ]; then
    log_skip "DB user $WP_DB_USER already exists"
else
    # Use WP_DB_PW from secrets.local if available, otherwise generate.
    # When phase0 was used, WP_DB_PW is the password documented in
    # CREDENTIALS.txt - we MUST use it so CREDENTIALS.txt stays canonical.
    if [ -z "${WP_DB_PW:-}" ]; then
        WP_DB_PW=$(openssl rand -base64 24 | tr -d '/+=' | head -c 28)
        log_warn "No WP_DB_PW in secrets.local - generated a random one (NOT in CREDENTIALS.txt)"
    fi
    mysql --defaults-file="$ROOT_DEFAULTS_FILE" <<SQL
CREATE USER '$WP_DB_USER'@'localhost' IDENTIFIED BY '$WP_DB_PW';
GRANT ALL PRIVILEGES ON \`$WP_DB_NAME\`.* TO '$WP_DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL
    log_done "Created DB user $WP_DB_USER (full access on $WP_DB_NAME)"
fi

# ============================================================================
# STEP 3: Download and install WordPress core
# ============================================================================
step "Step 3: Installing WordPress core"

if [ -f "$WP_DIR/wp-includes/version.php" ]; then
    WP_VERSION=$(grep "^\$wp_version" "$WP_DIR/wp-includes/version.php" | awk -F"'" '{print $2}')
    log_skip "WordPress already installed ($WP_VERSION)"
else
    if [ ! -d "$WP_DIR" ]; then
        mkdir -p "$WP_DIR"
        log_done "Created $WP_DIR"
    fi

    # Download latest WP into a temp dir, then move
    TMPDIR=$(mktemp -d)
    if wget -q -O "$TMPDIR/latest.tar.gz" https://wordpress.org/latest.tar.gz; then
        tar -xzf "$TMPDIR/latest.tar.gz" -C "$TMPDIR"
        # Move contents of wordpress/ into $WP_DIR (handles both empty and partial dirs)
        cp -a "$TMPDIR/wordpress/." "$WP_DIR/"
        rm -rf "$TMPDIR"
        log_done "Downloaded and extracted WordPress core"
    else
        rm -rf "$TMPDIR"
        log_fail "Failed to download WordPress"
        exit 1
    fi
fi

# ============================================================================
# STEP 4: Set ownership and permissions
# ============================================================================
step "Step 4: Setting file ownership and permissions"

# WordPress files owned by www-data so PHP/Apache can write uploads, plugins, etc.
# Standard secure-ish defaults: 755 dirs, 644 files, wp-config.php 640.
chown -R www-data:www-data "$WP_DIR"
find "$WP_DIR" -type d -exec chmod 755 {} \;
find "$WP_DIR" -type f -exec chmod 644 {} \;
log_done "Set ownership to www-data:www-data, dirs 755, files 644"

# ============================================================================
# STEP 5: Generate wp-config.php from sample
# ============================================================================
step "Step 5: Generating wp-config.php"

if [ -f "$WP_CONFIG" ] && grep -q "phase6-marker" "$WP_CONFIG"; then
    log_skip "wp-config.php already configured"
else
    SAMPLE="$WP_DIR/wp-config-sample.php"
    if [ ! -f "$SAMPLE" ]; then
        log_fail "wp-config-sample.php not found - WordPress core install incomplete"
        exit 1
    fi

    # If we just generated a password this run, use it; otherwise we need to
    # extract it from the existing wp-config.php (which means there isn't one,
    # which means the user already exists, which means we have a problem).
    if [ -z "$WP_DB_PW" ]; then
        # User existed but wp-config.php doesn't. Use secrets.local's
        # WP_DB_PW if available (CREDENTIALS.txt must stay canonical).
        # Otherwise generate.
        if [ -z "${WP_DB_PW:-}" ]; then
            WP_DB_PW=$(openssl rand -base64 24 | tr -d '/+=' | head -c 28)
            log_warn "No WP_DB_PW in secrets.local - generated a random one (NOT in CREDENTIALS.txt)"
        fi
        mysql --defaults-file="$ROOT_DEFAULTS_FILE" -e \
            "ALTER USER '$WP_DB_USER'@'localhost' IDENTIFIED BY '$WP_DB_PW'; FLUSH PRIVILEGES;"
        log_warn "DB user existed but wp-config.php was missing - reset DB password"
    fi

    cp "$SAMPLE" "$WP_CONFIG"

    # Substitute database settings
    sed -i "s/database_name_here/$WP_DB_NAME/" "$WP_CONFIG"
    sed -i "s/username_here/$WP_DB_USER/" "$WP_CONFIG"
    # password may contain regex specials; use a literal sed delimiter that won't appear
    ESCAPED_PW=$(printf '%s\n' "$WP_DB_PW" | sed 's/[\/&|]/\\&/g')
    sed -i "s|password_here|$ESCAPED_PW|" "$WP_CONFIG"

    # Insert fresh authentication keys/salts from the WP API.
    # We use Python rather than sed/perl because the salt strings contain
    # arbitrary punctuation that breaks shell-quoted regex replacements.
    if SALTS_OUTPUT=$(python3 - "$WP_CONFIG" <<'PYEOF'
import sys, re, urllib.request
config_path = sys.argv[1]
try:
    salts = urllib.request.urlopen(
        'https://api.wordpress.org/secret-key/1.1/salt/',
        timeout=10
    ).read().decode()
except Exception as e:
    print(f"ERROR: could not fetch salts: {e}", file=sys.stderr)
    sys.exit(2)
if not salts.strip():
    print("ERROR: empty response from api.wordpress.org", file=sys.stderr)
    sys.exit(2)
with open(config_path) as f:
    content = f.read()
new_content = re.sub(
    r"define\(\s*'AUTH_KEY'.*?define\(\s*'NONCE_SALT'\s*,\s*'put your unique phrase here'\s*\)\s*;",
    salts.strip(),
    content,
    flags=re.DOTALL
)
if new_content == content:
    print("ERROR: placeholder salt block not found", file=sys.stderr)
    sys.exit(3)
with open(config_path, 'w') as f:
    f.write(new_content)
print("OK")
PYEOF
    ); then
        log_done "Injected fresh authentication keys/salts from api.wordpress.org"
    else
        log_warn "Could not inject keys/salts (network or parse error). Replace manually before logging in to WP."
    fi

    # Add phase6 marker so re-runs detect this config
    sed -i "1a // phase6-marker - managed by phase6.sh" "$WP_CONFIG"

    log_done "Wrote $WP_CONFIG"
fi

# Always (re-)apply tight permissions on wp-config.php, regardless of whether
# we wrote it this run. Step 4 sets all files to 644, which would otherwise
# leave wp-config.php world-readable on subsequent runs.
if [ -f "$WP_CONFIG" ]; then
    chown www-data:www-data "$WP_CONFIG"
    chmod 640 "$WP_CONFIG"
    log_done "Applied secure permissions on wp-config.php (640, www-data:www-data)"
fi

# ============================================================================
# STEP 6: Configure Apache vhost for WordPress
# ============================================================================
step "Step 6: Configuring Apache vhost"

# Phase 2 wrote two vhost files for us:
#   - 000-default.conf            (catch-all, ServerName _default_)
#   - 000-default-le-ssl.conf     (catch-all, ServerName _default_, on :443)
#   - $WP_DOMAIN.conf             (placeholder for the primary domain on :80)
#   - $WP_DOMAIN-le-ssl.conf      (placeholder SSL vhost on :443, generated
#                                  by certbot install in phase 2 step 7b)
#
# We do NOT disable the 000-default* catch-alls - they handle requests
# for unknown hostnames (like mail.$WP_DOMAIN). We just overwrite the
# primary-domain vhost files with the WordPress configuration.

# Write our WP-specific vhost (covers both :80 and :443; redirect HTTP -> HTTPS)
CERT_DIR="/etc/letsencrypt/live/$WP_DOMAIN"
cat > "$WP_VHOST_FILE" <<EOF
# phase6-marker - managed by phase6.sh
<VirtualHost *:80>
    ServerName $WP_DOMAIN
    ServerAlias $WP_DOMAIN_ALT
    RewriteEngine On
    RewriteCond %{HTTPS} !=on
    RewriteRule ^/?(.*) https://$WP_DOMAIN/\$1 [R=301,L]
</VirtualHost>

<VirtualHost *:443>
    ServerName $WP_DOMAIN
    ServerAlias $WP_DOMAIN_ALT
    DocumentRoot $WP_DIR

    SSLEngine on
    SSLCertificateFile $CERT_DIR/fullchain.pem
    SSLCertificateKeyFile $CERT_DIR/privkey.pem

    <Directory $WP_DIR>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    # Block access to sensitive files
    <FilesMatch "^(wp-config\.php|\.htaccess|xmlrpc\.php)$">
        Require all denied
    </FilesMatch>
    <Files "wp-config.php">
        Require all denied
    </Files>

    ErrorLog \${APACHE_LOG_DIR}/$WP_DOMAIN-error.log
    CustomLog \${APACHE_LOG_DIR}/$WP_DOMAIN-access.log combined
</VirtualHost>
EOF
log_done "Wrote $WP_VHOST_FILE (WordPress vhost for $WP_DOMAIN, both :80 and :443)"

# Phase 2's certbot install may have generated $WP_DOMAIN-le-ssl.conf as a
# separate file. We now have everything in $WP_VHOST_FILE, so disable any
# stale -le-ssl twin so we don't have duplicate :443 vhosts for the domain.
LE_SSL_TWIN="$WP_DOMAIN-le-ssl"
if [ -L "/etc/apache2/sites-enabled/${LE_SSL_TWIN}.conf" ]; then
    a2dissite -q "$LE_SSL_TWIN" >/dev/null 2>&1
    log_done "Disabled certbot's stale -le-ssl twin (replaced by $WP_VHOST_FILE)"
fi

# Enable the new vhost
if [ -L "/etc/apache2/sites-enabled/$(basename "$WP_VHOST_FILE")" ]; then
    log_skip "WordPress vhost already enabled"
else
    a2ensite -q "$(basename "$WP_VHOST_FILE" .conf)" >/dev/null 2>&1
    log_done "Enabled WordPress vhost"
fi

# Validate config
if apache2ctl configtest >/dev/null 2>&1; then
    log_done "Apache config validated"
else
    log_fail "Apache config has errors. Check with: apache2ctl configtest"
fi

# Reload Apache
systemctl reload apache2
if systemctl is-active --quiet apache2; then
    log_done "Apache reloaded"
else
    log_fail "Apache failed to reload"
fi

# ============================================================================
# REPORT
# ============================================================================
echo ""
echo "==================================================================="
echo "  PHASE 6 COMPLETE - SUMMARY REPORT"
echo "==================================================================="
echo ""
for line in "${REPORT[@]}"; do
    echo "  $line"
done

# ============================================================================
# CREDENTIALS
# ============================================================================
echo ""
echo "==================================================================="
echo "  PASSWORDS"
echo "==================================================================="
echo ""
echo "  All passwords are in CREDENTIALS.txt at the repo root."
echo "  This script does NOT print passwords (to avoid scrollback exposure)."
echo ""
echo "  The WordPress DB password is also stored in:"
echo "    $WP_CONFIG (mode 640, www-data:www-data)"
echo ""
echo "  Suggested WP admin username: $WP_ADMIN_USERNAME"
echo "  Suggested WP admin email:    $WP_ADMIN_EMAIL"
echo ""
echo "  (You'll set the actual admin username/password/email next at"
echo "   https://$WP_DOMAIN/wp-admin/install.php — see manual steps below)"

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

# PHP packages
for pkg in php libapache2-mod-php php-mysql php-curl php-gd php-mbstring php-xml php-zip; do
    if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        echo "  [PASS] Package $pkg installed"
        VERIFY_PASS=$((VERIFY_PASS + 1))
    else
        echo "  [FAIL] Package $pkg NOT installed"
        VERIFY_FAIL=$((VERIFY_FAIL + 1))
    fi
done

# php module loaded in apache
if apache2ctl -M 2>/dev/null | grep -qE "^\s+php"; then
    echo "  [PASS] PHP module loaded into Apache"
    VERIFY_PASS=$((VERIFY_PASS + 1))
else
    echo "  [FAIL] PHP module NOT loaded into Apache"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# WordPress core present
if [ -f "$WP_DIR/wp-includes/version.php" ]; then
    WP_VERSION=$(grep "^\$wp_version" "$WP_DIR/wp-includes/version.php" | awk -F"'" '{print $2}')
    echo "  [PASS] WordPress core present (version: $WP_VERSION)"
    VERIFY_PASS=$((VERIFY_PASS + 1))
else
    echo "  [FAIL] WordPress core not found at $WP_DIR"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# wp-config.php exists with correct perms
if [ -f "$WP_CONFIG" ]; then
    PERMS=$(stat -c '%a' "$WP_CONFIG")
    OWNER=$(stat -c '%U:%G' "$WP_CONFIG")
    if [ "$PERMS" = "640" ] && [ "$OWNER" = "www-data:www-data" ]; then
        echo "  [PASS] wp-config.php exists (mode 640, owner www-data:www-data)"
        VERIFY_PASS=$((VERIFY_PASS + 1))
    else
        echo "  [FAIL] wp-config.php has mode $PERMS owner $OWNER (expected 640 www-data:www-data)"
        VERIFY_FAIL=$((VERIFY_FAIL + 1))
    fi
else
    echo "  [FAIL] wp-config.php missing"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# wp-config has been customized (no placeholder strings)
if [ -f "$WP_CONFIG" ]; then
    if grep -q "database_name_here\|username_here\|password_here" "$WP_CONFIG"; then
        echo "  [FAIL] wp-config.php still contains placeholder values"
        VERIFY_FAIL=$((VERIFY_FAIL + 1))
    else
        echo "  [PASS] wp-config.php has no placeholder values"
        VERIFY_PASS=$((VERIFY_PASS + 1))
    fi

    if grep -q "put your unique phrase here" "$WP_CONFIG"; then
        echo "  [FAIL] wp-config.php still has default 'put your unique phrase here' salts"
        VERIFY_FAIL=$((VERIFY_FAIL + 1))
    else
        echo "  [PASS] wp-config.php has fresh authentication salts"
        VERIFY_PASS=$((VERIFY_PASS + 1))
    fi
fi

# Database exists
DB_OK=$(mysql --defaults-file="$ROOT_DEFAULTS_FILE" -Nse \
    "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$WP_DB_NAME';" 2>/dev/null || echo "0")
if [ "$DB_OK" = "1" ]; then
    echo "  [PASS] Database $WP_DB_NAME exists"
    VERIFY_PASS=$((VERIFY_PASS + 1))
else
    echo "  [FAIL] Database $WP_DB_NAME does not exist"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# DB user exists with privileges on the WP database
USER_OK=$(mysql --defaults-file="$ROOT_DEFAULTS_FILE" -Nse \
    "SELECT COUNT(*) FROM mysql.user WHERE User='$WP_DB_USER' AND Host='localhost';" 2>/dev/null || echo "0")
if [ "$USER_OK" = "1" ]; then
    echo "  [PASS] DB user $WP_DB_USER exists"
    VERIFY_PASS=$((VERIFY_PASS + 1))
else
    echo "  [FAIL] DB user $WP_DB_USER does not exist"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# DB user can connect (extracts password from wp-config and tries it)
if [ -f "$WP_CONFIG" ]; then
    EXTRACTED_PW=$(grep "^define( 'DB_PASSWORD'" "$WP_CONFIG" | sed -E "s/.*'DB_PASSWORD'\s*,\s*'([^']+)'.*/\1/")
    if [ -n "$EXTRACTED_PW" ] && \
       mysql -u"$WP_DB_USER" -p"$EXTRACTED_PW" -e "USE $WP_DB_NAME;" >/dev/null 2>&1; then
        echo "  [PASS] DB user $WP_DB_USER can connect to $WP_DB_NAME"
        VERIFY_PASS=$((VERIFY_PASS + 1))
    else
        echo "  [FAIL] DB user $WP_DB_USER cannot connect to $WP_DB_NAME"
        VERIFY_FAIL=$((VERIFY_FAIL + 1))
    fi
fi

# WP vhost file exists and is enabled
if [ -f "$WP_VHOST_FILE" ]; then
    echo "  [PASS] WordPress vhost file exists"
    VERIFY_PASS=$((VERIFY_PASS + 1))
else
    echo "  [FAIL] WordPress vhost file missing"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

if [ -L "/etc/apache2/sites-enabled/$(basename "$WP_VHOST_FILE")" ]; then
    echo "  [PASS] WordPress vhost is enabled"
    VERIFY_PASS=$((VERIFY_PASS + 1))
else
    echo "  [FAIL] WordPress vhost is NOT enabled"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# Catch-all vhost should remain enabled (it handles unknown hostnames like mail.*)
if [ -L /etc/apache2/sites-enabled/000-default.conf ]; then
    echo "  [PASS] Catch-all vhost (000-default) is enabled"
    VERIFY_PASS=$((VERIFY_PASS + 1))
else
    echo "  [FAIL] Catch-all vhost (000-default) is NOT enabled - mail.* etc will fall through to WordPress"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# Apache config valid
if apache2ctl configtest >/dev/null 2>&1; then
    echo "  [PASS] Apache config is valid"
    VERIFY_PASS=$((VERIFY_PASS + 1))
else
    echo "  [FAIL] Apache config has errors"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# HTTPS responds
HTTPS_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "https://$WP_DOMAIN/" 2>/dev/null || echo "000")
# WP install screen returns 200 (or 302 to install.php). Both are fine.
if [ "$HTTPS_CODE" = "200" ] || [ "$HTTPS_CODE" = "302" ]; then
    echo "  [PASS] https://$WP_DOMAIN/ returned HTTP $HTTPS_CODE"
    VERIFY_PASS=$((VERIFY_PASS + 1))
else
    echo "  [FAIL] https://$WP_DOMAIN/ returned HTTP $HTTPS_CODE"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# wp-login.php reachable (proves PHP is executing)
LOGIN_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "https://$WP_DOMAIN/wp-login.php" 2>/dev/null || echo "000")
if [ "$LOGIN_CODE" = "200" ] || [ "$LOGIN_CODE" = "302" ]; then
    echo "  [PASS] PHP executes correctly (wp-login.php returned $LOGIN_CODE)"
    VERIFY_PASS=$((VERIFY_PASS + 1))
else
    echo "  [FAIL] wp-login.php returned $LOGIN_CODE - PHP may not be executing"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# wp-config.php is NOT readable from the web (security check)
WP_CONFIG_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "https://$WP_DOMAIN/wp-config.php" 2>/dev/null || echo "000")
if [ "$WP_CONFIG_CODE" = "403" ]; then
    echo "  [PASS] wp-config.php is blocked from web access (403)"
    VERIFY_PASS=$((VERIFY_PASS + 1))
elif [ "$WP_CONFIG_CODE" = "200" ]; then
    # 200 with empty body is also acceptable (PHP executes the file but it has no output)
    BODY=$(curl -s --max-time 10 "https://$WP_DOMAIN/wp-config.php" 2>/dev/null | head -c 50)
    if [ -z "$BODY" ]; then
        echo "  [PASS] wp-config.php returns empty (PHP executes, no leak)"
        VERIFY_PASS=$((VERIFY_PASS + 1))
    else
        echo "  [FAIL] wp-config.php returned content (potential leak): $BODY"
        VERIFY_FAIL=$((VERIFY_FAIL + 1))
    fi
else
    echo "  [WARN] wp-config.php returned $WP_CONFIG_CODE"
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
echo "  MANUAL VERIFICATION & NEXT STEPS"
echo "==================================================================="
cat <<EOF

  1. Confirm CREDENTIALS.txt is saved in your password manager.
     The WordPress DB password is in BACKEND PASSWORDS.

  2. In a browser, complete the WordPress install wizard:
       https://$WP_DOMAIN/wp-admin/install.php

     - Site Title: anything you want (you can change later)
     - Username:   $WP_ADMIN_USERNAME  (NOT 'admin' - heavily attacked)
     - Password:   let WP generate a strong one, save to password manager
     - Email:      $WP_ADMIN_EMAIL
     - Discourage search engines: leave unchecked (you want Kamatera to find it)

  3. Log in at: https://$WP_DOMAIN/wp-admin/

  4. Theme/configure the site to look like a real Docent project page,
     using whatever template/approach you've used before. The goal is
     a real-looking site so Kamatera will approve PTR.

  5. Once the site is "real-looking enough":
     - Submit (or re-submit) the PTR request to Kamatera, asking for:
         PTR $SERVER_IP -> mail.$WP_DOMAIN
     - Without PTR, outbound mail to Gmail/Outlook/etc. will land in spam.
       Inbound and webmail still work fine - PTR only affects outbound
       deliverability reputation.

  6. Clear scrollback:  clear && history -c

EOF
echo "==================================================================="

if [ "$VERIFY_FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
