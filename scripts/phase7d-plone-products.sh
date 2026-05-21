#!/usr/bin/env bash
# ============================================================================
# phase7d-plone-products.sh - Phase 7d: Install Docent products into Plone
# ============================================================================
# What this phase does:
#   1. Verify phases 7a/7b/7c ran (plone user, bin/instance, systemd unit)
#   2. Copy the overlay buildout (products.cfg) into the Plone instance dir
#   3. As the plone user: run 'bin/buildout -c products.cfg' - this pulls the
#      Docent product source from git (mr.developer) and adds the products to
#      the instance egg set. bin/instance is regenerated IN PLACE - same path
#      - so the phase 7c systemd unit keeps working unchanged.
#   4. Restart the Plone systemd unit and wait for it to come back up.
#   5. Verify each product egg is importable by the running instance.
#
# What this phase does NOT do:
#   - It does NOT install Plone (phase 7b does that).
#   - It does NOT ACTIVATE the add-ons inside the Plone site. After this phase,
#     the products are AVAILABLE (importable, listed in the Add-ons control
#     panel) but not installed into the site. Activation is a manual step -
#     see MANUAL NEXT STEPS at the end.
#
# Prerequisites:
#   - Phase 7a ran (plone user + OS deps)
#   - Phase 7b ran (Plone buildout, venv, bin/instance, bin/buildout exist)
#   - Phase 7c ran (systemd unit running, site reachable)
#
# End state:
#   - The Docent products are built into the instance and importable.
#   - Plone is running again as the same systemd service.
#
# Idempotent. Safe to re-run. Re-running re-runs buildout, which is itself
# idempotent (it will no-op if nothing changed in products.cfg or the sources).
#
# Run as root via run-phases.sh, or directly: sudo bash phase7d-plone-products.sh
# ============================================================================
set -u

# ============================================================================
# CONFIGURATION
# ============================================================================
PLONE_USER="plone"
PLONE_HOME="/home/plone"
PLONE_INSTANCE_DIR=""  # Set after tenant.local is sourced (see below)

# The Docent product egg names that should be importable after this phase.
# Keep in sync with products.cfg [instance] eggs +=.
DOCENT_PRODUCTS=(
    "medialog.notifications"
    "medialog.meadows"
    "medialog.docxtransform"
    "medialog.docenttheme"
    "DocentIMS.ActionItems"
    "collective.sidebar"
    "collective.collectionfilter"
    "collective.fullcalendar"
)

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
SCRIPT_DIR="$__PHASE_SCRIPT_DIR"
unset __PHASE_SCRIPT_DIR __PHASE_REPO_ROOT
# === END tenant.local/secrets.local source block ===

# Compute Plone path values now that tenant.local has been sourced.
if [ -z "${DOMAIN:-}" ]; then
    echo "FATAL: DOMAIN is not set. tenant.local must define it before phase 7d runs."
    exit 1
fi

PLONE_SITE_NAME="${PLONE_SITE_NAME:-$(echo "$DOMAIN" | cut -d. -f1)}"
PLONE_INSTANCE_DIR="${PLONE_HOME}/${PLONE_SITE_NAME}"

# systemd unit name (must match what phase 7c created)
PLONE_SYSTEMD_UNIT="plone-${PLONE_SITE_NAME}"

# Zope loopback port (must match phase 7b/7c)
ZOPE_LOOPBACK_PORT=8080

# Overlay buildout: source (in repo) and destination (in instance dir)
PRODUCTS_CFG_SRC="${SCRIPT_DIR}/assets/products.cfg"
PRODUCTS_CFG_DST="${PLONE_INSTANCE_DIR}/products.cfg"

# Phase 7b's buildout, which products.cfg extends
BUILDOUT_CFG="${PLONE_INSTANCE_DIR}/buildout.cfg"
BIN_BUILDOUT="${PLONE_INSTANCE_DIR}/bin/buildout"
BIN_INSTANCE="${PLONE_INSTANCE_DIR}/bin/instance"

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
echo "  PHASE 7D: Install Docent products into Plone"
echo "==================================================================="
echo "  Instance dir:   $PLONE_INSTANCE_DIR"
echo "  Overlay config: $PRODUCTS_CFG_DST"
echo "  Systemd unit:   $PLONE_SYSTEMD_UNIT.service"
echo "  Products:       ${#DOCENT_PRODUCTS[@]} packages"
echo ""

# ============================================================================
# STEP 1: Verify prerequisites from phases 7a/7b/7c
# ============================================================================
step "Step 1: Verifying prerequisites from phases 7a/7b/7c"

# plone user exists (phase 7a)
if ! id "$PLONE_USER" >/dev/null 2>&1; then
    log_fail "User '$PLONE_USER' does not exist. Did phase 7a run?"
    exit 1
