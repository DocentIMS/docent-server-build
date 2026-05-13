#!/bin/bash
#
# phase7a-plone-prereqs.sh - Phase 7a: OS prerequisites for Plone 6.2 classic
#
# Installs system packages and creates the working environment that Plone
# needs, but does NOT install Plone itself. After this phase runs, the
# 'plone' user can run buildout from /home/plone/<sitename>/ (derived from
# DOMAIN) to install whichever Plone configuration the user (or their
# Plone programmer) prefers.
#
# Specifically this phase does NOT:
#   - clone any Plone repo
#   - run buildout
#   - install Apache reverse-proxy vhost (deferred until URL/site-id decided)
#   - install systemd unit (deferred until buildout produces bin/instance)
#   - open firewall (Zope binds 127.0.0.1:8080 by default; not exposed)
#
# Phase 7b (future) will handle those items once the install approach is
# agreed between Wayne and the Plone programmer.
#
# Idempotent. Safe to re-run. Each step checks current state before acting.
# Run as root via run-phases.sh, or directly: bash phase7a-plone-prereqs.sh
#

set -u

# ============================================================================
# CONFIGURATION
# ============================================================================
PLONE_USER="plone"
PLONE_HOME="/home/plone"
PLONE_INSTANCE_DIR=""  # Derived from DOMAIN below, after tenant.local is sourced
PLONE_SHELL="/bin/bash"

# Python version requirements for Plone 6.2 (per official Plone docs).
# Plone 6.2.0rc2 was released 2026-05-08 and supports Python 3.10 through 3.14.
# Ubuntu 26.04 ships with Python 3.14 as the system Python, so the system
# python3 binary works out of the box without deadsnakes/pyenv.
#
# (Plone 6.1 supports only 3.10-3.13. We deliberately target 6.2 to avoid
# needing a separate Python install for 3.13 or earlier.)
PYTHON_MIN_MAJOR=3
PYTHON_MIN_MINOR=10
PYTHON_MAX_MINOR=14

