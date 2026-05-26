#!/bin/bash
#
# phase6.sh - Phase 6: WordPress core install on $DOMAIN
#
# This script installs vanilla WordPress core, creates its database, and
# configures Apache to serve it at https://$DOMAIN/. After this script
# runs, you finish setup interactively at https://$DOMAIN/wp-admin/install.php
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
DOMAIN="docenttemplate.com"      # default - overridden by tenant.local
WP_DOMAIN_ALT="www.docenttemplate.com"  # default - overridden by tenant.local
WP_DB_NAME="wordpress_docenttemplate"   # default - overridden by tenant.local
WP_DB_USER="wp_dt_user"             # default - overridden by tenant.local
WP_ADMIN_USERNAME="wpadmin"          # default - overridden by tenant.local
WP_ADMIN_EMAIL="wglover@docentims.com"  # default - overridden by tenant.local
WP_SITE_TITLE="Docent IMS"          # default - overridden by tenant.local
ROOT_DEFAULTS_FILE="/root/.my.cnf"

# Load shared helpers and per-tenant config. lib/common.sh sources
# tenant.local/secrets.local (overriding the hardcoded defaults above) and
# provides colors, logging helpers, and verification helpers.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

# Domain-dependent paths. Computed AFTER sourcing so they pick up the
# correct DOMAIN value.
WP_DIR="/srv/www/$DOMAIN"
WP_VHOST_FILE="/etc/apache2/sites-available/${DOMAIN}.conf"
WP_CONFIG="$WP_DIR/wp-config.php"

# ============================================================================
# REPORT TRACKING
# ============================================================================
REPORT=()
# DO NOT initialize WP_DB_PW here - it was already set by sourcing
# secrets.local above. Setting it to "" would wipe out the canonical
# value from CREDENTIALS.txt and force the script to generate a new one,
# breaking the canonical-credentials design.



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

if [ ! -f "$ROOT_DEFAULTS_FILE" ]; then
    echo "ERROR: $ROOT_DEFAULTS_FILE not found. Phase 3 (database) must run first."
    exit 1
fi

echo "==================================================================="
echo "  Phase 6 - WordPress core install for $DOMAIN"
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
    wait_for_dpkg_lock
    apt-get update -qq
    if apt-get install -y -qq -o Dpkg::Use-Pty=0 $MISSING < /dev/null; then
        log_done "Installed:$MISSING"
    else
        log_fail "apt-get install failed for:$MISSING - see output above"
        exit 1
    fi
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
        WP_DB_PW=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 28)
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
            WP_DB_PW=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 28)
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
#   - $DOMAIN.conf             (placeholder for the primary domain on :80)
#   - $DOMAIN-le-ssl.conf      (placeholder SSL vhost on :443, generated
#                                  by certbot install in phase 2 step 7b)
#
# We do NOT disable the 000-default* catch-alls - they handle requests
# for unknown hostnames (like mail.$DOMAIN). We just overwrite the
# primary-domain vhost files with the WordPress configuration.

# Write our WP-specific vhost (covers both :80 and :443; redirect HTTP -> HTTPS)
CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
cat > "$WP_VHOST_FILE" <<EOF
# phase6-marker - managed by phase6.sh
<VirtualHost *:80>
    ServerName $DOMAIN
    ServerAlias $WP_DOMAIN_ALT
    RewriteEngine On
    RewriteCond %{HTTPS} !=on
    RewriteRule ^/?(.*) https://$DOMAIN/\$1 [R=301,L]
</VirtualHost>

<VirtualHost *:443>
    ServerName $DOMAIN
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

    ErrorLog \${APACHE_LOG_DIR}/$DOMAIN-error.log
    CustomLog \${APACHE_LOG_DIR}/$DOMAIN-access.log combined
</VirtualHost>
EOF
log_done "Wrote $WP_VHOST_FILE (WordPress vhost for $DOMAIN, both :80 and :443)"

# Phase 2's certbot install may have generated $DOMAIN-le-ssl.conf as a
# separate file. We now have everything in $WP_VHOST_FILE, so disable any
# stale -le-ssl twin so we don't have duplicate :443 vhosts for the domain.
LE_SSL_TWIN="$DOMAIN-le-ssl"
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
    log_fail "Skipping reload to avoid disrupting Apache with a broken config."
    exit 1
fi

