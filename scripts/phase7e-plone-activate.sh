#!/bin/bash
#
# phase7e-plone-activate.sh - Phase 7e: Activate the Docent add-ons in the site
#
# Prerequisites: phases 7a/7b/7c/7d have run (Plone installed, the Plone Site
# object exists at /Plone, and the add-on eggs are built into the instance by
# phase 7d). DOMAIN must be set in tenant.local.
#
# What this phase does:
#   1. Verify the prior phases left the instance + the Plone site in place.
#   2. Stop the Plone systemd unit (bin/instance run needs the ZODB file lock).
#   3. bin/instance run a Python script that, as the Zope admin, installs each
#      add-on's GenericSetup profile via the quickinstaller - IN DEPENDENCY
#      ORDER. collective.collectionfilter and medialog.notifications are
#      installed BEFORE the themes, because the themes ship a collectionfilter
#      portlet that groups by 'notification_type' - a group-by criterion that
#      only exists once medialog.notifications is installed. Installing a theme
#      first raises:
#        zope.schema ConstraintNotSatisfied: ('notification_type', 'group_by')
#      Ordering here is the whole point of this phase.
#   4. Optionally activate the Diazo theme (default: meadows).
#   5. Restart the systemd unit and wait for Plone to come back up.
#
# Design:
#   - The activation ORDER is an explicit list below (ACTIVATION_ORDER), not
#     derived from products.cfg eggs - order matters and some eggs (python-docx,
#     Plone core) are not activatable add-ons.
#   - Idempotent: each add-on is skipped if already installed. Safe to re-run,
#     and a no-op on sites where everything is already active.
#   - Fail-soft per add-on: a failing profile is logged and the rest continue;
#     the phase still exits non-zero so run-phases.sh flags it.
#
# Idempotent. Safe to re-run.
#
# Run as root via run-phases.sh, or directly: sudo bash phase7e-plone-activate.sh
#

set -u

# ============================================================================
# CONFIGURATION
# ============================================================================
PLONE_USER="plone"
PLONE_HOME="/home/plone"
PLONE_INSTANCE_DIR=""   # set after tenant.local is sourced (see below)

# Site ID inside the Zope instance (Plone's default; matches phase 7c).
PLONE_SITE_ID="Plone"

# Zope loopback port (must match phase 7b/7c/7d).
ZOPE_LOOPBACK_PORT=8080

# Add-on activation order. Dependencies FIRST, themes LAST. This is the single
# source of truth for what gets activated and in what order.
ACTIVATION_ORDER=(
    collective.collectionfilter
    medialog.notifications
    collective.sidebar
    DocentIMS.ActionItems
    onlyoffice.plone
    medialog.docxtransform
    plone.app.changeownership
    medialog.docenttheme
    medialog.meadows
)

# Diazo theme to make active at the end. Override with PLONE_THEME in
# tenant.local if the theme's registered name differs. If the name is not
# found, the script lists the available theme names and continues (warning,
# not a failure) so you can set PLONE_THEME correctly.
PLONE_THEME="${PLONE_THEME:-meadows}"

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

# Re-apply PLONE_THEME default in case tenant.local set it.
PLONE_THEME="${PLONE_THEME:-meadows}"

if [ -z "${DOMAIN:-}" ]; then
    echo "FATAL: DOMAIN is not set. tenant.local must define it before phase 7e runs."
    exit 1
fi
PLONE_SITE_NAME="${PLONE_SITE_NAME:-$(echo "$DOMAIN" | cut -d. -f1)}"
PLONE_INSTANCE_DIR="${PLONE_HOME}/${PLONE_SITE_NAME}"
PLONE_SYSTEMD_UNIT="plone-${PLONE_SITE_NAME}"

BIN_INSTANCE="${PLONE_INSTANCE_DIR}/bin/instance"
ACTIVATE_SCRIPT="/tmp/phase7e-activate.py"

# ============================================================================
# REPORT TRACKING + HELPERS
# ============================================================================
REPORT=()

log_done()    { REPORT+=("[DONE]    $1"); echo "  ✓ $1"; }
log_skip()    { REPORT+=("[SKIPPED] $1 (already done)"); echo "  - $1 (already done)"; }
log_warn()    { REPORT+=("[WARN]    $1"); echo "  ! $1"; }
log_fail()    { REPORT+=("[FAIL]    $1"); echo "  ✗ $1"; }

step() { echo ""; echo "=== $1 ==="; }

# Bring the service back up. Used on every exit path after we stop it.
start_service() {
    systemctl start "$PLONE_SYSTEMD_UNIT" 2>/dev/null || true
}

