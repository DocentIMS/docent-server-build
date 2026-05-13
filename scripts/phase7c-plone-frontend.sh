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
#   7. Create the Plone Site object at /Plone (distribution='classic', NOT
#      Volto - critical to avoid the 'no Add menu, no content types' bug)
#      and create the Plone-level 'admin' user with PLONE_ADMIN_PW.
#
# Prerequisites:
#   - Phases 0-2 ran (Apache + Let's Encrypt + ufw)
#   - Phase 7a ran (plone user + OS deps)
#   - Phase 7b ran (Plone buildout, bin/instance exists)
#   - Wildcard DNS *.<domain> resolves to this server's public IP
#
# End state:
#   - Plone running as a systemd service, bound to 127.0.0.1:8080 only
#   - https://team.<DOMAIN>/ serves the Plone site (NO manual setup step
#     remaining - just log in at /login)
#   - WordPress at https://<DOMAIN>/ is untouched
#   - Roundcube at https://<DOMAIN>/mail/ is untouched
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
if [ -z "${DOMAIN:-}" ]; then
    echo "FATAL: DOMAIN is not set. tenant.local must define it before phase 7c runs."
    exit 1
fi
if [ -z "${NOTIFICATION_EMAIL:-}" ]; then
    echo "FATAL: NOTIFICATION_EMAIL is not set. Needed for certbot."
    exit 1
fi

PLONE_SITE_NAME="${PLONE_SITE_NAME:-$(echo "$DOMAIN" | cut -d. -f1)}"
PLONE_INSTANCE_DIR="${PLONE_HOME}/${PLONE_SITE_NAME}"

# Subdomain Plone is published at
PLONE_PUBLIC_HOST="team.${DOMAIN}"

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
# STEP 5: Obtain Let's Encrypt cert for team.<DOMAIN>
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
    #
    # DEFAULT_SITE_DIR comes from tenant.local (written by phase 0; phase 2
    # owns the actual directory). Fallback to the literal path for older
    # tenant.local files that predate this variable.
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
# STEP 6: Install Apache vhost for team.<DOMAIN>
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
# STEP 8: Create the Plone Site object + Plone-level admin user
# ============================================================================
# This is the step that used to be a manual browser click ("Create Classic UI
# Plone Site"). Doing it via the browser has a footgun: the welcome page
# defaults to the Volto distribution, which creates a site with no Classic UI
# content types - no Folder, no Page, no News Item, etc. - and no Add menu.
# We force distribution='classic' here, which installs the full content-type
# set and a working Add menu.
#
# We also create the Plone-level 'admin' user (using PLONE_ADMIN_PW). Note this
# is a DIFFERENT account from the Zope-root 'admin' user created by buildout
# (which has the same password but lives in a different user folder). The
# Zope-root admin authenticates at /manage (the ZMI). The Plone-level admin
# authenticates at /login (Plone's own login form). Phase 7c step 4 already
# configured the Zope-root admin via the buildout 'user = admin:...' line.
# This step covers the Plone-level admin needed for /login.
# ============================================================================
step "Step 8: Creating Plone Site (distribution=classic) and admin user"

PLONE_SITE_TITLE="Docent"
CREATE_SCRIPT="/tmp/phase7c-create-site.py"

# Check if the site already exists. We always run the create script (it's
# idempotent and detects broken sites that need recreation), but we log
# what we're starting from so the script output is readable.
SITE_CHECK_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    "http://127.0.0.1:$ZOPE_LOOPBACK_PORT/$PLONE_SITE_ID/" 2>/dev/null || echo "000")

if echo "$SITE_CHECK_CODE" | grep -qE "^(200|302)$"; then
    log_done "Site at /$PLONE_SITE_ID currently responds HTTP $SITE_CHECK_CODE"
    log_done "The create script will detect if it's healthy and recreate if not"
else
    log_done "No site at /$PLONE_SITE_ID yet (HTTP $SITE_CHECK_CODE); will create one"
fi
SITE_NEEDS_CREATE=true

# Read PLONE_ADMIN_PW from CREDENTIALS.txt (phase 7b wrote it there)
CREDENTIALS_FILE="$REPO_ROOT/CREDENTIALS.txt"
if [ ! -f "$CREDENTIALS_FILE" ]; then
    log_fail "$CREDENTIALS_FILE not found. Phase 7b should have created it."
    exit 1
