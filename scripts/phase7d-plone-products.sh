#!/bin/bash
#
# phase7d-plone-products.sh - Phase 7d: Install Docent add-on products into Plone
#
# Prerequisites: phases 7a, 7b and 7c have run (plone user, bin/instance,
# bin/buildout and the systemd unit all exist; Plone is installed and running).
# DOMAIN must be set in tenant.local.
#
# What this phase does:
#   1. Verify phases 7a/7b/7c left the instance in the expected state.
#   2. Download the add-on overlay (products.cfg) from the docent-plone-addons
#      GitHub repo. That repo is the single source of truth for which add-ons
#      get installed. products.cfg is an OVERLAY: it extends phase 7b's
#      buildout.cfg and only ADDS products - it does not reinstall Plone or
#      change the Plone version or the admin password.
#   3. As the plone user: run 'bin/buildout -c products.cfg'. mr.developer
#      fetches the add-on sources; buildout adds them to the instance egg set.
#      bin/instance is regenerated IN PLACE (same path), so the phase 7c
#      systemd unit keeps working unchanged.
#   4. Restart the Plone systemd unit and wait for it to come back up.
#   5. Verify each add-on listed in products.cfg was built into the instance.
#
# What this phase does NOT do:
#   - It does NOT install Plone (phase 7b does that). The overlay leaves Plone,
#     its version and the admin password exactly as phase 7b set them.
#   - It does NOT ACTIVATE the add-ons inside the Plone site. After this phase
#     the add-ons are AVAILABLE (listed in Site Setup -> Add-ons) but not yet
#     installed into the site. Activation is a manual UI step - see MANUAL
#     NEXT STEPS at the end.
#
# Idempotent. Safe to re-run. Re-running re-downloads products.cfg and re-runs
# buildout (itself idempotent - a no-op if nothing has changed).
#
# Run as root via run-phases.sh, or directly: sudo bash phase7d-plone-products.sh
#

set -u

# ============================================================================
# CONFIGURATION
# ============================================================================
PLONE_USER="plone"
PLONE_HOME="/home/plone"
PLONE_INSTANCE_DIR=""   # set after tenant.local is sourced (see below)

# Where to fetch the add-on overlay from: the docent-plone-addons GitHub repo
# (public). Override PRODUCTS_CFG_URL in tenant.local to point at a different
# branch or fork (e.g. a 'staging' branch) without editing this script.
PRODUCTS_CFG_URL="${PRODUCTS_CFG_URL:-https://raw.githubusercontent.com/DocentIMS/docent-plone-addons/main/products.cfg}"

# Private add-on sources: any repo referenced by products.cfg as git@github.com:
# (SSH) is cloned by mr.developer as the plone user. Step 3 installs the SSH key
# bootstrap created for root into the plone user's ~/.ssh so those clones
# authenticate. The key's GitHub account must have read access to those repos.

# Zope loopback port (must match phase 7b/7c).
ZOPE_LOOPBACK_PORT=8080

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
    echo "FATAL: DOMAIN is not set. tenant.local must define it before phase 7d runs."
    exit 1
fi
PLONE_SITE_NAME="${PLONE_SITE_NAME:-$(echo "$DOMAIN" | cut -d. -f1)}"
PLONE_INSTANCE_DIR="${PLONE_HOME}/${PLONE_SITE_NAME}"

# systemd unit name (must match what phase 7c created).
PLONE_SYSTEMD_UNIT="plone-${PLONE_SITE_NAME}"

# Overlay buildout: where it lands inside the instance dir (next to buildout.cfg).
PRODUCTS_CFG_DST="${PLONE_INSTANCE_DIR}/products.cfg"
BUILDOUT_CFG="${PLONE_INSTANCE_DIR}/buildout.cfg"
BIN_BUILDOUT="${PLONE_INSTANCE_DIR}/bin/buildout"
BIN_INSTANCE="${PLONE_INSTANCE_DIR}/bin/instance"

