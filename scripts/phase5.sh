#!/bin/bash
#
# phase5.sh - Phase 5: Roundcube webmail
#
# Installs Roundcube webmail and serves it at https://<domain>/mail/.
# Connects to local Postfix (SMTP submission on 587) and Dovecot (IMAPS on 993)
# from Phase 4. Stores user preferences/contacts/identities in its own
# MariaDB database (separate from the Phase 4 mail user db).
#
# Includes the managesieve plugin so users can edit Sieve spam filters
# through the webmail interface (talks to dovecot-managesieved on 4190).
#
# Idempotent. Safe to re-run. Each step checks current state before acting.
# Produces a summary report and runs automated verification at the end.
#
# Run as root: sudo bash phase5.sh
#

set -u

# ============================================================================
# CONFIGURATION
# ============================================================================
# Non-domain-dependent constants.
MAIL_DOMAIN="docenttemplate.com"      # default - overridden by tenant.local
MAIL_HOSTNAME="mail.docenttemplate.com"  # default - overridden by tenant.local
ROUNDCUBE_DIR="/usr/share/roundcube"   # package install location
ROUNDCUBE_URL_PATH="/mail"             # served at https://<domain>/mail/
ROUNDCUBE_DB="roundcube"
ROUNDCUBE_DB_USER="roundcube"
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
# correct MAIL_DOMAIN value.
APACHE_VHOST="/etc/apache2/sites-available/${MAIL_DOMAIN}-le-ssl.conf"
CERT_DIR="/etc/letsencrypt/live/${MAIL_DOMAIN}"

# ============================================================================
# REPORT TRACKING
# ============================================================================
REPORT=()
# DO NOT initialize ROUNDCUBE_DB_PW or ROUNDCUBE_DES_KEY here - they were
# already set by sourcing secrets.local above. Setting them to "" would wipe
# out the canonical values from CREDENTIALS.txt and force the script to
# generate new ones, breaking the canonical-credentials design.

log_done() { REPORT+=("[DONE]    $1"); echo "  ✓ $1"; }
log_skip() { REPORT+=("[SKIPPED] $1 (already done)"); echo "  - $1 (already done)"; }
log_warn() { REPORT+=("[WARN]    $1"); echo "  ! $1"; }
log_fail() { REPORT+=("[FAIL]    $1"); echo "  ✗ $1"; }

step() { echo ""; echo "=== $1 ==="; }

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
# SAFETY CHECKS
# ============================================================================
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root (use sudo)."
    exit 1
fi

if [ ! -f "$ROOT_DEFAULTS_FILE" ]; then
    echo "ERROR: $ROOT_DEFAULTS_FILE not found. Phase 3 (database) must run first."
    exit 1
fi

if [ ! -d "$CERT_DIR" ]; then
    echo "ERROR: $CERT_DIR not found. Phase 2 (web + TLS) must run first."
    exit 1
fi

if ! systemctl is-active --quiet dovecot; then
    echo "ERROR: Dovecot is not running. Phase 4 (mail server) must run first."
    exit 1
fi

if ! systemctl is-active --quiet postfix; then
    echo "ERROR: Postfix is not running. Phase 4 (mail server) must run first."
    exit 1
fi

echo "==================================================================="
echo "  Phase 5 - Roundcube webmail for $MAIL_DOMAIN"
echo "  Will be served at: https://$MAIL_DOMAIN$ROUNDCUBE_URL_PATH/"
echo "  $(date)"
echo "==================================================================="

# ============================================================================
# STEP 1: Install Roundcube and dependencies
# ============================================================================
step "Step 1: Installing Roundcube packages"

export DEBIAN_FRONTEND=noninteractive

# Tell debconf NOT to auto-configure dbconfig (we'll do it ourselves so we
# control the password and reuse Phase 3's MariaDB). Saves a config dialog
# and stops the package post-install from writing its own /etc/roundcube/
# config that would clobber ours.
echo "roundcube-core roundcube/dbconfig-install boolean false" | debconf-set-selections
echo "roundcube-core roundcube/database-type select mysql" | debconf-set-selections

