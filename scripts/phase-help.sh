#!/bin/bash
#
# phase-help.sh - Phase: Docent help site at help.<domain>
#
# Clones the DocentIMS/HelpFiles repo and serves its generated WebHelp/ folder
# (Help & Manual static web output) at https://help.<domain>/ via its own
# Apache vhost + Let's Encrypt cert - mirroring how phase 5 serves
# mail.<domain> and phase 7c serves team.<domain>. Static HTML only: no build
# step, no database, no app server.
#
# Idempotent. Safe to re-run: re-pulls the repo and re-uses the existing cert.
#
# Run as root via run-phases.sh, or directly: sudo bash phase-help.sh
#

set -u

# ============================================================================
# CONFIGURATION
# ============================================================================
DOMAIN="docenttemplate.com"      # default - overridden by tenant.local

HELP_REPO_URL="https://github.com/DocentIMS/HelpFiles.git"
HELP_SRC_DIR="/srv/www/help"     # git checkout lives here
HELP_WEBHELP_SUBDIR="WebHelp"    # the generated static site inside the repo

# Load shared helpers + per-tenant config (sources tenant.local/secrets.local,
# so DOMAIN / DEFAULT_SITE_DIR / NOTIFICATION_EMAIL come from there; also
# provides colors and log_done/log_skip/log_warn/log_fail/step).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

# Domain-dependent (computed AFTER common.sh sourced tenant.local).
HELP_PUBLIC_HOST="help.${DOMAIN}"
HELP_CERT_DIR="/etc/letsencrypt/live/${HELP_PUBLIC_HOST}"
HELP_VHOST_FILE="/etc/apache2/sites-available/${HELP_PUBLIC_HOST}.conf"
HELP_DOCROOT="${HELP_SRC_DIR}/${HELP_WEBHELP_SUBDIR}"

REPORT=()

# ============================================================================
# Must run as root
# ============================================================================
if [ "$(id -u)" -ne 0 ]; then
    echo "This phase must run as root. Try: sudo bash $0"
    exit 1
fi

echo ""
echo "==================================================================="
echo "  PHASE HELP: Docent help site at https://$HELP_PUBLIC_HOST/"
echo "==================================================================="

# ----------------------------------------------------------------------------
# Step 1: clone or update the HelpFiles repo
# ----------------------------------------------------------------------------
step "Step 1: Fetch the HelpFiles content"
if ! command -v git >/dev/null 2>&1; then
    log_fail "git not found - phase 1 installs it; run phase 1 first."
    exit 1
fi
if [ -d "$HELP_SRC_DIR/.git" ]; then
    if git -C "$HELP_SRC_DIR" pull --ff-only >/dev/null 2>&1; then
        log_done "Updated existing checkout at $HELP_SRC_DIR"
    else
        log_warn "Could not fast-forward $HELP_SRC_DIR; using the existing copy"
    fi
else
    mkdir -p "$(dirname "$HELP_SRC_DIR")"
    if git clone --depth 1 "$HELP_REPO_URL" "$HELP_SRC_DIR" >/dev/null 2>&1; then
        log_done "Cloned $HELP_REPO_URL -> $HELP_SRC_DIR"
    else
        log_fail "git clone failed for $HELP_REPO_URL"
        exit 1
    fi
fi

if [ ! -f "$HELP_DOCROOT/index.html" ]; then
    log_fail "$HELP_DOCROOT/index.html not found (expected ${HELP_WEBHELP_SUBDIR}/index.html in the repo)."
    exit 1
fi
log_done "Help content present: $HELP_DOCROOT/index.html"

# ----------------------------------------------------------------------------
# Step 2: Let's Encrypt cert for help.<domain>
# ----------------------------------------------------------------------------
# Same --webroot pattern as phase 2 / 5 / 7c: certbot writes the ACME challenge
# into the default-site webroot (served for any hostname), so we get the cert
# before standing the vhost up.
step "Step 2: TLS certificate for $HELP_PUBLIC_HOST"
if [ -f "$HELP_CERT_DIR/fullchain.pem" ]; then
    log_skip "Certificate for $HELP_PUBLIC_HOST already exists"