# Reload Apache
systemctl reload apache2
if systemctl is-active --quiet apache2; then
    log_done "Apache reloaded"
else
    log_fail "Apache failed to reload"
fi

# ============================================================================
# STEP 7: Install wp-cli and run the WordPress install wizard
# ============================================================================
# Previously phase 6 stopped here and asked the user to open
# https://<domain>/wp-admin/install.php in a browser and fill in a form.
# wp-cli lets us do the same thing from the command line, idempotently.
# Re-running this step is safe: 'wp core is-installed' returns 0 if the
# install already happened and we skip everything below.
step "Step 7: Running the WordPress install wizard via wp-cli"

WP_CLI_BIN="/usr/local/bin/wp"
WP_CLI_URL="https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar"

# Install wp-cli if not already present.
if [ -x "$WP_CLI_BIN" ]; then
    WP_CLI_VERSION=$("$WP_CLI_BIN" --version 2>/dev/null | awk '{print $2}')
    log_skip "wp-cli already installed (version ${WP_CLI_VERSION:-unknown})"
else
    if curl -fsSL -o /tmp/wp-cli.phar "$WP_CLI_URL"; then
        chmod +x /tmp/wp-cli.phar
        mv /tmp/wp-cli.phar "$WP_CLI_BIN"
        WP_CLI_VERSION=$("$WP_CLI_BIN" --version 2>/dev/null | awk '{print $2}')
        log_done "Installed wp-cli to $WP_CLI_BIN (version ${WP_CLI_VERSION:-unknown})"
    else
        log_fail "Failed to download wp-cli from $WP_CLI_URL"
        exit 1
    fi
fi

# Sanity-check that the password is available in this script's environment.
# If WP_ADMIN_PW isn't set (e.g. an older phase 0 ran before this variable was
# introduced), bail out with a clear error rather than inventing one.
if [ -z "${WP_ADMIN_PW:-}" ]; then
    log_fail "WP_ADMIN_PW is not set. Re-run phase 0 to regenerate secrets.local,"
    log_fail "or set it manually in $REPO_ROOT/secrets.local and re-run phase 6."
    exit 1
fi

# Run the install (idempotent: only runs if WP isn't already installed).
# All wp-cli calls go through 'sudo -u www-data' so files are owned correctly.
if sudo -u www-data "$WP_CLI_BIN" --path="$WP_DIR" core is-installed 2>/dev/null; then
    log_skip "WordPress is already installed (skipping wizard)"
else
    if sudo -u www-data "$WP_CLI_BIN" --path="$WP_DIR" core install \
            --url="https://$DOMAIN" \
            --title="$WP_SITE_TITLE" \
            --admin_user="$WP_ADMIN_USERNAME" \
            --admin_password="$WP_ADMIN_PW" \
            --admin_email="$WP_ADMIN_EMAIL" \
            --skip-email; then
        log_done "WordPress installed (site: $WP_SITE_TITLE, admin: $WP_ADMIN_USERNAME)"
    else
        log_fail "wp-cli core install failed"
        exit 1
    fi
fi

# Discourage search engines = CHECKED.
# blog_public is the inverse: 0 means "discourage", 1 means "allow indexing".
# Setting to 0 makes WP add a noindex meta tag and disallow robots in /robots.txt.
CURRENT_BLOG_PUBLIC=$(sudo -u www-data "$WP_CLI_BIN" --path="$WP_DIR" option get blog_public 2>/dev/null || echo "")
if [ "$CURRENT_BLOG_PUBLIC" = "0" ]; then
    log_skip "Search engine visibility already set to 'discourage' (blog_public=0)"
else
    if sudo -u www-data "$WP_CLI_BIN" --path="$WP_DIR" option update blog_public 0 >/dev/null 2>&1; then
        log_done "Set search engine visibility to 'discourage' (blog_public=0)"
    else
        log_fail "Failed to set blog_public=0"
    fi
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
echo "  WordPress admin login (created automatically by Step 7):"
echo "    URL:      https://$DOMAIN/wp-admin/"
echo "    Username: $WP_ADMIN_USERNAME"
echo "    Password: see CREDENTIALS.txt (WP_ADMIN_PW)"
echo "    Email:    $WP_ADMIN_EMAIL"

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
       MYSQL_PWD="$EXTRACTED_PW" mysql -u"$WP_DB_USER" -e "USE $WP_DB_NAME;" >/dev/null 2>&1; then
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
HTTPS_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "https://$DOMAIN/" 2>/dev/null || echo "000")
# WP install screen returns 200 (or 302 to install.php). Both are fine.
if [ "$HTTPS_CODE" = "200" ] || [ "$HTTPS_CODE" = "302" ]; then
    echo "  [PASS] https://$DOMAIN/ returned HTTP $HTTPS_CODE"
    VERIFY_PASS=$((VERIFY_PASS + 1))