ROUNDCUBE_PACKAGES=(
    roundcube
    roundcube-core
    roundcube-mysql
    roundcube-plugins
    roundcube-plugins-extra
    php-net-sieve
)

MISSING=""
for pkg in "${ROUNDCUBE_PACKAGES[@]}"; do
    if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        MISSING="$MISSING $pkg"
    fi
done

if [ -z "$MISSING" ]; then
    log_skip "All Roundcube packages already installed"
else
    wait_for_dpkg_lock
    apt-get update -qq
    apt-get install -y -qq -o Dpkg::Use-Pty=0 $MISSING < /dev/null
    log_done "Installed:$MISSING"
fi

# ============================================================================
# STEP 1b: Patch Roundcube 1.6.11 array_first() conflict with PHP 8.5
# ============================================================================
step "Step 1b: Patching Roundcube for PHP 8.5 compatibility"

# Roundcube 1.6.11 (which Ubuntu 26.04 ships) defines a polyfill function
# array_first() in bootstrap.php. PHP 8.5 added array_first() as a built-in,
# so the polyfill collides with it -> Fatal error on startup.
# Roundcube 1.6.12+ fixed this by wrapping the polyfill in:
#     if (!function_exists("array_first")) { ... }
# We apply the same patch directly to the package's bootstrap.php.
# Idempotent - re-running this script does nothing if patch is already in place.
BOOTSTRAP_FILE=/usr/share/roundcube/program/lib/Roundcube/bootstrap.php
if [ ! -f "$BOOTSTRAP_FILE" ]; then
    log_warn "$BOOTSTRAP_FILE not found - skipping patch (Roundcube install layout may differ)"
elif grep -q 'if (!function_exists("array_first"))' "$BOOTSTRAP_FILE"; then
    log_skip "Roundcube bootstrap.php already patched for PHP 8.5"
else
    python3 <<PYEOF
import re
path = "$BOOTSTRAP_FILE"
with open(path, 'r') as f:
    content = f.read()
# Match the entire function definition and body
pattern = r'(function array_first\(\\\$array\)\s*\{[^}]*\})'
new_content, n = re.subn(pattern,
    r'if (!function_exists("array_first")) {\n\1\n}',
    content, count=1, flags=re.DOTALL)
if n == 0:
    print("ERROR: array_first() pattern not found in bootstrap.php")
    exit(1)
with open(path, 'w') as f:
    f.write(new_content)
print("Patched bootstrap.php")
PYEOF
    if [ $? -eq 0 ]; then
        log_done "Patched bootstrap.php (wrapped array_first() polyfill in function_exists check)"
    else
        log_fail "Failed to patch bootstrap.php"
        exit 1
    fi
fi

# ============================================================================
# STEP 2: Create Roundcube database
# ============================================================================
step "Step 2: Creating Roundcube database and user"

DB_EXISTS=$(mysql --defaults-file="$ROOT_DEFAULTS_FILE" -Nse \
    "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$ROUNDCUBE_DB';" 2>/dev/null || echo "0")
if [ "$DB_EXISTS" -gt 0 ]; then
    log_skip "Database $ROUNDCUBE_DB exists"
else
    mysql --defaults-file="$ROOT_DEFAULTS_FILE" -e \
        "CREATE DATABASE \`$ROUNDCUBE_DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    log_done "Created database $ROUNDCUBE_DB"
fi

USER_EXISTS=$(mysql --defaults-file="$ROOT_DEFAULTS_FILE" -Nse \
    "SELECT COUNT(*) FROM mysql.user WHERE User='$ROUNDCUBE_DB_USER' AND Host='localhost';" 2>/dev/null || echo "0")
if [ "$USER_EXISTS" -gt 0 ]; then
    log_skip "DB user $ROUNDCUBE_DB_USER exists"
    # Try to recover the password from existing config
    if [ -f /etc/roundcube/config.inc.php ]; then
        ROUNDCUBE_DB_PW=$(grep -oP "mysql://${ROUNDCUBE_DB_USER}:\K[^@]+" /etc/roundcube/config.inc.php 2>/dev/null || echo "")
    fi