# ============================================================================
# REPORT TRACKING + HELPERS
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
echo "  PHASE 7D: Install Docent add-on products into Plone"
echo "==================================================================="
echo "  Instance dir:   $PLONE_INSTANCE_DIR"
echo "  Overlay source: $PRODUCTS_CFG_URL"
echo "  Overlay target: $PRODUCTS_CFG_DST"
echo "  Systemd unit:   $PLONE_SYSTEMD_UNIT.service"
echo ""

# ============================================================================
# STEP 1: Verify prerequisites from phases 7a/7b/7c
# ============================================================================
step "Step 1: Verifying prerequisites from phases 7a/7b/7c"

if ! id "$PLONE_USER" >/dev/null 2>&1; then
    log_fail "User '$PLONE_USER' does not exist. Did phase 7a run?"
    exit 1
fi
log_done "User '$PLONE_USER' exists"

if [ ! -d "$PLONE_INSTANCE_DIR" ]; then
    log_fail "Instance dir $PLONE_INSTANCE_DIR does not exist. Did phase 7b run?"
    exit 1
fi
log_done "Instance dir exists"

if [ ! -f "$BUILDOUT_CFG" ] || ! grep -q "phase7b-marker" "$BUILDOUT_CFG" 2>/dev/null; then
    log_fail "$BUILDOUT_CFG is missing or not phase7b-managed. Did phase 7b run?"
    exit 1
fi
log_done "Phase 7b's buildout.cfg exists (products.cfg will extend it)"

if [ ! -x "$BIN_BUILDOUT" ]; then
    log_fail "$BIN_BUILDOUT not found or not executable. Did phase 7b run?"
    exit 1
fi
log_done "bin/buildout exists"

if [ ! -x "$BIN_INSTANCE" ]; then
    log_fail "$BIN_INSTANCE not found. Did phase 7b run?"
    exit 1
fi
log_done "bin/instance exists"

if ! systemctl cat "${PLONE_SYSTEMD_UNIT}.service" >/dev/null 2>&1; then
    log_fail "systemd unit ${PLONE_SYSTEMD_UNIT}.service not found. Did phase 7c run?"
    exit 1
fi
log_done "systemd unit ${PLONE_SYSTEMD_UNIT}.service exists"

# ============================================================================
# STEP 2: Download the add-on overlay (products.cfg) from GitHub
# ============================================================================
step "Step 2: Downloading products.cfg from the docent-plone-addons repo"

if ! command -v curl >/dev/null 2>&1; then
    log_fail "curl is not installed - cannot download products.cfg."
    exit 1
fi

TMP_CFG="$(mktemp)"
if ! curl -fsSL "$PRODUCTS_CFG_URL" -o "$TMP_CFG"; then
    rm -f "$TMP_CFG"
    log_fail "Could not download products.cfg from:"
    log_fail "  $PRODUCTS_CFG_URL"
    log_fail "Check that the docent-plone-addons repo is public, that the file"
    log_fail "exists at that branch/path, and that the server has internet access."
    exit 1
fi

if [ ! -s "$TMP_CFG" ]; then
    rm -f "$TMP_CFG"
    log_fail "The downloaded products.cfg is empty (zero bytes)."
    exit 1
fi

# Sanity check: it must be the OVERLAY (extends buildout.cfg) - not a full
# replacement buildout, and not a stray GitHub error page.
if ! grep -qE '^[[:space:]]*extends[[:space:]]*=[[:space:]]*buildout\.cfg' "$TMP_CFG"; then
    rm -f "$TMP_CFG"
    log_fail "The downloaded file does not look like the add-on overlay."
    log_fail "It must contain a line: extends = buildout.cfg"
    log_fail "Got something else (a full-replacement buildout, or an error page)."
    exit 1
fi
log_done "Downloaded products.cfg and confirmed it is the add-on overlay"

# Place it next to buildout.cfg in the instance dir, owned by the plone user.
cp "$TMP_CFG" "$PRODUCTS_CFG_DST"
rm -f "$TMP_CFG"
chown "${PLONE_USER}:${PLONE_USER}" "$PRODUCTS_CFG_DST"
chmod 644 "$PRODUCTS_CFG_DST"
log_done "products.cfg installed at $PRODUCTS_CFG_DST"

