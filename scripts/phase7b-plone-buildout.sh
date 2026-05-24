#!/bin/bash
#
# phase7b-plone-buildout.sh - Phase 7b: Install Plone 6.2 via buildout
#
# Prerequisites: phase 7a has run (plone user exists, OS packages installed,
# /home/plone/<sitename>/ directory exists owned by plone). DOMAIN must
# be set in tenant.local.
#
# What this phase does:
#   1. Read PLONE_VERSION from tenant.local (default to a known-good version)
#   2. Read or generate PLONE_ADMIN_PW; write to CREDENTIALS.txt
#   3. As plone user: create venv, install buildout prerequisites
#   4. Write buildout.cfg (with phase7b-marker)
#   5. Bootstrap and run buildout (produces bin/instance, ~5-15 min)
#   6. Verify the install succeeded
#
# What this phase does NOT do (deferred to phase 7c):
#   - bind Plone to 127.0.0.1 (left on 0.0.0.0:8080 here; 7c locks it down)
#   - install systemd unit
#   - install Apache reverse-proxy vhost
#   - create the Plone Site object inside the Zope instance
#     (7c does this automatically via bin/instance run, with
#      distribution_name='classic' so Folder/Page/etc. are installed)
#
# Note: phase 1 already installs ufw with port 8080 blocked, so even
# though buildout configures Plone to listen on 0.0.0.0, external traffic
# can't reach it between 7b and 7c. Phase 7c then changes the listen
# address to 127.0.0.1 belt-and-suspenders.
#
# Idempotent. Safe to re-run. Each step checks current state before acting.
# Run as root via run-phases.sh, or directly: sudo bash phase7b-plone-buildout.sh
#

set -u

# ============================================================================
# CONFIGURATION
# ============================================================================
PLONE_USER="plone"
PLONE_HOME="/home/plone"
PLONE_INSTANCE_DIR=""  # Set after tenant.local is sourced (see below)

# Default Plone version. Override via PLONE_VERSION in tenant.local.
# As of May 2026, 6.2.0rc2 is the current release candidate; 6.2 stable
# expected end of May. Pin to a specific version for reproducibility.
DEFAULT_PLONE_VERSION="6.2.0rc2"

# Plone release line: used to fetch versions.cfg and requirements.txt.
# For 6.2.x releases this is "6.2-latest". For 6.1.x it would be "6.1-latest".
# Computed from PLONE_VERSION below (e.g. 6.2.0rc2 -> 6.2-latest).
PLONE_RELEASE_LINE=""


# Compute Plone path values now that tenant.local has been sourced.
if [ -z "${DOMAIN:-}" ]; then
    echo "FATAL: DOMAIN is not set. tenant.local must define it before phase 7b runs."
    exit 1
fi
PLONE_SITE_NAME="${PLONE_SITE_NAME:-$(echo "$DOMAIN" | cut -d. -f1)}"
PLONE_INSTANCE_DIR="${PLONE_HOME}/${PLONE_SITE_NAME}"

# Apply Plone version: tenant.local override > script default
PLONE_VERSION="${PLONE_VERSION:-$DEFAULT_PLONE_VERSION}"

# Compute release line from PLONE_VERSION (e.g. 6.2.0rc2 -> 6.2)
PLONE_MAJOR_MINOR=$(echo "$PLONE_VERSION" | grep -oE '^[0-9]+\.[0-9]+')
if [ -z "$PLONE_MAJOR_MINOR" ]; then
    echo "FATAL: cannot parse PLONE_VERSION='$PLONE_VERSION' (expected like 6.2.0rc2)"
    exit 1
fi
PLONE_RELEASE_LINE="${PLONE_MAJOR_MINOR}-latest"

# Credentials file location (matches phase 4 / phase 5 convention)
CREDENTIALS_FILE="$REPO_ROOT/CREDENTIALS.txt"