else
    # Use ROUNDCUBE_DB_PW from secrets.local if available, otherwise generate.
    # When phase0 was used, ROUNDCUBE_DB_PW is the password documented in
    # CREDENTIALS.txt - we MUST use it so CREDENTIALS.txt stays canonical.
    if [ -z "${ROUNDCUBE_DB_PW:-}" ]; then
        ROUNDCUBE_DB_PW=$(openssl rand -base64 24 | tr -d '/+=' | head -c 28)
        log_warn "No ROUNDCUBE_DB_PW in secrets.local - generated a random one (NOT in CREDENTIALS.txt)"
    fi
    mysql --defaults-file="$ROOT_DEFAULTS_FILE" <<SQL
CREATE USER '$ROUNDCUBE_DB_USER'@'localhost' IDENTIFIED BY '$ROUNDCUBE_DB_PW';
GRANT ALL PRIVILEGES ON \`$ROUNDCUBE_DB\`.* TO '$ROUNDCUBE_DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL
    log_done "Created DB user $ROUNDCUBE_DB_USER (full access on $ROUNDCUBE_DB)"
fi

# Import Roundcube's schema if the database is empty
TABLE_COUNT=$(mysql --defaults-file="$ROOT_DEFAULTS_FILE" -Nse \
    "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$ROUNDCUBE_DB';" 2>/dev/null || echo "0")
if [ "$TABLE_COUNT" -gt 0 ]; then
    log_skip "Roundcube schema already loaded ($TABLE_COUNT tables)"
else
    SCHEMA_FILE=$(find /usr/share/roundcube /usr/share/dbconfig-common -name "mysql.initial.sql" 2>/dev/null | head -1)
    if [ -z "$SCHEMA_FILE" ]; then
        SCHEMA_FILE=$(find / -name "mysql.initial.sql" -path "*roundcube*" 2>/dev/null | head -1)
    fi
    if [ -n "$SCHEMA_FILE" ] && [ -f "$SCHEMA_FILE" ]; then
        mysql --defaults-file="$ROOT_DEFAULTS_FILE" "$ROUNDCUBE_DB" < "$SCHEMA_FILE"
        log_done "Imported Roundcube schema from $SCHEMA_FILE"
    else
        log_fail "Could not find Roundcube schema file (mysql.initial.sql)"
        echo "         Look manually in /usr/share/doc/roundcube*/SQL/ or /usr/share/dbconfig-common/data/roundcube/"
        exit 1
    fi
fi

# ============================================================================
# STEP 3: Configure Roundcube
# ============================================================================
step "Step 3: Configuring Roundcube"

# Generate a 24-char DES key (Roundcube uses this to encrypt session data)
ROUNDCUBE_CONFIG=/etc/roundcube/config.inc.php
if [ -f "$ROUNDCUBE_CONFIG" ] && grep -q "phase5-marker" "$ROUNDCUBE_CONFIG" 2>/dev/null; then
    log_skip "Roundcube already configured by this script"
    # Recover existing values to print at the end
    ROUNDCUBE_DES_KEY=$(grep -oP "\\\$config\['des_key'\] = '\K[^']+" "$ROUNDCUBE_CONFIG" 2>/dev/null || echo "")
else
    if [ -z "$ROUNDCUBE_DB_PW" ]; then
        log_warn "DB password unknown - resetting"
        # Use the value from secrets.local if it's there (CREDENTIALS.txt must
        # stay canonical). Otherwise generate.
        if [ -z "${ROUNDCUBE_DB_PW:-}" ]; then
            ROUNDCUBE_DB_PW=$(openssl rand -base64 24 | tr -d '/+=' | head -c 28)
            log_warn "No ROUNDCUBE_DB_PW in secrets.local - generated a random one (NOT in CREDENTIALS.txt)"
        fi
        mysql --defaults-file="$ROOT_DEFAULTS_FILE" -e \
            "ALTER USER '$ROUNDCUBE_DB_USER'@'localhost' IDENTIFIED BY '$ROUNDCUBE_DB_PW'; FLUSH PRIVILEGES;"
    fi
    # Use ROUNDCUBE_DES_KEY from secrets.local if available, otherwise generate.
    # When phase0 was used, ROUNDCUBE_DES_KEY is documented in CREDENTIALS.txt -
    # we MUST use it so CREDENTIALS.txt stays canonical.
    if [ -z "${ROUNDCUBE_DES_KEY:-}" ]; then
        ROUNDCUBE_DES_KEY=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
        log_warn "No ROUNDCUBE_DES_KEY in secrets.local - generated a random one (NOT in CREDENTIALS.txt)"
    fi

    cat > "$ROUNDCUBE_CONFIG" <<EOF
<?php
// phase5-marker - managed by phase5.sh
\$config = [];

// Database connection
\$config['db_dsnw'] = 'mysql://${ROUNDCUBE_DB_USER}:${ROUNDCUBE_DB_PW}@localhost/${ROUNDCUBE_DB}';

// IMAP server (Dovecot from Phase 4)
\$config['imap_host'] = 'ssl://${MAIL_HOSTNAME}:993';
\$config['imap_conn_options'] = [
    'ssl' => [
        'verify_peer'       => true,
        'verify_peer_name'  => true,
        // Use system CA bundle (/etc/ssl/certs/ca-certificates.crt) which
        // trusts Let's Encrypt. Don't override 'cafile' - that points it
        // at our server cert chain, not a CA bundle, causing chain
        // validation to fail with "unknown ca" error.
    ],
];

// SMTP server (Postfix submission port from Phase 4)
\$config['smtp_host'] = 'tls://${MAIL_HOSTNAME}:587';
\$config['smtp_user']      = '%u';   // use the logged-in user's address
\$config['smtp_pass']      = '%p';   // and password
\$config['smtp_conn_options'] = [
    'ssl' => [
        'verify_peer'       => true,
        'verify_peer_name'  => true,
        // (Same reasoning as imap_conn_options - no cafile override)
    ],
];

// Site / branding
\$config['support_url']  = '';
\$config['product_name'] = 'Webmail - ${MAIL_DOMAIN}';

// 24-char DES key used to encrypt cached IMAP password in session.
// Random per-server. Don't share. Don't change after deployment - users
// would lose any saved IMAP passwords (re-login fixes it).
\$config['des_key'] = '${ROUNDCUBE_DES_KEY}';

// Plugins enabled. managesieve lets users edit Sieve filters from webmail
// (talks to dovecot-managesieved on port 4190 from Phase 4 / 8b).
\$config['plugins'] = [
    'archive',
    'zipdownload',
    'managesieve',
];

// Skin
\$config['skin'] = 'elastic';

// Default address book - users can add personal contacts
\$config['address_book_type'] = 'sql';

// Username: require full email address always.
// (Earlier builds set \$config['username_domain'] = '\${MAIL_DOMAIN}' so users
// could type just 'wglover'. Removed because the login form does not make it
// clear which mode is active, leading users to think their password was wrong
// when they actually typed an unrecognized short username.)

// Force HTTPS - if someone hits http:// redirect to https://
\$config['force_https'] = true;

// Trust the X-Forwarded-Proto header that Apache will send when client
// arrived via HTTPS (so force_https doesn't infinite-loop)
\$config['proxy_whitelist'] = ['127.0.0.1', '::1'];

// Session lifetime in minutes (10 = idle timeout)
\$config['session_lifetime'] = 30;

// Don't show the "you are using Roundcube" footer
\$config['display_version'] = false;

// Logging - keep logs in /var/log/roundcube/ (default location)
\$config['log_driver'] = 'file';
\$config['log_dir'] = '/var/log/roundcube/';

// Default folder behavior - file sent mail in Sent, drafts in Drafts, etc.
// Phase 4's Dovecot config auto-creates these folders on first login.
\$config['drafts_mbox'] = 'Drafts';
\$config['sent_mbox']   = 'Sent';
\$config['trash_mbox']  = 'Trash';
\$config['junk_mbox']   = 'Junk';
EOF
    chown root:www-data "$ROUNDCUBE_CONFIG"
    chmod 640 "$ROUNDCUBE_CONFIG"
    log_done "Wrote $ROUNDCUBE_CONFIG"
fi

# ============================================================================
# STEP 4: Configure managesieve plugin
# ============================================================================
step "Step 4: Configuring managesieve plugin"

# The managesieve plugin lets users edit Sieve filters from the webmail UI.
# It connects to dovecot-managesieved on port 4190 (set up in Phase 4 step 8b).
SIEVE_PLUGIN_CONFIG=/etc/roundcube/plugins/managesieve/config.inc.php
mkdir -p "$(dirname "$SIEVE_PLUGIN_CONFIG")"
if [ -f "$SIEVE_PLUGIN_CONFIG" ] && grep -q "phase5-marker" "$SIEVE_PLUGIN_CONFIG" 2>/dev/null; then
    log_skip "managesieve plugin already configured by this script"
else
    cat > "$SIEVE_PLUGIN_CONFIG" <<EOF
<?php
// phase5-marker - managed by phase5.sh
// Connects to dovecot-managesieved on localhost:4190 (TLS via STARTTLS)
\$config['managesieve_host']      = 'tls://${MAIL_HOSTNAME}:4190';
\$config['managesieve_usetls']    = false;  // already wrapped in tls:// above
\$config['managesieve_default']   = '/etc/dovecot/sieve/global.sieve';
\$config['managesieve_mbox_encoding'] = 'UTF-8';
\$config['managesieve_replace_delimiter'] = '';
\$config['managesieve_disabled_extensions'] = [];
\$config['managesieve_debug']     = false;
\$config['managesieve_conn_options'] = [
    'ssl' => [
        'verify_peer'       => true,
        'verify_peer_name'  => true,
        // Use system CA bundle - don't override cafile (see config.inc.php)
    ],
];
EOF
    chown root:www-data "$SIEVE_PLUGIN_CONFIG"
    chmod 640 "$SIEVE_PLUGIN_CONFIG"
    log_done "Wrote $SIEVE_PLUGIN_CONFIG"
fi

# ============================================================================
# STEP 4b: Make Let's Encrypt cert readable by www-data
# ============================================================================
step "Step 4b: Granting www-data read access to Let's Encrypt cert"

# By default, certbot creates /etc/letsencrypt/live/ and /etc/letsencrypt/archive/
# with mode 700 owned by root. PHP running as www-data cannot read the cert,
# so Roundcube's TLS connection to Dovecot fails with "failed loading cafile
# stream" or "certificate verify failed". Granting group www-data read access
# is the standard fix used by every webmail/mail-aware app on the server.
#
# This is idempotent - re-running just sets the same perms.
if [ -d /etc/letsencrypt/live ] && [ -d /etc/letsencrypt/archive ]; then
    chgrp -R www-data /etc/letsencrypt/live /etc/letsencrypt/archive
    chmod -R g+rX /etc/letsencrypt/live /etc/letsencrypt/archive
    log_done "Granted www-data read access to /etc/letsencrypt/{live,archive}"
else
    log_warn "Let's Encrypt directories not found - skipping cert perms"
fi

# ============================================================================
# STEP 5: Configure Apache to serve Roundcube
# ============================================================================
step "Step 5: Configuring Apache to serve Roundcube at $ROUNDCUBE_URL_PATH"

# Approach: instead of modifying the live vhost file (fragile, hard to roll
# back, easy to corrupt), we ship Roundcube directives in a separate config
# file at /etc/apache2/conf-available/roundcube-mail.conf and enable it with
# a2enconf. This loads the directives globally - the Alias and <Directory>
# blocks apply to all vhosts that match the path. Apache "Alias" directives
# work this way regardless of which <VirtualHost> they sit under, as long
# as no vhost has an overriding Alias for the same path.
#
# This is the same pattern Roundcube's own package uses (the package ships
# /etc/apache2/conf-available/roundcube.conf with the /roundcube alias).
#
# To roll back: a2disconf roundcube-mail && systemctl reload apache2

# Disable the package-default /roundcube alias - we use /mail instead
if [ -f /etc/apache2/conf-enabled/roundcube.conf ]; then
    a2disconf roundcube >/dev/null 2>&1
    log_done "Disabled default /roundcube alias"
else
    log_skip "Default /roundcube alias not enabled"
fi

# Create our Roundcube config file
ROUNDCUBE_APACHE_CONF=/etc/apache2/conf-available/roundcube-mail.conf

cat > "$ROUNDCUBE_APACHE_CONF" <<EOF
# phase5-roundcube - Roundcube webmail at $ROUNDCUBE_URL_PATH/
# Managed by phase5.sh - to roll back: a2disconf roundcube-mail
#
# Why AllowOverride None: Roundcube ships an .htaccess at
# /var/lib/roundcube/public_html/.htaccess with rewrite rules designed for
# a / mount, not /$ROUNDCUBE_URL_PATH/. The regex denies any URL whose
# first path segment has no dot - which kills /skins/, /program/, /plugins/
# when accessed via our alias. We replicate the security rules below in
# a form that works for the alias path.

Alias $ROUNDCUBE_URL_PATH /var/lib/roundcube/public_html

<Directory /var/lib/roundcube/public_html>
    Options FollowSymLinks
    AllowOverride None
    Require all granted
</Directory>

# Allow asset access throughout the symlinked tree
<Directory /usr/share/roundcube>
    Options FollowSymLinks
    AllowOverride None
    Require all granted
</Directory>

# Block sensitive Roundcube directories (replicates rules from the .htaccess
# we disabled with AllowOverride None)
<Directory /usr/share/roundcube/SQL>
    Require all denied
</Directory>
<Directory /usr/share/roundcube/bin>
    Require all denied
</Directory>
<Directory /usr/share/roundcube/program/include>
    Require all denied
</Directory>
<Directory /usr/share/roundcube/program/lib>
    Require all denied
</Directory>
<Directory /usr/share/roundcube/program/localization>
    Require all denied
</Directory>
<Directory /usr/share/roundcube/program/steps>
    Require all denied
</Directory>
<Directory /var/lib/roundcube/config>
    Require all denied
</Directory>
<Directory /var/lib/roundcube/temp>
    Require all denied
</Directory>
<Directory /var/lib/roundcube/logs>
    Require all denied
</Directory>

# Block sensitive files anywhere under the tree
<FilesMatch "(?i)^(README.*|CHANGELOG.*|SECURITY.*|composer\..*|jsdeps\.json|meta\.json|\.htaccess|\.htpasswd|\.git.*)\$">
    Require all denied
</FilesMatch>
EOF

log_done "Wrote $ROUNDCUBE_APACHE_CONF"

# Enable our config (creates symlink in /etc/apache2/conf-enabled/)
a2enconf roundcube-mail >/dev/null 2>&1
log_done "Enabled roundcube-mail config (a2enconf)"

# Make sure mod_rewrite and php are enabled
a2enmod rewrite >/dev/null 2>&1 && log_done "Apache mod_rewrite enabled"
PHP_VER=$(ls /etc/apache2/mods-available/ 2>/dev/null | grep -oP 'php\d+(\.\d+)?\.conf' | head -1 | sed 's/\.conf//')
if [ -n "$PHP_VER" ]; then
    a2enmod "$PHP_VER" >/dev/null 2>&1 && log_done "Apache $PHP_VER enabled"
fi

# Validate Apache config before reload - if config is broken, do NOT reload
# (a broken reload would take the WordPress site down with it)
if apache2ctl configtest 2>&1 | grep -q "Syntax OK"; then
    systemctl reload apache2
    log_done "Apache config valid, reloaded"
else
    log_fail "Apache config has errors. NOT reloading (site stays up)."
    apache2ctl configtest 2>&1 | tail -10
    echo ""
    echo "  To roll back manually:"
    echo "    sudo a2disconf roundcube-mail"
    echo "    sudo systemctl reload apache2"
    exit 1
fi

# ============================================================================
# STEP 6: Permissions on Roundcube directories
# ============================================================================
step "Step 6: Setting Roundcube directory permissions"

# Roundcube needs to write to /var/log/roundcube and /var/lib/roundcube
for dir in /var/log/roundcube /var/lib/roundcube; do
    if [ -d "$dir" ]; then
        chown -R www-data:www-data "$dir"
        chmod 750 "$dir"
        log_done "Set $dir ownership to www-data:www-data mode 750"
    else
        mkdir -p "$dir"
        chown www-data:www-data "$dir"
        chmod 750 "$dir"
        log_done "Created $dir (www-data:www-data, mode 750)"
    fi
done

# ============================================================================
# REPORT
# ============================================================================
echo ""
echo "==================================================================="
echo "  PHASE 5 COMPLETE - SUMMARY REPORT"
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
echo "  The Roundcube DB password and DES key are also stored in:"
echo "    /etc/roundcube/config.inc.php"
echo ""

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

vp() { echo "  [PASS] $1"; VERIFY_PASS=$((VERIFY_PASS + 1)); }
vf() { echo "  [FAIL] $1"; VERIFY_FAIL=$((VERIFY_FAIL + 1)); }

for pkg in roundcube roundcube-core roundcube-mysql roundcube-plugins; do
    if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        vp "Package $pkg installed"
    else
        vf "Package $pkg NOT installed"
    fi
done

if [ -f /etc/roundcube/config.inc.php ] && grep -q "phase5-marker" /etc/roundcube/config.inc.php; then
    vp "Roundcube main config exists and is managed by phase5.sh"
else
    vf "Roundcube main config missing or not phase5-managed"
fi

if [ -f /etc/roundcube/plugins/managesieve/config.inc.php ] && grep -q "phase5-marker" /etc/roundcube/plugins/managesieve/config.inc.php; then
    vp "managesieve plugin config exists and is managed by phase5.sh"
else
    vf "managesieve plugin config missing"
fi

if mysql --defaults-file="$ROOT_DEFAULTS_FILE" -Nse \
   "SELECT 1 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$ROUNDCUBE_DB';" 2>/dev/null | grep -q 1; then
    vp "Database $ROUNDCUBE_DB exists"
else
    vf "Database $ROUNDCUBE_DB does NOT exist"
fi

TC=$(mysql --defaults-file="$ROOT_DEFAULTS_FILE" -Nse \
    "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$ROUNDCUBE_DB';" 2>/dev/null || echo "0")
if [ "$TC" -gt 5 ]; then
    vp "Roundcube schema loaded ($TC tables)"
else
    vf "Roundcube schema not loaded properly (only $TC tables found)"
fi

if mysql --defaults-file="$ROOT_DEFAULTS_FILE" -Nse \
   "SELECT 1 FROM mysql.user WHERE User='$ROUNDCUBE_DB_USER' AND Host='localhost';" 2>/dev/null | grep -q 1; then
    vp "DB user $ROUNDCUBE_DB_USER exists"
else
    vf "DB user $ROUNDCUBE_DB_USER missing"
fi

if [ -f /etc/apache2/conf-enabled/roundcube-mail.conf ] || [ -L /etc/apache2/conf-enabled/roundcube-mail.conf ]; then
    vp "Apache roundcube-mail config is enabled"
else
    vf "Apache roundcube-mail config is NOT enabled"
fi

if grep -q "Alias $ROUNDCUBE_URL_PATH /var/lib/roundcube/public_html" /etc/apache2/conf-available/roundcube-mail.conf 2>/dev/null; then
    vp "Roundcube Alias points at correct path"
else
    vf "Roundcube Alias missing or wrong path"
fi

if apache2ctl configtest 2>&1 | grep -q "Syntax OK"; then
    vp "Apache config syntax OK"
else
    vf "Apache config has errors"
fi

if systemctl is-active --quiet apache2; then
    vp "Apache is running"
else
    vf "Apache is NOT running"
fi

# Test that Roundcube responds at https://<domain>/mail/
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    "https://${MAIL_DOMAIN}${ROUNDCUBE_URL_PATH}/" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ] || [ "$HTTP_CODE" = "301" ]; then
    vp "Roundcube responds at https://${MAIL_DOMAIN}${ROUNDCUBE_URL_PATH}/ (HTTP $HTTP_CODE)"
else
    vf "Roundcube does NOT respond at https://${MAIL_DOMAIN}${ROUNDCUBE_URL_PATH}/ (HTTP $HTTP_CODE)"
fi

# Test that Roundcube can connect to its database
if mysql -u "$ROUNDCUBE_DB_USER" -p"$ROUNDCUBE_DB_PW" "$ROUNDCUBE_DB" -e "SELECT 1;" 2>/dev/null | grep -q 1; then
    vp "Roundcube DB user can connect to $ROUNDCUBE_DB"
else
    vf "Roundcube DB user CANNOT connect to $ROUNDCUBE_DB (check password in config)"
fi

# Verify managesieve port (4190) is reachable
if timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/4190; echo OK <&3' 2>/dev/null | grep -q .; then
    vp "ManageSieve (port 4190) reachable from localhost"
else
    vf "ManageSieve (port 4190) NOT reachable - check Phase 4 dovecot-managesieved"
fi

if [ -f /var/lib/roundcube/public_html/index.php ] || [ -L /var/lib/roundcube/public_html/index.php ]; then
    vp "Roundcube web root exists at /var/lib/roundcube/public_html"
else
    vf "Roundcube web root /var/lib/roundcube/public_html missing"
fi

if grep -q 'if (!function_exists("array_first"))' /usr/share/roundcube/program/lib/Roundcube/bootstrap.php 2>/dev/null; then
    vp "bootstrap.php patched for PHP 8.5 compatibility"
else
    vf "bootstrap.php NOT patched - Roundcube will fail on PHP 8.5"
fi

if [ -r /etc/letsencrypt/live/${MAIL_DOMAIN}/fullchain.pem ] && \
   sudo -u www-data test -r /etc/letsencrypt/live/${MAIL_DOMAIN}/fullchain.pem 2>/dev/null; then
    vp "www-data can read Let's Encrypt cert (TLS to Dovecot will work)"
else
    vf "www-data CANNOT read Let's Encrypt cert - TLS to Dovecot will fail"
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

  1. Open a web browser and go to:
       https://${MAIL_DOMAIN}${ROUNDCUBE_URL_PATH}/

     You should see the Roundcube login page.

  2. Log in with the test mailbox credentials from Phase 4:
       Username:  wglover@${MAIL_DOMAIN}  (full email address required)
       Password:  (the test mailbox password from Phase 4)

  3. You should land in the inbox and see your existing messages
     (the local test, IONOS test, plus any others).

  4. Try composing a new message and sending it. Check the mail log:
       sudo tail -30 /var/log/mail.log

     You should see SASL authentication and outbound delivery.

  5. SIEVE FILTER TEST:
     Click Settings (top right gear) -> Filters -> + (create rule)
     If managesieve is working, you'll see Sieve rule editor.
     The default global script (file X-Spam-Flag mail to Junk) is already
     active - you don't need to recreate it. This is for adding
     per-user custom rules.

  6. Check for errors:
       sudo tail /var/log/roundcube/errors.log
       sudo tail /var/log/apache2/error.log

  Roundcube is now available alongside Thunderbird/Outlook IMAP access.
  Users can pick whichever interface they prefer. Both go through the
  same Postfix and Dovecot - same mailbox, same folders.

EOF
echo "==================================================================="

if [ "$VERIFY_FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