# System packages required by Plone 6.2 classic + DocentIMS.ActionItems
# install_requires (numpy, pandas, openpyxl, python-docx-oss, etc.)
SYSTEM_PACKAGES=(
    # Build toolchain
    build-essential
    # OpenSSL headers (Python builds, several Plone deps)
    libssl-dev
    # libffi (cffi, cryptography)
    libffi-dev
    # XML/XSLT (lxml, plone.app.theming, Diazo)
    libxml2-dev
    libxslt1-dev
    # Image libraries (Pillow, plone.scale)
    libjpeg-dev
    libtiff-dev
    libwebp-dev
    libfreetype-dev   # Ubuntu 26.04 renamed libfreetype6-dev to libfreetype-dev
    # Compression (Pillow, ZODB)
    zlib1g-dev
    # Python dev + venv (Plone buildout creates a venv)
    python3-dev
    python3-venv
    # PDF tooling - intentionally an OS dep, listed in DocentIMS.ActionItems
    # install_requires as a hint even though it's not a Python package
    poppler-utils
    # SASL + LDAP (some Plone integration packages pull python-ldap)
    libsasl2-dev
    libldap2-dev
    # Misc
    git
    wget
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
unset __PHASE_SCRIPT_DIR __PHASE_REPO_ROOT
# === END tenant.local/secrets.local source block ===

# Derive PLONE_INSTANCE_DIR from DOMAIN (matches phase 7b/7c convention).
# Each tenant gets a Plone instance at /home/plone/<first-label-of-DOMAIN>/
# e.g. DOMAIN=docentclienttest.com -> /home/plone/docentclienttest/
# This way one server can in principle host multiple tenants' Plone instances
# in sibling directories under /home/plone/, even though the current build
# assumes single-tenant.
if [ -z "${DOMAIN:-}" ]; then
    echo "FATAL: DOMAIN is not set. tenant.local must define it before phase 7a runs."
    exit 1
fi
PLONE_SITE_NAME="${PLONE_SITE_NAME:-$(echo "$DOMAIN" | cut -d. -f1)}"
PLONE_INSTANCE_DIR="${PLONE_HOME}/${PLONE_SITE_NAME}"

# ============================================================================
# REPORT TRACKING
# ============================================================================
REPORT=()

log_done()    { REPORT+=("[DONE]    $1"); echo "  ✓ $1"; }
log_skip()    { REPORT+=("[SKIPPED] $1 (already done)"); echo "  - $1 (already done)"; }
log_warn()    { REPORT+=("[WARN]    $1"); echo "  ! $1"; }
log_fail()    { REPORT+=("[FAIL]    $1"); echo "  ✗ $1"; }

step() { echo ""; echo "=== $1 ==="; }

# wait_for_dpkg_lock - block until /var/lib/dpkg/lock-frontend is released.
# Same helper as phases 1-6. unattended-upgrades or apt-daily can hold the
# lock; without this guard apt fails silently and the script cascades errors.
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
# Must run as root
# ============================================================================
if [ "$EUID" -ne 0 ]; then
    echo "This phase must run as root. Try: sudo bash $0"
    exit 1
fi

# ============================================================================
# STEP 1: Verify Python version is in Plone 6.2's supported range
# ============================================================================
step "Step 1: Verifying system Python version"

if ! command -v python3 >/dev/null 2>&1; then
    log_fail "python3 not found on system"
    echo ""
    echo "  This is unexpected on Ubuntu 26.04 - the OS ships with Python 3."
    echo "  Aborting. Investigate why python3 is missing before continuing."
    exit 1
fi

PYTHON_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
PYTHON_MAJOR=$(echo "$PYTHON_VERSION" | cut -d. -f1)
PYTHON_MINOR=$(echo "$PYTHON_VERSION" | cut -d. -f2)

if [ "$PYTHON_MAJOR" -ne "$PYTHON_MIN_MAJOR" ] \
   || [ "$PYTHON_MINOR" -lt "$PYTHON_MIN_MINOR" ] \
   || [ "$PYTHON_MINOR" -gt "$PYTHON_MAX_MINOR" ]; then
    log_fail "Python $PYTHON_VERSION is outside Plone 6.2's supported range (3.10-3.14)"
    echo ""
    echo "  Plone 6.2 requires Python 3.10, 3.11, 3.12, 3.13, or 3.14."
    echo "  Detected: $PYTHON_VERSION"
    echo ""
    echo "  On Ubuntu 26.04 the system Python is 3.14, which is in range. If"
    echo "  this check is failing, the system was upgraded or modified. Either:"
    echo "    - install a supported Python from deadsnakes PPA, or"
    echo "    - investigate why python3 is reporting an unsupported version."
    exit 1
fi

log_done "System Python is $PYTHON_VERSION (in Plone 6.2's supported range)"

# ============================================================================
# STEP 2: Install system packages
# ============================================================================
step "Step 2: Installing Plone system prerequisites"

export DEBIAN_FRONTEND=noninteractive

# Compute MISSING list
MISSING=""
for pkg in "${SYSTEM_PACKAGES[@]}"; do
    if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        MISSING="$MISSING $pkg"
    fi
done

if [ -z "$MISSING" ]; then
    log_skip "All system packages already installed"
else
    wait_for_dpkg_lock
    apt-get update -qq
    wait_for_dpkg_lock
    if apt-get install -y -qq -o Dpkg::Use-Pty=0 $MISSING < /dev/null; then
        log_done "Installed system packages:$MISSING"
    else
        log_fail "apt-get install failed (exit code $?). Packages NOT installed:$MISSING"
        exit 1
    fi
fi

# ============================================================================
# STEP 3: Verify and configure plone system user
# ============================================================================
step "Step 3: Verifying plone system user"

if ! id "$PLONE_USER" >/dev/null 2>&1; then
    log_fail "User '$PLONE_USER' does not exist"
    echo ""
    echo "  This phase expects phase 2 to have created the plone user."
    echo "  Re-run phase 2 first:"
    echo "    sudo bash /root/server-build/scripts/run-phases.sh --from 2"
    exit 1
fi
log_done "User '$PLONE_USER' exists"

# Verify home directory
if [ ! -d "$PLONE_HOME" ]; then
    log_fail "Home directory $PLONE_HOME does not exist"
    echo "  Re-run phase 2 to create it."
    exit 1
fi
log_done "Home directory $PLONE_HOME exists"

# Change shell from /usr/sbin/nologin to /bin/bash so we can su - plone
CURRENT_SHELL=$(getent passwd "$PLONE_USER" | cut -d: -f7)
if [ "$CURRENT_SHELL" = "$PLONE_SHELL" ]; then
    log_skip "User '$PLONE_USER' already has shell $PLONE_SHELL"
else
    if usermod -s "$PLONE_SHELL" "$PLONE_USER"; then
        log_done "Changed shell of '$PLONE_USER' from $CURRENT_SHELL to $PLONE_SHELL"
    else
        log_fail "Failed to change shell of '$PLONE_USER' to $PLONE_SHELL"
        exit 1
    fi
fi

# ============================================================================
# STEP 4: Create Plone instance working directory
# ============================================================================
step "Step 4: Creating Plone instance working directory"

if [ -d "$PLONE_INSTANCE_DIR" ]; then
    log_skip "Directory $PLONE_INSTANCE_DIR already exists"
else
    if mkdir -p "$PLONE_INSTANCE_DIR"; then
        log_done "Created directory $PLONE_INSTANCE_DIR"
    else
        log_fail "Failed to create $PLONE_INSTANCE_DIR"
        exit 1
    fi
fi

# Ensure ownership of the entire /home/plone tree is plone:plone.
# This is idempotent and cheap. Necessary because the tree may have files
# created by root in earlier ad-hoc work.
if chown -R "$PLONE_USER:$PLONE_USER" "$PLONE_HOME"; then
    log_done "Ownership of $PLONE_HOME tree set to $PLONE_USER:$PLONE_USER"
else
    log_fail "chown -R failed on $PLONE_HOME"
    exit 1
fi

# Set sane permissions on the instance directory
chmod 755 "$PLONE_INSTANCE_DIR"

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

verify() {
    local description="$1"
    local result="$2"
    if [ "$result" = "PASS" ]; then
        echo "  [PASS] $description"
        VERIFY_PASSED=$((VERIFY_PASSED + 1))
    else
        echo "  [FAIL] $description"
        VERIFY_FAILED=$((VERIFY_FAILED + 1))
    fi
}

# Python in supported range.
# NOTE: this check uses the same PYTHON_MIN_MINOR / PYTHON_MAX_MINOR variables
# as Step 1, so the two can never disagree. (Earlier version of this script
# had hard-coded 10/13 here while Step 1 used the variables; when 6.2 widened
# the range to 14, Step 1 was updated but this check was not, causing Step 1
# to pass and verification to fail for the same Python version.)
PY_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null)
PY_MAJOR=$(echo "$PY_VER" | cut -d. -f1)
PY_MINOR=$(echo "$PY_VER" | cut -d. -f2)
if [ "$PY_MAJOR" = "$PYTHON_MIN_MAJOR" ] \
   && [ "$PY_MINOR" -ge "$PYTHON_MIN_MINOR" ] \
   && [ "$PY_MINOR" -le "$PYTHON_MAX_MINOR" ]; then
    verify "Python $PY_VER is in Plone 6.2 supported range" "PASS"