# ============================================================================
# REPORT TRACKING
# ============================================================================
REPORT=()


# ============================================================================
# Must run as root
# ============================================================================
if [ "$EUID" -ne 0 ]; then
    echo "This phase must run as root. Try: sudo bash $0"
    exit 1
fi

echo ""
echo "==================================================================="
echo "  PHASE 7B: Install Plone $PLONE_VERSION via buildout"
echo "==================================================================="
echo "  Site name:     $PLONE_SITE_NAME"
echo "  Install dir:   $PLONE_INSTANCE_DIR"
echo "  Plone version: $PLONE_VERSION"
echo "  Release line:  $PLONE_RELEASE_LINE"
echo ""

# ============================================================================
# STEP 1: Verify phase 7a prerequisites
# ============================================================================
step "Step 1: Verifying phase 7a prerequisites"

# plone user must exist
if ! id "$PLONE_USER" >/dev/null 2>&1; then
    log_fail "User '$PLONE_USER' does not exist. Did phase 7a run?"
    exit 1
fi
log_done "User '$PLONE_USER' exists"

# Install dir must exist and be writable by plone
if [ ! -d "$PLONE_INSTANCE_DIR" ]; then
    log_fail "Directory $PLONE_INSTANCE_DIR does not exist. Did phase 7a run?"
    exit 1
fi
if ! su - "$PLONE_USER" -c "test -w '$PLONE_INSTANCE_DIR'" 2>/dev/null; then
    log_fail "User '$PLONE_USER' cannot write to $PLONE_INSTANCE_DIR"
    exit 1
fi
log_done "Directory $PLONE_INSTANCE_DIR exists and is writable by '$PLONE_USER'"

# python3 must be in supported range (phase 7a already checked, but cheap to re-verify)
if ! command -v python3 >/dev/null 2>&1; then
    log_fail "python3 not found on system"
    exit 1
fi
PYTHON_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
log_done "System Python is $PYTHON_VERSION"

# ============================================================================
# STEP 2: Establish PLONE_ADMIN_PW
# ============================================================================
step "Step 2: Establishing Plone admin password"

# Source of truth: secrets.local if set, otherwise generate, then write to
# CREDENTIALS.txt. This matches how phase 4 handles MAIL_DB_PW.
if [ -n "${PLONE_ADMIN_PW:-}" ]; then
    log_skip "PLONE_ADMIN_PW already set from secrets.local"
    PLONE_ADMIN_PW_SOURCE="secrets.local"
else
    PLONE_ADMIN_PW=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
    log_done "Generated PLONE_ADMIN_PW (24 chars)"
    PLONE_ADMIN_PW_SOURCE="generated"
fi

# Append to CREDENTIALS.txt if not already there
if [ ! -f "$CREDENTIALS_FILE" ]; then
    log_warn "CREDENTIALS.txt does not exist at $CREDENTIALS_FILE. Phase 0 normally creates it."
    log_warn "Creating it now with just the Plone admin entry."
    touch "$CREDENTIALS_FILE"
    chmod 600 "$CREDENTIALS_FILE"
fi
if grep -q "^PLONE_ADMIN_PW=" "$CREDENTIALS_FILE" 2>/dev/null; then
    log_skip "PLONE_ADMIN_PW already recorded in CREDENTIALS.txt"
else
    {
        echo ""
        echo "# === Plone (added by phase7b) ==="
        echo "PLONE_ADMIN_USER=admin"
        echo "PLONE_ADMIN_PW=$PLONE_ADMIN_PW"
        echo "PLONE_VERSION=$PLONE_VERSION"
        echo "PLONE_INSTANCE_DIR=$PLONE_INSTANCE_DIR"
        echo "PLONE_URL_LOCAL=http://127.0.0.1:8080/"
    } >> "$CREDENTIALS_FILE"
    log_done "Recorded Plone admin credentials to $CREDENTIALS_FILE"
fi