else
    echo "  [FAIL] https://$DOMAIN/ returned HTTP $HTTPS_CODE"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# wp-login.php reachable (proves PHP is executing)
LOGIN_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "https://$DOMAIN/wp-login.php" 2>/dev/null || echo "000")
if [ "$LOGIN_CODE" = "200" ] || [ "$LOGIN_CODE" = "302" ]; then
    echo "  [PASS] PHP executes correctly (wp-login.php returned $LOGIN_CODE)"
    VERIFY_PASS=$((VERIFY_PASS + 1))
else
    echo "  [FAIL] wp-login.php returned $LOGIN_CODE - PHP may not be executing"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# wp-config.php is NOT readable from the web (security check)
WP_CONFIG_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "https://$DOMAIN/wp-config.php" 2>/dev/null || echo "000")
if [ "$WP_CONFIG_CODE" = "403" ]; then
    echo "  [PASS] wp-config.php is blocked from web access (403)"
    VERIFY_PASS=$((VERIFY_PASS + 1))
elif [ "$WP_CONFIG_CODE" = "200" ]; then
    # 200 with empty body is also acceptable (PHP executes the file but it has no output)
    BODY=$(curl -s --max-time 10 "https://$DOMAIN/wp-config.php" 2>/dev/null | head -c 50)
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

# wp-cli binary exists and is executable
if [ -x "$WP_CLI_BIN" ]; then
    echo "  [PASS] wp-cli installed at $WP_CLI_BIN"
    VERIFY_PASS=$((VERIFY_PASS + 1))
else
    echo "  [FAIL] wp-cli not found at $WP_CLI_BIN"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# WordPress is installed (wp_options table populated)
if sudo -u www-data "$WP_CLI_BIN" --path="$WP_DIR" core is-installed 2>/dev/null; then
    echo "  [PASS] WordPress is installed (wp core is-installed returned 0)"
    VERIFY_PASS=$((VERIFY_PASS + 1))
else
    echo "  [FAIL] WordPress is NOT installed (wp core is-installed failed)"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# blog_public is 0 (discourage search engines = checked)
BP=$(sudo -u www-data "$WP_CLI_BIN" --path="$WP_DIR" option get blog_public 2>/dev/null || echo "")
if [ "$BP" = "0" ]; then
    echo "  [PASS] Search engine visibility set to 'discourage' (blog_public=0)"
    VERIFY_PASS=$((VERIFY_PASS + 1))
else
    echo "  [FAIL] blog_public is '$BP', expected '0' (search engines should be discouraged)"
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
echo "  MANUAL VERIFICATION & NEXT STEPS"
echo "==================================================================="
cat <<EOF

  1. Confirm CREDENTIALS.txt is saved in your password manager.
     Both WordPress passwords (admin and database) are in
     BACKEND PASSWORDS.

  2. Log in to WordPress:
       URL:      https://$DOMAIN/wp-admin/
       Username: $WP_ADMIN_USERNAME
       Password: see CREDENTIALS.txt BACKEND PASSWORDS (WordPress admin)

     The site is already installed (Step 7 ran the wizard via wp-cli).
     Search engine visibility is set to 'discourage' (placeholder/template
     content shouldn't be indexed). Toggle that off in Settings > Reading
     once the site is publicly ready.

  3. Theme/configure the site to look like a real Docent project page,
     using whatever template/approach you've used before.

  4. Set the PTR (reverse DNS) record:
     - Return to Hetzner and manually activate a PTR record:
         PTR $SERVER_IP -> mail.$DOMAIN
       (Hetzner Cloud Console -> select this server -> set the reverse
        DNS on the server's IPv4 address. No support ticket needed.)
     - Without PTR, outbound mail to Gmail/Outlook/etc. will land in spam.
       Inbound and webmail still work fine - PTR only affects outbound
       deliverability reputation.

  5. Clear scrollback:  clear && history -c

EOF
echo "==================================================================="

if [ "$VERIFY_FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