else
    verify "Python $PY_VER is in Plone 6.2 supported range" "FAIL"
fi

# Each system package
for pkg in "${SYSTEM_PACKAGES[@]}"; do
    if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        verify "Package '$pkg' is installed" "PASS"
    else
        verify "Package '$pkg' is installed" "FAIL"
    fi
done

# plone user exists
if id "$PLONE_USER" >/dev/null 2>&1; then
    verify "User '$PLONE_USER' exists" "PASS"
else
    verify "User '$PLONE_USER' exists" "FAIL"
fi

# plone user has bash shell
SHELL_NOW=$(getent passwd "$PLONE_USER" | cut -d: -f7)
if [ "$SHELL_NOW" = "$PLONE_SHELL" ]; then
    verify "User '$PLONE_USER' has shell $PLONE_SHELL" "PASS"
else
    verify "User '$PLONE_USER' has shell $PLONE_SHELL (got: $SHELL_NOW)" "FAIL"
fi

# /home/plone exists and owned by plone
if [ -d "$PLONE_HOME" ]; then
    OWNER=$(stat -c '%U' "$PLONE_HOME")
    if [ "$OWNER" = "$PLONE_USER" ]; then
        verify "Directory $PLONE_HOME exists and owned by '$PLONE_USER'" "PASS"
    else
        verify "Directory $PLONE_HOME exists and owned by '$PLONE_USER' (got: $OWNER)" "FAIL"
    fi