fi
log_done "User '$PLONE_USER' exists"

# instance dir exists
if [ ! -d "$PLONE_INSTANCE_DIR" ]; then
    log_fail "Instance dir $PLONE_INSTANCE_DIR does not exist. Did phase 7b run?"
    exit 1
fi
log_done "Instance dir exists"

# phase 7b's buildout.cfg exists (products.cfg extends it)
if [ ! -f "$BUILDOUT_CFG" ]; then
    log_fail "$BUILDOUT_CFG not found. Did phase 7b run?"
    exit 1
fi
log_done "Phase 7b's buildout.cfg exists"

# bin/buildout exists (phase 7b bootstrapped it)
if [ ! -x "$BIN_BUILDOUT" ]; then
    log_fail "$BIN_BUILDOUT not found or not executable. Did phase 7b run?"
    exit 1
fi
log_done "bin/buildout exists"

# bin/instance exists (phase 7b built it)
if [ ! -x "$BIN_INSTANCE" ]; then
    log_fail "$BIN_INSTANCE not found. Did phase 7b run?"
    exit 1
fi
log_done "bin/instance exists"

# systemd unit exists (phase 7c created it)
if ! systemctl list-unit-files "${PLONE_SYSTEMD_UNIT}.service" >/dev/null 2>&1 \
     || ! systemctl cat "${PLONE_SYSTEMD_UNIT}.service" >/dev/null 2>&1; then
    log_fail "systemd unit ${PLONE_SYSTEMD_UNIT}.service not found. Did phase 7c run?"
    exit 1
fi
log_done "systemd unit ${PLONE_SYSTEMD_UNIT}.service exists"

# overlay buildout exists in the repo
if [ ! -f "$PRODUCTS_CFG_SRC" ]; then
    log_fail "Overlay buildout not found at $PRODUCTS_CFG_SRC"
    log_fail "It should be committed to the repo at scripts/assets/products.cfg"
    exit 1
fi
log_done "Overlay buildout products.cfg found in repo"

# ============================================================================
# STEP 2: Install the overlay buildout into the instance dir
# ============================================================================
step "Step 2: Installing products.cfg into the instance directory"

# Copy products.cfg into the instance dir. We copy every run (not skip-if-exists)
# so an updated products.cfg in the repo always takes effect on re-run.
cp "$PRODUCTS_CFG_SRC" "$PRODUCTS_CFG_DST"
chown "${PLONE_USER}:${PLONE_USER}" "$PRODUCTS_CFG_DST"
chmod 644 "$PRODUCTS_CFG_DST"

# Zero-byte guard - make sure the copy actually wrote content.
if [ ! -s "$PRODUCTS_CFG_DST" ]; then
    log_fail "products.cfg was copied but is empty (zero bytes)"
    exit 1
fi
log_done "products.cfg installed at $PRODUCTS_CFG_DST (owner $PLONE_USER, mode 644)"

# ============================================================================
# STEP 3: Run the overlay buildout as the plone user
# ============================================================================
step "Step 3: Running overlay buildout (this takes several minutes)"

echo ""
echo "  -----------------------------------------------------------------"
echo "  IMPORTANT: buildout is about to pull ${#DOCENT_PRODUCTS[@]} packages from git and"
echo "  compile them. This typically takes 3-8 minutes and prints a lot"
echo "  of output. DO NOT press Ctrl-C - let it finish. An interrupted"
echo "  buildout can leave the instance in a half-built state."
echo "  -----------------------------------------------------------------"
echo ""

# Run buildout against the overlay config, as the plone user, from inside the
# instance dir. bin/instance is regenerated in place by this run.
if ! sudo -u "$PLONE_USER" bash -c "cd '$PLONE_INSTANCE_DIR' && bin/buildout -c products.cfg"; then
    log_fail "Overlay buildout (bin/buildout -c products.cfg) failed."
    log_fail "Review the buildout output above. Common causes: a product's"
    log_fail "dependency version conflicts with the Plone 6.2.0 pin set, or a"
    log_fail "git source URL is unreachable."
    log_fail "Plone itself (from phase 7b) is unaffected - you can re-run 7d"
    log_fail "after fixing the issue."
    exit 1
fi
log_done "Overlay buildout completed - Docent products built into the instance"

# Sanity: bin/instance still exists and is executable after the rebuild
if [ ! -x "$BIN_INSTANCE" ]; then
    log_fail "bin/instance is missing after buildout. The systemd unit will fail."
    exit 1
fi
log_done "bin/instance still present after buildout (systemd unit path intact)"

# ============================================================================
# STEP 4: Restart Plone and wait for it to come back up
# ============================================================================
step "Step 4: Restarting Plone via systemd"