else
    if ! command -v certbot >/dev/null 2>&1; then
        log_fail "certbot not found - phase 2 must run first"
        exit 1
    fi
    WEBROOT_PATH="${DEFAULT_SITE_DIR:-/srv/www/default}"
    if [ ! -d "$WEBROOT_PATH" ]; then
        log_fail "Webroot $WEBROOT_PATH does not exist - did phase 2 run?"
        exit 1
    fi
    if ! certbot certonly \
            --webroot \
            --webroot-path "$WEBROOT_PATH" \
            --non-interactive \
            --agree-tos \
            --email "${NOTIFICATION_EMAIL:-admin@$DOMAIN}" \
            -d "$HELP_PUBLIC_HOST"; then
        log_fail "certbot failed for $HELP_PUBLIC_HOST"
        log_fail "Common causes: help.$DOMAIN not resolving to this server, or port 80 blocked."
        exit 1
    fi
    log_done "Obtained Let's Encrypt cert for $HELP_PUBLIC_HOST"
fi

# ----------------------------------------------------------------------------
# Step 3: Apache vhost serving the static WebHelp at help.<domain>
# ----------------------------------------------------------------------------
step "Step 3: Apache vhost for $HELP_PUBLIC_HOST"
a2enmod ssl rewrite >/dev/null 2>&1 || true   # phase 2 normally enables these

if [ -f "$HELP_VHOST_FILE" ] && grep -q "phase-help-marker" "$HELP_VHOST_FILE" 2>/dev/null; then
    log_skip "Apache vhost $HELP_VHOST_FILE already managed by phase-help"
else
    cat > "$HELP_VHOST_FILE" <<EOF
# phase-help-marker - managed by phase-help.sh
# Static Docent help site served at https://$HELP_PUBLIC_HOST/
# To roll back: a2dissite ${HELP_PUBLIC_HOST}.conf && systemctl reload apache2

<VirtualHost *:80>
    ServerName $HELP_PUBLIC_HOST
    RewriteEngine On
    RewriteCond %{HTTPS} !=on
    RewriteRule ^/?(.*) https://$HELP_PUBLIC_HOST/\$1 [R=301,L]
</VirtualHost>

<VirtualHost *:443>
    ServerName $HELP_PUBLIC_HOST

    SSLEngine on
    SSLCertificateFile $HELP_CERT_DIR/fullchain.pem
    SSLCertificateKeyFile $HELP_CERT_DIR/privkey.pem

    DocumentRoot $HELP_DOCROOT
    DirectoryIndex index.html

    <Directory $HELP_DOCROOT>
        Options -Indexes +FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/$HELP_PUBLIC_HOST-error.log
    CustomLog \${APACHE_LOG_DIR}/$HELP_PUBLIC_HOST-access.log combined
</VirtualHost>
EOF
    chmod 644 "$HELP_VHOST_FILE"
    [ -s "$HELP_VHOST_FILE" ] || { log_fail "Heredoc wrote zero bytes to $HELP_VHOST_FILE"; exit 1; }
    log_done "Wrote $HELP_VHOST_FILE"
fi

if [ -L "/etc/apache2/sites-enabled/${HELP_PUBLIC_HOST}.conf" ]; then
    log_skip "Apache vhost $HELP_PUBLIC_HOST already enabled"
else
    a2ensite "${HELP_PUBLIC_HOST}.conf" >/dev/null 2>&1
    log_done "Enabled apache2 site $HELP_PUBLIC_HOST"
fi

if apache2ctl configtest >/dev/null 2>&1; then
    systemctl reload apache2
    log_done "Apache config valid; reloaded"
else
    log_fail "apache2ctl configtest failed - not reloading. Run 'apache2ctl configtest' to see why."
    exit 1
fi

# ============================================================================
# VERIFICATION
# ============================================================================
echo ""
echo "  Verifying https://$HELP_PUBLIC_HOST/ (locally) ..."
CODE="$(curl -s -o /dev/null -w '%{http_code}' --resolve "$HELP_PUBLIC_HOST:443:127.0.0.1" "https://$HELP_PUBLIC_HOST/" 2>/dev/null || echo 000)"
case "$CODE" in
    2*|3*) log_done "Help site responds (HTTP $CODE)" ;;
    *)     log_warn "Help site returned HTTP $CODE (DNS may still be propagating; re-check the public URL shortly)" ;;
esac

# ============================================================================
# SUMMARY
# ============================================================================
echo ""
echo "==================================================================="
echo "  PHASE HELP COMPLETE  ->  https://$HELP_PUBLIC_HOST/"
echo "==================================================================="
for line in "${REPORT[@]}"; do echo "  $line"; done
echo ""
exit 0