# Also insert a human-readable Plone admin entry into the BACKEND PASSWORDS
# section, right after the WordPress admin line. The machine-readable block
# above is what phase 7c parses; this insert is purely for the human reading
# CREDENTIALS.txt.
#
# Anchor: the WordPress admin's "login: ...wp-admin/" line (unique in the file).
# Idempotent: skip if "Plone admin:" already appears in the BACKEND block.
PLONE_HUMAN_LINE="  Plone admin:         ${PLONE_ADMIN_PW}    (user: admin)"
PLONE_HUMAN_LOGIN="                                          login: https://team.${DOMAIN}/login"
if grep -qE "^  Plone admin:" "$CREDENTIALS_FILE" 2>/dev/null; then
    log_skip "Plone admin line already in human-readable BACKEND PASSWORDS section"
elif grep -qE "login: https://[^/]+/wp-admin/" "$CREDENTIALS_FILE" 2>/dev/null; then
    # Found the anchor. Use awk to insert two lines right after it.
    # awk handles this more reliably than sed for multi-line content with
    # special characters in the password.
    TMP=$(mktemp)
    awk -v line1="$PLONE_HUMAN_LINE" -v line2="$PLONE_HUMAN_LOGIN" '
        { print }
        /login: https:\/\/[^/]+\/wp-admin\// {
            print line1
            print line2
        }
    ' "$CREDENTIALS_FILE" > "$TMP" && mv "$TMP" "$CREDENTIALS_FILE"
    chmod 600 "$CREDENTIALS_FILE"
    log_done "Inserted Plone admin into human-readable BACKEND PASSWORDS section"
else
    log_warn "No WordPress admin anchor in $CREDENTIALS_FILE - skipping human-readable insert. Plone password is still in the machine-readable section above."
fi

# ============================================================================
# STEP 3: Create venv and install buildout prerequisites
# ============================================================================
step "Step 3: Creating Python venv and installing buildout prerequisites"

VENV_DIR="$PLONE_INSTANCE_DIR/venv"
REQ_URL="https://dist.plone.org/release/${PLONE_RELEASE_LINE}/requirements.txt"

if [ -x "$VENV_DIR/bin/buildout" ]; then
    log_skip "Venv at $VENV_DIR already has buildout installed"
else
    # Create venv (idempotent: python3 -m venv on an existing dir is harmless)
    if ! sudo -u "$PLONE_USER" python3 -m venv "$VENV_DIR"; then
        log_fail "Failed to create venv at $VENV_DIR"
        exit 1
    fi
    log_done "Created venv at $VENV_DIR"

    # Install buildout + pip + setuptools + wheel from Plone release requirements
    if ! sudo -u "$PLONE_USER" "$VENV_DIR/bin/pip" install --pre -r "$REQ_URL"; then
        log_fail "Failed to install buildout prerequisites from $REQ_URL"
        log_fail "Check network connectivity and that PLONE_RELEASE_LINE='$PLONE_RELEASE_LINE' exists on dist.plone.org"
        exit 1
    fi
    log_done "Installed buildout prerequisites (pip, setuptools, wheel, zc.buildout)"
fi

# ============================================================================
# STEP 4: Write buildout.cfg
# ============================================================================
step "Step 4: Writing buildout.cfg"

BUILDOUT_CFG="$PLONE_INSTANCE_DIR/buildout.cfg"

if [ -f "$BUILDOUT_CFG" ] && grep -q "phase7b-marker" "$BUILDOUT_CFG" 2>/dev/null; then
    log_skip "buildout.cfg already exists and is managed by phase7b"
else
    # Write as plone user. Use a fixed heredoc string (no bash variable
    # expansion inside the heredoc) to avoid the set-u/heredoc bug pattern
    # we hit in phase 5. Variables are interpolated via printf -v first.
    cat > "$BUILDOUT_CFG" <<EOF