fi
PLONE_ADMIN_PW=$(grep "^PLONE_ADMIN_PW=" "$CREDENTIALS_FILE" | head -1 | cut -d= -f2-)
if [ -z "$PLONE_ADMIN_PW" ]; then
    log_fail "PLONE_ADMIN_PW not found in $CREDENTIALS_FILE. Phase 7b should have written it."
    exit 1
fi

if [ "$SITE_NEEDS_CREATE" = "true" ]; then
    # bin/instance run grabs the ZODB file lock, so we must stop the service
    # for the duration. Same pattern as zconsole.
    log_done "Stopping $PLONE_SYSTEMD_UNIT to free the ZODB lock"
    systemctl stop "$PLONE_SYSTEMD_UNIT"
    # Give it a moment to release the lock file
    sleep 3

    # Write the creation script. Use a heredoc with NO bash variable expansion
    # (quoted 'EOF') to avoid the set-u/$variable bug that bit phase 5. We pass
    # the few values we need (site id, title, password) via environment vars
    # that the Python script reads with os.environ.
    cat > "$CREATE_SCRIPT" <<'PYEOF'
# phase7c-marker - generated by phase7c-plone-frontend.sh
#
# Run via: bin/instance run /tmp/phase7c-create-site.py
# Receives `app` (the Zope root) and `globals()` from bin/instance.
#
# Reads three env vars (set by the bash caller, NOT interpolated by heredoc):
#   PHASE7C_SITE_ID    - e.g. "Plone"
#   PHASE7C_SITE_TITLE - e.g. "Docent"
#   PHASE7C_ADMIN_PW   - the Plone-level admin password
#
# CRITICAL: the keyword argument is `distribution_name`, NOT `distribution`.
# Reading the Products.CMFPlone.factory.addPloneSite source in plone 6.2:
#   def addPloneSite(context, site_id, ..., distribution_name=None, **kwargs):
#       if distribution_name:
#           # routes through plone.distribution.api.site._create_site
#           # which installs the full classic profile chain
#       ...
# If you pass distribution= (no _name), it goes into **kwargs and is silently
# ignored. The site is then created via the legacy bare-Plone path with only
# Products.CMFPlone:plone applied -> no Folder, no Page, no Add menu. Don't
# repeat that mistake.
#
import os
import sys
import transaction
from Products.CMFPlone.factory import addPloneSite

SITE_ID = os.environ["PHASE7C_SITE_ID"]
SITE_TITLE = os.environ["PHASE7C_SITE_TITLE"]
ADMIN_PW = os.environ["PHASE7C_ADMIN_PW"]


def site_is_healthy(site):
    """Return True if the site has the Classic UI content types installed.

    A site created via the wrong distribution path will have only TempFolder
    and Plone Site in portal_types; a healthy classic site has Folder,
    Document, News Item, Event, File, Image, Link, and Collection at minimum.
    Folder alone is a sufficient signal.
    """
    try:
        pt = site.portal_types
        return "Folder" in pt.objectIds()
    except Exception as exc:
        print("WARN: could not inspect portal_types: %s" % exc)
        return False


# `app` is provided by bin/instance run
if SITE_ID in app.objectIds():
    existing = app[SITE_ID]
    if site_is_healthy(existing):
        print("Site '/%s' already exists and is healthy; skipping creation" % SITE_ID)
        site = existing
    else:
        print("Site '/%s' exists but is missing Classic UI content types (broken)." % SITE_ID)
        print("Deleting and recreating with distribution_name='classic'.")
        app.manage_delObjects([SITE_ID])
        transaction.commit()
        # Fall through to creation
        addPloneSite(
            app,
            SITE_ID,
            title=SITE_TITLE,
            distribution_name="classic",
        )
        transaction.commit()
        print("Recreated Plone Site /%s with distribution_name='classic'" % SITE_ID)
        site = app[SITE_ID]
else:
    print("Creating Plone Site /%s with title '%s', distribution_name='classic'" % (SITE_ID, SITE_TITLE))
    addPloneSite(
        app,
        SITE_ID,
        title=SITE_TITLE,
        distribution_name="classic",
    )
    transaction.commit()
    print("Created Plone Site /%s" % SITE_ID)
    site = app[SITE_ID]

# Verify the site is now healthy before continuing.
if not site_is_healthy(site):
    print("ERROR: site '/%s' was created/recreated but Folder is still not a" % SITE_ID)
    print("       registered content type. Something went wrong with the classic")
    print("       distribution profile chain. Inspect manually:")
    print("         bin/instance run -c 'app.%s.portal_types.objectIds()'" % SITE_ID)
    sys.exit(2)
print("Site healthy: Folder is registered.")