# ============================================================================
# Must run as root
# ============================================================================
if [ "$EUID" -ne 0 ]; then
    echo "This phase must run as root. Try: sudo bash $0"
    exit 1
fi

echo ""
echo "==================================================================="
echo "  PHASE 7E: Activate the Docent add-ons in the Plone site"
echo "==================================================================="
echo "  Instance dir:   $PLONE_INSTANCE_DIR"
echo "  Plone site:     /$PLONE_SITE_ID"
echo "  Systemd unit:   $PLONE_SYSTEMD_UNIT.service"
echo "  Theme:          $PLONE_THEME"
echo "  Add-ons:        ${#ACTIVATION_ORDER[@]} (in dependency order)"
echo ""

# ============================================================================
# STEP 1: Verify prerequisites from phases 7a-7d
# ============================================================================
step "Step 1: Verifying prerequisites from phases 7a-7d"

if ! id "$PLONE_USER" >/dev/null 2>&1; then
    log_fail "User '$PLONE_USER' does not exist. Did phase 7a run?"
    exit 1
fi
log_done "User '$PLONE_USER' exists"

if [ ! -x "$BIN_INSTANCE" ]; then
    log_fail "$BIN_INSTANCE not found. Did phase 7b/7d run?"
    exit 1
fi
log_done "bin/instance exists"

if ! systemctl cat "${PLONE_SYSTEMD_UNIT}.service" >/dev/null 2>&1; then
    log_fail "systemd unit ${PLONE_SYSTEMD_UNIT}.service not found. Did phase 7c run?"
    exit 1
fi
log_done "systemd unit ${PLONE_SYSTEMD_UNIT}.service exists"

# ============================================================================
# STEP 2: Write the activation script
# ============================================================================
step "Step 2: Writing the add-on activation script"

# Quoted heredoc (no bash interpolation). Values are passed via env vars that
# the Python reads with os.environ - same pattern as phase 7c.
cat > "$ACTIVATE_SCRIPT" <<'PYEOF'
# phase7e-marker - generated by phase7e-plone-activate.sh
#
# Run via: bin/instance run /tmp/phase7e-activate.py
# Receives `app` (the Zope root) from bin/instance.
#
# Reads env vars (set by the bash caller, NOT interpolated by the heredoc):
#   PHASE7E_SITE_ID   - e.g. "Plone"
#   PHASE7E_PRODUCTS  - space-separated add-on names, in install order
#   PHASE7E_THEME     - Diazo theme name to activate (may be empty)
#
import os
import sys
import transaction
from AccessControl.SecurityManagement import newSecurityManager
from zope.component.hooks import setSite

SITE_ID = os.environ["PHASE7E_SITE_ID"]
PRODUCTS = os.environ.get("PHASE7E_PRODUCTS", "").split()
THEME = os.environ.get("PHASE7E_THEME", "").strip()

# `app` is provided by bin/instance run.
if SITE_ID not in app.objectIds():
    print("ERROR: Plone site '/%s' not found. Run phase 7c first." % SITE_ID)
    sys.exit(1)
site = app[SITE_ID]

zope_admin = app.acl_users.getUserById("admin")
if zope_admin is None:
    print("ERROR: Zope-root 'admin' user not found in app.acl_users.")
    sys.exit(1)
newSecurityManager(None, zope_admin.__of__(app.acl_users))
setSite(site)

from Products.CMFPlone.utils import get_installer

qi = get_installer(site, getattr(site, "REQUEST", None))

failed = []
for name in PRODUCTS:
    try:
        if not qi.is_product_installable(name):
            print("SKIP  %s (no install profile / not installable)" % name)
            continue
        if qi.is_product_installed(name):
            print("OK    %s (already installed)" % name)
            continue
        qi.install_product(name)
        transaction.commit()
        print("DONE  %s installed" % name)
    except Exception as exc:
        transaction.abort()
        print("FAIL  %s -> %s" % (name, exc))
        failed.append(name)

# Activate the Diazo theme (best-effort; a missing theme name is a warning,
# not a failure, because the registered name can differ from the egg name).
if THEME:
    try:
        from plone.app.theming.utils import applyTheme, getAvailableThemes
        themes = list(getAvailableThemes())
        match = None
        for t in themes:
            if getattr(t, "name", None) == THEME:
                match = t
                break
        if match is not None:
            applyTheme(match)
            transaction.commit()
            print("THEME %s activated" % THEME)
        else:
            names = ", ".join(getattr(t, "name", "?") for t in themes)
            print("WARN  theme '%s' not found. Available themes: %s" % (THEME, names))
            print("WARN  set PLONE_THEME to one of the above and re-run phase 7e.")
    except Exception as exc:
        transaction.abort()
        print("WARN  theme activation error: %s" % exc)