else
    verify "Directory $PLONE_HOME exists and owned by '$PLONE_USER'" "FAIL"
fi

# /home/plone/instance exists and owned by plone
if [ -d "$PLONE_INSTANCE_DIR" ]; then
    OWNER=$(stat -c '%U' "$PLONE_INSTANCE_DIR")
    if [ "$OWNER" = "$PLONE_USER" ]; then
        verify "Directory $PLONE_INSTANCE_DIR exists and owned by '$PLONE_USER'" "PASS"
    else
        verify "Directory $PLONE_INSTANCE_DIR exists and owned by '$PLONE_USER' (got: $OWNER)" "FAIL"
    fi
else
    verify "Directory $PLONE_INSTANCE_DIR exists and owned by '$PLONE_USER'" "FAIL"
fi

# /home/plone/instance writable by plone (sudo -u plone test)
if su - "$PLONE_USER" -c "test -w '$PLONE_INSTANCE_DIR'" 2>/dev/null; then
    verify "User '$PLONE_USER' can write to $PLONE_INSTANCE_DIR" "PASS"
else
    verify "User '$PLONE_USER' can write to $PLONE_INSTANCE_DIR" "FAIL"
fi

# poppler-utils binaries are usable
if su - "$PLONE_USER" -c "command -v pdftotext >/dev/null 2>&1 && command -v pdftoppm >/dev/null 2>&1" 2>/dev/null; then
    verify "Poppler binaries (pdftotext, pdftoppm) are on plone's PATH" "PASS"
else
    verify "Poppler binaries (pdftotext, pdftoppm) are on plone's PATH" "FAIL"
fi

echo ""
echo "  Verification: $VERIFY_PASSED passed, $VERIFY_FAILED failed"
echo ""

if [ "$VERIFY_FAILED" -gt 0 ]; then
    echo "  *** $VERIFY_FAILED CHECK(S) FAILED. Review failures above before proceeding. ***"
fi

# ============================================================================
# MANUAL VERIFICATION / NEXT STEPS
# ============================================================================
echo ""
echo "==================================================================="
echo "  MANUAL NEXT STEPS"
echo "==================================================================="
echo ""
echo "  Phase 7a only installs OS prerequisites and the per-tenant directory"
echo "  at $PLONE_INSTANCE_DIR. Plone itself is NOT yet installed."
echo ""
echo "  Next phase: 7b will run buildout in $PLONE_INSTANCE_DIR, install"
echo "  Plone (6.2 by default, configurable via PLONE_VERSION in tenant.local),"
echo "  and record an admin password in CREDENTIALS.txt."
echo ""
echo "  To proceed:"
echo "    sudo bash /root/server-build/scripts/phase7b-plone-buildout.sh"
echo ""
echo "  (Phase 7c then exposes Plone at https://team.<DOMAIN>/ via"
echo "   Apache reverse proxy, and creates the Plone Site object inside the"
echo "   Zope instance with distribution='classic'.)"
echo ""
echo "  NOTE on Plone 6.2.0rc2 (current default in phase 7b): this is a"
echo "  release candidate, not stable final. Final 6.2.0 expected late May"
echo "  2026. When final ships, update phase 7b's DEFAULT_PLONE_VERSION."
echo ""
echo "==================================================================="
echo ""

# ============================================================================
# SUMMARY REPORT
# ============================================================================
echo "==================================================================="
echo "  PHASE 7A SUMMARY REPORT"
echo "==================================================================="
echo ""
for line in "${REPORT[@]}"; do
    echo "  $line"
done
echo ""
echo "==================================================================="