# Now create the Plone-level admin user inside the site.
# This is separate from the Zope-root admin (handled by buildout's user= line).
from AccessControl.SecurityManagement import newSecurityManager
from zope.component.hooks import setSite

zope_admin = app.acl_users.getUserById("admin")
if zope_admin is None:
    print("ERROR: Zope-root 'admin' user not found in app.acl_users.")
    print("       Buildout's 'user = admin:...' line should have created it.")
    sys.exit(1)

newSecurityManager(None, zope_admin.__of__(app.acl_users))
setSite(site)

from plone import api

if api.user.get(username="admin") is not None:
    print("Plone-level user 'admin' already exists; skipping user creation")
else:
    api.user.create(
        email="admin@example.invalid",
        username="admin",
        password=ADMIN_PW,
        roles=("Member", "Manager"),
    )
    transaction.commit()
    print("Created Plone-level user 'admin' with Manager role")

print("Step 8 script complete.")
PYEOF
    chown "$PLONE_USER:$PLONE_USER" "$CREATE_SCRIPT"
    chmod 600 "$CREATE_SCRIPT"

    if [ ! -s "$CREATE_SCRIPT" ]; then
        log_fail "Heredoc wrote zero bytes to $CREATE_SCRIPT"
        # Bring the service back up before we exit, so we don't leave a half-state
        systemctl start "$PLONE_SYSTEMD_UNIT" || true
        exit 1
    fi
    log_done "Wrote $CREATE_SCRIPT"

    # Run the script. Pass site id, title, and password as env vars (NOT
    # interpolated into the script body) to keep the password out of the
    # script file and avoid heredoc escaping headaches.
    if ! sudo -u "$PLONE_USER" \
            PHASE7C_SITE_ID="$PLONE_SITE_ID" \
            PHASE7C_SITE_TITLE="$PLONE_SITE_TITLE" \
            PHASE7C_ADMIN_PW="$PLONE_ADMIN_PW" \
            bash -c "cd '$PLONE_INSTANCE_DIR' && bin/instance run '$CREATE_SCRIPT'"; then
        log_fail "bin/instance run failed. The site may be in a partial state."
        log_fail "Check the output above for the Python traceback."
        # Bring the service back up before we exit
        systemctl start "$PLONE_SYSTEMD_UNIT" || true
        exit 1
    fi
    log_done "Plone Site /$PLONE_SITE_ID created with distribution='classic'"
    log_done "Plone-level 'admin' user created (password in CREDENTIALS.txt)"

    # Clean up the script file (it contained no secrets - password came from
    # env - but we don't need it sitting around in /tmp).
    rm -f "$CREATE_SCRIPT"

    # Restart the service and wait for it to come back up
    log_done "Restarting $PLONE_SYSTEMD_UNIT"
    systemctl start "$PLONE_SYSTEMD_UNIT"

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
        log_fail "Plone did not come back up on 127.0.0.1:$ZOPE_LOOPBACK_PORT after 60s"
        log_fail "Check: journalctl -u $PLONE_SYSTEMD_UNIT -n 50"
        exit 1
    fi
    log_done "Plone is responding on 127.0.0.1:$ZOPE_LOOPBACK_PORT again (took ${WAIT}s)"
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

# ----------------------------------------------------------------------------
# Step 8 verification: Plone Site object + content types
# ----------------------------------------------------------------------------

# /Plone exists and responds
SITE_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$ZOPE_LOOPBACK_PORT/$PLONE_SITE_ID/" 2>/dev/null || echo "000")
if echo "$SITE_CODE" | grep -qE "^(200|302)$"; then
    vp "Plone Site at /$PLONE_SITE_ID responds (HTTP $SITE_CODE)"
else
    vf "Plone Site at /$PLONE_SITE_ID does NOT respond (got: $SITE_CODE)"
fi

# Public URL serves the Plone site (not just the Zope welcome page).
# A working classic Plone site puts the string 'plone-toolbar' or similar
# Plone-specific markers in the HTML; the Zope welcome page does not.
# We use the body of the response rather than just status to catch the case
# where Apache routes correctly but Plone serves the wrong thing.
PUBLIC_BODY=$(curl -sk "https://$PLONE_PUBLIC_HOST/" --resolve "$PLONE_PUBLIC_HOST:443:127.0.0.1" 2>/dev/null || echo "")
if echo "$PUBLIC_BODY" | grep -qiE "(plone|barceloneta)"; then
    vp "https://$PLONE_PUBLIC_HOST/ serves a Plone site (body contains Plone markers)"