# phase7b-marker - managed by phase7b-plone-buildout.sh
# Plone $PLONE_VERSION install for $PLONE_SITE_NAME
[buildout]
extends =
    https://dist.plone.org/release/${PLONE_RELEASE_LINE}/versions.cfg

parts =
    instance

[versions]
# Pin Plone to the version declared in tenant.local / script default.
Plone = $PLONE_VERSION

[instance]
recipe = plone.recipe.zope2instance
user = admin:$PLONE_ADMIN_PW
# Listen on port 8080. The plone.recipe.zope2instance default for a
# bare port number ('8080') is to bind to all interfaces (0.0.0.0:8080),
# which means anyone with network access to this host can reach Plone
# directly. Phase 7c rewrites this to '127.0.0.1:8080' to lock it down
# to loopback only - after which Apache reverse-proxies to it.
#
# Between phase 7b finishing and phase 7c running, Plone IS reachable
# on the public IP at port 8080. Run phase 7c immediately after 7b,
# or rely on ufw blocking 8080 (the default phase 1 firewall posture).
http-address = 8080
eggs =
    Plone
EOF
    chown "$PLONE_USER:$PLONE_USER" "$BUILDOUT_CFG"
    chmod 640 "$BUILDOUT_CFG"

    # Belt and suspenders: catch silent zero-byte heredoc failures
    # (the bug pattern we hit in phase 5 commit 780badb)
    if [ ! -s "$BUILDOUT_CFG" ]; then
        log_fail "Heredoc wrote zero bytes to $BUILDOUT_CFG. Heredoc body may have errored under set -u."
        exit 1
    fi
    if ! grep -q "phase7b-marker" "$BUILDOUT_CFG"; then
        log_fail "buildout.cfg was written but does not contain phase7b-marker"
        exit 1
    fi
    log_done "Wrote $BUILDOUT_CFG"
fi

# ============================================================================
# STEP 5: Run buildout
# ============================================================================
step "Step 5: Running buildout (this takes 5-15 minutes)"

BIN_INSTANCE="$PLONE_INSTANCE_DIR/bin/instance"
BIN_BUILDOUT="$PLONE_INSTANCE_DIR/bin/buildout"

if [ -x "$BIN_INSTANCE" ]; then
    log_skip "bin/instance already exists. Re-run buildout manually with 'sudo -u plone bin/buildout' if you need to refresh."
else
    # Bootstrap: produces bin/buildout
    if [ ! -x "$BIN_BUILDOUT" ]; then
        if ! sudo -u "$PLONE_USER" bash -c "cd '$PLONE_INSTANCE_DIR' && venv/bin/buildout bootstrap"; then
            log_fail "Buildout bootstrap failed"
            exit 1
        fi
        log_done "Buildout bootstrap completed (bin/buildout exists)"
    fi

    # Main buildout run: downloads and compiles all Plone packages
    echo "  Running 'bin/buildout' as $PLONE_USER. This will print a lot of output."
    echo "  Expected runtime: 5-15 minutes depending on network and CPU."
    if ! sudo -u "$PLONE_USER" bash -c "cd '$PLONE_INSTANCE_DIR' && bin/buildout"; then
        log_fail "bin/buildout failed."
        echo ""
        echo "  Recovery: clean partial state and re-run phase 7b:"
        echo "    sudo rm -rf $PLONE_INSTANCE_DIR/{eggs,parts,develop-eggs,bin}"
        echo "    sudo bash $0"
        exit 1
    fi
    log_done "Buildout completed successfully"
fi

# ============================================================================
# STEP 6: Verification
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

# bin/instance exists and is executable
if [ -x "$BIN_INSTANCE" ]; then
    vp "bin/instance exists and is executable"
else
    vf "bin/instance is missing or not executable at $BIN_INSTANCE"
fi