systemctl restart "$PLONE_SYSTEMD_UNIT"
log_done "Issued systemctl restart $PLONE_SYSTEMD_UNIT"

echo "  Waiting for Plone to accept connections on 127.0.0.1:$ZOPE_LOOPBACK_PORT..."
WAIT=0
while [ "$WAIT" -lt 90 ]; do
    if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$ZOPE_LOOPBACK_PORT/" 2>/dev/null | grep -qE "^[2-4]"; then
        break
    fi
    sleep 2
    WAIT=$((WAIT + 2))
done
if [ "$WAIT" -ge 90 ]; then
    log_fail "Plone did not come back up on 127.0.0.1:$ZOPE_LOOPBACK_PORT after 90s"
    log_fail "A product may be failing at Zope startup. Check:"
    log_fail "  journalctl -u $PLONE_SYSTEMD_UNIT -n 80"
    exit 1
fi
log_done "Plone is responding on 127.0.0.1:$ZOPE_LOOPBACK_PORT again (took ${WAIT}s)"

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

# products.cfg is in place
if [ -s "$PRODUCTS_CFG_DST" ]; then
    vp "products.cfg present in instance dir"
else
    vf "products.cfg missing from instance dir"
fi

# systemd unit is active
if systemctl is-active --quiet "$PLONE_SYSTEMD_UNIT"; then
    vp "systemd unit $PLONE_SYSTEMD_UNIT is active"
else
    vf "systemd unit $PLONE_SYSTEMD_UNIT is NOT active"
fi

# Each product egg must be importable by the instance's Python.
# We use 'bin/zopepy' (built by phase 7b's [zopepy] part) which has the full
# egg path. Import name != egg name for namespaced packages, so we map them.
ZOPEPY="${PLONE_INSTANCE_DIR}/bin/zopepy"
if [ ! -x "$ZOPEPY" ]; then
    vf "bin/zopepy not found - cannot verify product imports"
else
    # Map egg name -> python import name
    declare -A IMPORT_NAME=(
        ["medialog.notifications"]="medialog.notifications"
        ["medialog.meadows"]="medialog.meadows"
        ["medialog.docxtransform"]="medialog.docxtransform"
        ["medialog.docenttheme"]="medialog.docenttheme"
        ["DocentIMS.ActionItems"]="DocentIMS.ActionItems"
        ["collective.sidebar"]="collective.sidebar"
        ["collective.collectionfilter"]="collective.collectionfilter"
        ["collective.fullcalendar"]="collective.fullcalendar"
    )
    for prod in "${DOCENT_PRODUCTS[@]}"; do
        imp="${IMPORT_NAME[$prod]}"
        if sudo -u "$PLONE_USER" bash -c "cd '$PLONE_INSTANCE_DIR' && bin/zopepy -c 'import ${imp}'" >/dev/null 2>&1; then
            vp "Product importable: $prod"
        else
            vf "Product NOT importable: $prod"
        fi
    done
fi

echo ""
echo "  Verification: $VERIFY_PASSED passed, $VERIFY_FAILED failed"
echo ""

if [ "$VERIFY_FAILED" -gt 0 ]; then
    echo "  *** $VERIFY_FAILED CHECK(S) FAILED. Review failures above before proceeding. ***"
fi

# ============================================================================
# SUMMARY REPORT
# ============================================================================
echo ""
echo "==================================================================="
echo "  PHASE 7D COMPLETE - SUMMARY REPORT"
echo "==================================================================="
echo ""
for line in "${REPORT[@]}"; do
    echo "  $line"
done
echo ""

# ============================================================================
# MANUAL NEXT STEPS
# ============================================================================
echo ""
echo "==================================================================="
echo "  MANUAL NEXT STEPS"
echo "==================================================================="
echo ""
echo "  The Docent products are now BUILT INTO the Plone instance and"
echo "  importable. They are NOT yet activated inside the Plone site."
echo ""
echo "  To activate an add-on:"
echo "    1. Log in at https://team.$DOMAIN/login as admin"
echo "       (password in $REPO_ROOT/CREDENTIALS.txt - PLONE_ADMIN_PW)"
echo "    2. Go to: Site Setup -> Add-ons"
echo "    3. Click 'Install' next to each Docent add-on you want active."
echo ""
echo "  Useful commands:"
echo "    sudo systemctl status  $PLONE_SYSTEMD_UNIT"
echo "    sudo systemctl restart $PLONE_SYSTEMD_UNIT"
echo "    sudo journalctl -u $PLONE_SYSTEMD_UNIT -f"
echo ""
echo "  To refresh products after editing products.cfg, just re-run phase 7d."
echo ""
echo "==================================================================="
echo ""

# Exit non-zero if any verification check failed, so run-phases.sh notices.
if [ "$VERIFY_FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