else
    vf "https://$PLONE_PUBLIC_HOST/ does NOT appear to serve a Plone site (no Plone markers in body)"
fi

# Content types: Folder must be addable in the Plone site root.
# We check this by running a tiny inspection script via bin/instance run -
# same pattern as Step 8. This DOES require stopping the service briefly,
# so we only run this check if the site exists in the first place.
#
# A passing check here is the difference between "Plone is up" and "Plone is
# usable" - i.e. it catches the Volto-vs-classic regression that caused the
# original 'no Add menu' bug.
if echo "$SITE_CODE" | grep -qE "^(200|302)$"; then
    INSPECT_SCRIPT="/tmp/phase7c-inspect-types.py"
    cat > "$INSPECT_SCRIPT" <<'PYEOF'
import os
import sys
SITE_ID = os.environ["PHASE7C_SITE_ID"]
if SITE_ID not in app.objectIds():
    print("FAIL: site /%s does not exist" % SITE_ID)
    sys.exit(2)
site = app[SITE_ID]
from zope.component.hooks import setSite
setSite(site)
# portal_types is the Plone tool that knows which types are registered.
# We check that 'Folder' is among them - that's the canonical "is this a
# classic Plone site or a Volto-stripped one" signal.
pt = site.portal_types
type_ids = list(pt.objectIds())
if "Folder" in type_ids:
    print("PASS: 'Folder' is a registered content type")
    sys.exit(0)
else:
    print("FAIL: 'Folder' is NOT a registered content type. Site may be Volto-default.")
    print("       Registered types: %s" % type_ids)
    sys.exit(2)
PYEOF
    chown "$PLONE_USER:$PLONE_USER" "$INSPECT_SCRIPT"
    chmod 600 "$INSPECT_SCRIPT"

    if [ ! -s "$INSPECT_SCRIPT" ]; then
        vf "Heredoc wrote zero bytes to $INSPECT_SCRIPT - cannot inspect content types"
    else
        # Stop the service briefly to free the ZODB lock for the inspection script
        systemctl stop "$PLONE_SYSTEMD_UNIT"
        sleep 3
        INSPECT_OUT=$(sudo -u "$PLONE_USER" \
            PHASE7C_SITE_ID="$PLONE_SITE_ID" \
            bash -c "cd '$PLONE_INSTANCE_DIR' && bin/instance run '$INSPECT_SCRIPT'" 2>&1)
        INSPECT_RC=$?
        systemctl start "$PLONE_SYSTEMD_UNIT"

        # Wait for service to come back
        WAIT=0
        while [ "$WAIT" -lt 60 ]; do
            if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$ZOPE_LOOPBACK_PORT/" 2>/dev/null | grep -qE "^[2-4]"; then
                break
            fi
            sleep 2
            WAIT=$((WAIT + 2))
        done

        if [ "$INSPECT_RC" -eq 0 ]; then
            vp "Content type 'Folder' is registered (site has Classic UI content types)"
        else
            vf "Content type 'Folder' is NOT registered. Site may be Volto-default. Output:"
            echo "$INSPECT_OUT" | sed 's/^/        /'
        fi
        rm -f "$INSPECT_SCRIPT"
    fi
else
    vf "Skipping content-type check because the Plone Site does not exist"
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
echo "  Plone is now publicly reachable AND the site exists at /$PLONE_SITE_ID."
echo "  The Plone Site was created with distribution='classic', so Folder,"
echo "  Page, News Item, and the rest of the Classic UI content types are"
echo "  installed and the Add menu is functional."
echo ""
echo "  To log in:"
echo "    1. Open: https://$PLONE_PUBLIC_HOST/login"
echo "    2. Username: admin"
echo "       Password: see $REPO_ROOT/CREDENTIALS.txt (PLONE_ADMIN_PW)"
echo ""
echo "  (The same password also works for /manage - the Zope Management"
echo "   Interface - via the Zope-root admin user, which is a different"
echo "   account in a different user folder, just sharing the password.)"
echo ""
echo "  WordPress at https://$DOMAIN/ is untouched."
echo "  Roundcube at https://$DOMAIN/mail/ is untouched."
echo ""
echo "  Useful commands going forward:"
echo "    sudo systemctl status  $PLONE_SYSTEMD_UNIT"
echo "    sudo systemctl restart $PLONE_SYSTEMD_UNIT"
echo "    sudo journalctl -u $PLONE_SYSTEMD_UNIT -f"
echo ""
echo "==================================================================="
echo ""