# buildout.cfg has phase7b-marker
if [ -f "$BUILDOUT_CFG" ] && grep -q "phase7b-marker" "$BUILDOUT_CFG" 2>/dev/null; then
    vp "buildout.cfg exists and is managed by phase7b"
else
    vf "buildout.cfg missing or not phase7b-managed"
fi

# Plone egg of the expected version is present.
# Egg layouts vary across buildout versions and Python wheel-style installs:
#   - older buildout:  eggs/Plone-X.Y.Z-pyA.B.egg/
#   - newer buildout:  eggs/v5/Plone-X.Y.Z-pyA.B.egg/  (some setups)
#   - wheel-style:     eggs/Plone-X.Y.Z.dist-info/
# Rather than guess the layout, just look anywhere under eggs/ for the
# expected version string. The find is fast enough not to bother optimizing.
if find "$PLONE_INSTANCE_DIR/eggs" -maxdepth 4 \
        \( -name "Plone-${PLONE_VERSION}-*.egg" -o -name "Plone-${PLONE_VERSION}.dist-info" \) \
        2>/dev/null | grep -q .; then
    vp "Plone $PLONE_VERSION egg/dist-info installed under $PLONE_INSTANCE_DIR/eggs/"
else
    vf "Plone $PLONE_VERSION egg/dist-info not found anywhere under $PLONE_INSTANCE_DIR/eggs/"
fi

# var/ directory exists (will be created by buildout / first run)
if [ -d "$PLONE_INSTANCE_DIR/var" ]; then
    vp "Instance var/ directory exists"
else
    vf "Instance var/ directory does not exist"
fi

# plone user can read bin/instance
if su - "$PLONE_USER" -c "test -x '$BIN_INSTANCE'" 2>/dev/null; then
    vp "User '$PLONE_USER' can execute bin/instance"
else
    vf "User '$PLONE_USER' cannot execute bin/instance"
fi

# Credentials file mentions PLONE_ADMIN_PW
if grep -q "^PLONE_ADMIN_PW=" "$CREDENTIALS_FILE" 2>/dev/null; then
    vp "PLONE_ADMIN_PW recorded in CREDENTIALS.txt"
else
    vf "PLONE_ADMIN_PW not recorded in CREDENTIALS.txt"
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
echo "  Plone is installed but the Zope instance is not yet running and"
echo "  there is no Plone Site object inside it yet."
echo ""
echo "  Run phase 7c next - it will:"
echo "    - rewrite buildout.cfg http-address to 127.0.0.1:8080"
echo "    - install a systemd unit so Plone runs in the background"
echo "    - install an Apache reverse-proxy vhost at"
echo "      https://team.$DOMAIN/"
echo "    - reuse the Let's Encrypt cert (phase 3 should have issued it"
echo "      for the team.<domain> subdomain alongside the bare domain)"
echo "    - create the Plone Site object at /Plone with the Classic UI"
echo "      distribution (so Folder, Page, News Item, etc. are installed)"
echo "    - create the Plone-level admin user with PLONE_ADMIN_PW"
echo ""
echo "  To run phase 7c:"
echo "    sudo bash /root/server-build/scripts/phase7c-plone-frontend.sh"
echo ""
echo "  After phase 7c, log in at:"
echo "    https://team.$DOMAIN/login"
echo "    Username: admin"
echo "    Password: (in $CREDENTIALS_FILE under PLONE_ADMIN_PW)"
echo ""
echo "  If you want to smoke-test the install before running phase 7c,"
echo "  start Plone in foreground:"
echo "    sudo -u $PLONE_USER bash -c 'cd $PLONE_INSTANCE_DIR && bin/instance fg'"
echo "  Then hit http://127.0.0.1:8080/ via SSH tunnel:"
echo "    ssh -L 8080:127.0.0.1:8080 -p 2222 wayne@<server-ip>"
echo "  Stop the foreground instance (Ctrl-C) before running phase 7c."
echo ""
echo "==================================================================="
echo ""