# Derive the add-on list from the overlay's [instance] eggs block. This is the
# single source of truth - there is no hard-coded product list in this script.
PRODUCTS=()
while IFS= read -r prod; do
    [ -n "$prod" ] && PRODUCTS+=("$prod")
done < <(awk '
    /^\[instance\]/ { in_inst=1; next }
    /^\[/           { in_inst=0; in_eggs=0; next }
    in_inst && /^[[:space:]]*eggs[[:space:]]*\+?=/ { in_eggs=1; next }
    in_eggs && /^[[:space:]]*$/ { next }
    in_eggs && /^[[:space:]]*#/ { next }
    in_eggs && /^[[:space:]]+[^[:space:]]/ {
        line=$0
        sub(/^[[:space:]]+/, "", line)
        sub(/[[:space:]]+$/, "", line)
        print line
        next
    }
    in_eggs { in_eggs=0 }
' "$PRODUCTS_CFG_DST")

if [ "${#PRODUCTS[@]}" -eq 0 ]; then
    log_warn "Could not read any add-on names from products.cfg [instance] eggs."
    log_warn "buildout will still run, but per-product verification is skipped."
else
    echo "  Add-ons listed in products.cfg: ${#PRODUCTS[@]}"
    for p in "${PRODUCTS[@]}"; do echo "    - $p"; done
fi

# ============================================================================
# STEP 3: Run the overlay buildout as the plone user
# ============================================================================
step "Step 3: Running the add-on buildout (this takes several minutes)"

echo ""
echo "  -----------------------------------------------------------------"
echo "  buildout is about to fetch the add-on packages and compile them."
echo "  This typically takes 3-8 minutes and prints a lot of output."
echo "  DO NOT press Ctrl-C - let it finish. An interrupted buildout can"
echo "  leave the instance half-built."
echo "  -----------------------------------------------------------------"
echo ""

# Private add-on repos in products.cfg are referenced as git@github.com: (SSH)
# and cloned by mr.developer as the plone user. Give the plone user the SSH key
# that bootstrap created for root (and that the operator registered on GitHub),
# so those clones authenticate. Harmless for public https sources.
PLONE_SSH_DIR="$(getent passwd "$PLONE_USER" | cut -d: -f6)/.ssh"
ROOT_SSH_KEY="/root/.ssh/id_ed25519"
if [ -f "$ROOT_SSH_KEY" ]; then
    install -d -m 700 -o "$PLONE_USER" -g "$PLONE_USER" "$PLONE_SSH_DIR"
    install -m 600 -o "$PLONE_USER" -g "$PLONE_USER" "$ROOT_SSH_KEY" "$PLONE_SSH_DIR/id_ed25519"
    if [ -f "$ROOT_SSH_KEY.pub" ]; then
        install -m 644 -o "$PLONE_USER" -g "$PLONE_USER" "$ROOT_SSH_KEY.pub" "$PLONE_SSH_DIR/id_ed25519.pub"
    fi
    # Pre-accept github.com's host key so the clone doesn't prompt or fail.
    if ! sudo -u "$PLONE_USER" ssh-keygen -F github.com -f "$PLONE_SSH_DIR/known_hosts" >/dev/null 2>&1; then
        ssh-keyscan -t rsa,ed25519 github.com 2>/dev/null \
            | sudo -u "$PLONE_USER" tee -a "$PLONE_SSH_DIR/known_hosts" >/dev/null
    fi
    log_done "Installed GitHub SSH key for $PLONE_USER (enables private add-on repos)"
else
    log_warn "No SSH key at $ROOT_SSH_KEY - private add-on repos (git@github.com:) will fail to clone."
    log_warn "Run bootstrap.sh first (it creates and registers the key), or install a key for $PLONE_USER manually."
fi

if ! sudo -u "$PLONE_USER" bash -c "cd '$PLONE_INSTANCE_DIR' && bin/buildout -c products.cfg"; then
    log_fail "The add-on buildout (bin/buildout -c products.cfg) failed."
    log_fail "Review the buildout output above. Common causes: an add-on's"
    log_fail "dependency conflicts with the Plone version, a git source URL is"
    log_fail "unreachable, or a private repo's SSH key lacks access on GitHub."
    log_fail "Plone itself (from phase 7b) is unaffected - fix the issue and"
    log_fail "re-run phase 7d."
    exit 1
fi
log_done "Add-on buildout completed"

if [ ! -x "$BIN_INSTANCE" ]; then
    log_fail "bin/instance is missing after buildout - the systemd unit would fail."
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
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$ZOPE_LOOPBACK_PORT/" 2>/dev/null || true)"
    case "$code" in
        2*|3*|4*) break ;;
    esac
    sleep 2
    WAIT=$((WAIT + 2))
done
if [ "$WAIT" -ge 90 ]; then
    log_fail "Plone did not come back up on 127.0.0.1:$ZOPE_LOOPBACK_PORT after 90s."
    log_fail "An add-on may be failing at Zope startup. Check:"
    log_fail "  journalctl -u $PLONE_SYSTEMD_UNIT -n 80"
    exit 1
fi
log_done "Plone is responding again on 127.0.0.1:$ZOPE_LOOPBACK_PORT (took ${WAIT}s)"

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

if [ -s "$PRODUCTS_CFG_DST" ]; then
    vp "products.cfg present in instance dir"
else
    vf "products.cfg missing from instance dir"
fi

if systemctl is-active --quiet "$PLONE_SYSTEMD_UNIT"; then
    vp "systemd unit $PLONE_SYSTEMD_UNIT is active"
else
    vf "systemd unit $PLONE_SYSTEMD_UNIT is NOT active"
fi

# Each add-on should be materialized in the instance: either a released egg
# under eggs/, or a mr.developer source checkout under src/ (with a link in
# develop-eggs/). This mirrors how phase 7b verifies the Plone egg.
if [ "${#PRODUCTS[@]}" -gt 0 ]; then
    for prod in "${PRODUCTS[@]}"; do
        if ls -d "$PLONE_INSTANCE_DIR"/eggs/"${prod}"*        >/dev/null 2>&1 \
           || ls -d "$PLONE_INSTANCE_DIR"/develop-eggs/"${prod}"* >/dev/null 2>&1 \
           || [ -d "$PLONE_INSTANCE_DIR/src/$prod" ]; then
            vp "Add-on built into instance: $prod"
        else
            vf "Add-on NOT found in instance: $prod"
        fi
    done
fi

echo ""
echo "  Verification: $VERIFY_PASSED passed, $VERIFY_FAILED failed"

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
echo "==================================================================="
echo "  MANUAL NEXT STEPS"
echo "==================================================================="
echo ""
echo "  The add-ons are now BUILT INTO the Plone instance, but they are NOT"
echo "  yet activated inside the Plone site."
echo ""
echo "  To activate an add-on:"
echo "    1. Log in to Plone as admin."
echo "       (admin password: PLONE_ADMIN_PW in $REPO_ROOT/CREDENTIALS.txt)"
echo "    2. Go to: Site Setup -> Add-ons"
echo "    3. Click 'Install' next to each add-on you want active."
echo ""
echo "  Useful commands:"
echo "    sudo systemctl status  $PLONE_SYSTEMD_UNIT"
echo "    sudo systemctl restart $PLONE_SYSTEMD_UNIT"
echo "    sudo journalctl -u $PLONE_SYSTEMD_UNIT -f"
echo ""
echo "  To change which add-ons are installed, edit products.cfg in the"
echo "  docent-plone-addons GitHub repo, then re-run phase 7d."
echo ""
echo "==================================================================="
echo ""

# Exit non-zero if any verification check failed, so run-phases.sh notices.
if [ "$VERIFY_FAILED" -gt 0 ]; then
    echo "  *** $VERIFY_FAILED CHECK(S) FAILED - review the failures above. ***"
    echo ""
    exit 1
fi
exit 0