if failed:
    print("")
    print("ACTIVATION FINISHED WITH FAILURES: %s" % ", ".join(failed))
    sys.exit(1)
print("")
print("ALL ADD-ONS ACTIVATED")
sys.exit(0)
PYEOF
chown "$PLONE_USER:$PLONE_USER" "$ACTIVATE_SCRIPT"
chmod 600 "$ACTIVATE_SCRIPT"

if [ ! -s "$ACTIVATE_SCRIPT" ]; then
    log_fail "Heredoc wrote zero bytes to $ACTIVATE_SCRIPT"
    exit 1
fi
log_done "Wrote $ACTIVATE_SCRIPT"

# ============================================================================
# STEP 3: Stop the service, run activation, restart
# ============================================================================
step "Step 3: Activating add-ons (Plone is briefly stopped for the ZODB lock)"

# bin/instance run grabs the ZODB file lock, so the service must be stopped.
log_done "Stopping $PLONE_SYSTEMD_UNIT to free the ZODB lock"
systemctl stop "$PLONE_SYSTEMD_UNIT"
sleep 3

# Space-join the ordered list for the env var.
PRODUCTS_STR="${ACTIVATION_ORDER[*]}"

set +e
sudo -u "$PLONE_USER" \
    PHASE7E_SITE_ID="$PLONE_SITE_ID" \
    PHASE7E_PRODUCTS="$PRODUCTS_STR" \
    PHASE7E_THEME="$PLONE_THEME" \
    bash -c "cd '$PLONE_INSTANCE_DIR' && bin/instance run '$ACTIVATE_SCRIPT'"
RUN_RC=$?
set -e

if [ "$RUN_RC" -ne 0 ]; then
    log_fail "Activation reported failures (exit $RUN_RC). See the output above."
    log_fail "Products that installed are committed; fix the failing one and re-run 7e."
else
    log_done "All add-ons activated in dependency order"
fi

# ============================================================================
# STEP 4: Restart Plone and wait for it to come back up
# ============================================================================
step "Step 4: Restarting Plone via systemd"

start_service
log_done "Issued systemctl start $PLONE_SYSTEMD_UNIT"

echo "  Waiting for Plone to accept connections on 127.0.0.1:$ZOPE_LOOPBACK_PORT..."
WAIT=0
while [ "$WAIT" -lt 90 ]; do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$ZOPE_LOOPBACK_PORT/$PLONE_SITE_ID/" 2>/dev/null || true)"
    case "$code" in
        2*|3*) break ;;
    esac
    sleep 2
    WAIT=$((WAIT + 2))
done
if [ "$WAIT" -ge 90 ]; then
    log_fail "Plone did not respond at /$PLONE_SITE_ID after 90s."
    log_fail "Check: journalctl -u $PLONE_SYSTEMD_UNIT -n 80"
fi
[ "$WAIT" -lt 90 ] && log_done "Plone is responding at /$PLONE_SITE_ID (took ${WAIT}s)"

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

if systemctl is-active --quiet "$PLONE_SYSTEMD_UNIT"; then
    vp "systemd unit $PLONE_SYSTEMD_UNIT is active"
else
    vf "systemd unit $PLONE_SYSTEMD_UNIT is NOT active"
fi

SITE_CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$ZOPE_LOOPBACK_PORT/$PLONE_SITE_ID/" 2>/dev/null || echo 000)"
case "$SITE_CODE" in
    2*|3*) vp "Plone site /$PLONE_SITE_ID responds (HTTP $SITE_CODE)" ;;
    *)     vf "Plone site /$PLONE_SITE_ID does NOT respond (HTTP $SITE_CODE)" ;;
esac

if [ "$RUN_RC" -eq 0 ]; then
    vp "Add-on activation completed without failures"
else
    vf "Add-on activation reported failures (see Step 3 output)"
fi

echo ""
echo "  Verification: $VERIFY_PASSED passed, $VERIFY_FAILED failed"

# ============================================================================
# SUMMARY REPORT
# ============================================================================
echo ""
echo "==================================================================="
echo "  PHASE 7E COMPLETE - SUMMARY REPORT"
echo "==================================================================="
echo ""
for line in "${REPORT[@]}"; do
    echo "  $line"
done
echo ""

if [ "$VERIFY_FAILED" -gt 0 ] || [ "$RUN_RC" -ne 0 ]; then
    echo "  *** Review the failures above. ***"
    echo ""
    exit 1
fi
exit 0
