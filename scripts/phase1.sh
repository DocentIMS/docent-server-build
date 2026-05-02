#!/bin/bash
#
# phase1.sh - Phase 1: Base OS hardening and prep for docenttemplate
#
# Idempotent. Safe to re-run. Each step checks current state before acting.
# Produces a summary report at the end, including generated passwords.
#
# Run as root: bash phase1.sh
#

set -u  # error on undefined variable; we don't use -e because we want to handle errors per-step

# ============================================================================
# CONFIGURATION
# ============================================================================
ADMIN_USER="wayne"
STAFF_USER="espen"
SSH_PORT="2222"
HOSTNAME_FQDN="docenttemplate.com"
HOSTNAME_SHORT="docenttemplate"
TIMEZONE="America/Los_Angeles"

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

# ============================================================================
# REPORT TRACKING
# ============================================================================
REPORT=()
ADMIN_PW=""
STAFF_PW=""

log_done()    { REPORT+=("[DONE]    $1"); echo "  ✓ $1"; }
log_skip()    { REPORT+=("[SKIPPED] $1 (already done)"); echo "  - $1 (already done)"; }
log_warn()    { REPORT+=("[WARN]    $1"); echo "  ! $1"; }
log_fail()    { REPORT+=("[FAIL]    $1"); echo "  ✗ $1"; }

step() { echo ""; echo "=== $1 ==="; }

# ============================================================================
# SAFETY CHECK
# ============================================================================
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

echo "==================================================================="
echo "  Phase 1 - Base OS hardening for $HOSTNAME_FQDN"
echo "  $(date)"
echo "==================================================================="

# ============================================================================
# STEP 1: OS updates
# ============================================================================
step "Step 1: Updating OS packages"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep -c upgradable || true)
if [ "$UPGRADABLE" -gt 1 ]; then
    apt-get upgrade -y -qq
    log_done "Applied $((UPGRADABLE - 1)) package updates"
else
    log_skip "OS packages already up to date"
fi

# ============================================================================
# STEP 2: Set hostname
# ============================================================================
step "Step 2: Setting hostname to $HOSTNAME_SHORT"

CURRENT_HOSTNAME=$(hostname)
if [ "$CURRENT_HOSTNAME" = "$HOSTNAME_SHORT" ]; then
    log_skip "Hostname already set to $HOSTNAME_SHORT"
else
    hostnamectl set-hostname "$HOSTNAME_SHORT"
    log_done "Hostname set to $HOSTNAME_SHORT (was: $CURRENT_HOSTNAME)"
fi

# /etc/hosts entry
if grep -qE "^127\.0\.1\.1\s+$HOSTNAME_FQDN" /etc/hosts; then
    log_skip "/etc/hosts already has $HOSTNAME_FQDN entry"
else
    # remove any old 127.0.1.1 line, then add the correct one
    sed -i '/^127\.0\.1\.1/d' /etc/hosts
    echo "127.0.1.1   $HOSTNAME_FQDN $HOSTNAME_SHORT" >> /etc/hosts
    log_done "/etc/hosts updated with $HOSTNAME_FQDN"
fi

# ============================================================================
# STEP 3: Timezone
# ============================================================================
step "Step 3: Setting timezone to $TIMEZONE"

CURRENT_TZ=$(timedatectl show --property=Timezone --value)
if [ "$CURRENT_TZ" = "$TIMEZONE" ]; then
    log_skip "Timezone already set to $TIMEZONE"
else
    timedatectl set-timezone "$TIMEZONE"
    log_done "Timezone set to $TIMEZONE (was: $CURRENT_TZ)"
fi

# ============================================================================
# STEP 4: Install basic admin tools
# ============================================================================
step "Step 4: Installing basic admin tools"

TOOLS="vim htop curl wget git net-tools dnsutils ufw fail2ban unattended-upgrades"
MISSING=""
for pkg in $TOOLS; do
    if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        MISSING="$MISSING $pkg"
    fi
done

if [ -z "$MISSING" ]; then
    log_skip "All admin tools already installed"
else
    apt-get install -y -qq $MISSING
    log_done "Installed packages:$MISSING"
fi

# ============================================================================
# STEP 5: Create admin user (wayne)
# ============================================================================
step "Step 5: Creating admin user '$ADMIN_USER'"

if id "$ADMIN_USER" &>/dev/null; then
    log_skip "User $ADMIN_USER already exists"
else
    useradd -m -s /bin/bash -G sudo "$ADMIN_USER"
    ADMIN_PW=$(openssl rand -base64 18 | tr -d '/+=' | head -c 22)
    echo "$ADMIN_USER:$ADMIN_PW" | chpasswd
    log_done "Created user $ADMIN_USER (member of sudo group)"
fi

# ============================================================================
# STEP 6: Create staff user (espen)
# ============================================================================
step "Step 6: Creating staff user '$STAFF_USER'"

if id "$STAFF_USER" &>/dev/null; then
    log_skip "User $STAFF_USER already exists"
else
    useradd -m -s /bin/bash -G sudo "$STAFF_USER"
    STAFF_PW=$(openssl rand -base64 18 | tr -d '/+=' | head -c 22)
    echo "$STAFF_USER:$STAFF_PW" | chpasswd
    log_done "Created user $STAFF_USER (member of sudo group)"
fi

# ============================================================================
# STEP 7: SSH hardening - move port, disable root login
# ============================================================================
step "Step 7: SSH hardening"

SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_BACKUP="/etc/ssh/sshd_config.phase1.bak"

# Backup once
if [ ! -f "$SSHD_BACKUP" ]; then
    cp "$SSHD_CONFIG" "$SSHD_BACKUP"
    log_done "Backed up $SSHD_CONFIG to $SSHD_BACKUP"
fi

# Set port
if grep -qE "^Port $SSH_PORT$" "$SSHD_CONFIG"; then
    log_skip "SSH already configured for port $SSH_PORT"
else
    sed -i '/^Port /d' "$SSHD_CONFIG"
    sed -i '/^#Port /d' "$SSHD_CONFIG"
    echo "Port $SSH_PORT" >> "$SSHD_CONFIG"
    log_done "SSH port set to $SSH_PORT"
fi

# Disable root login
if grep -qE "^PermitRootLogin no$" "$SSHD_CONFIG"; then
    log_skip "Root SSH login already disabled"
else
    sed -i '/^PermitRootLogin /d' "$SSHD_CONFIG"
    sed -i '/^#PermitRootLogin /d' "$SSHD_CONFIG"
    echo "PermitRootLogin no" >> "$SSHD_CONFIG"
    log_done "Root SSH login disabled"
fi

# Ubuntu 24.04+ uses /etc/ssh/sshd_config.d/ snippets - check there too
SSHD_SNIPPET_DIR="/etc/ssh/sshd_config.d"
if [ -d "$SSHD_SNIPPET_DIR" ]; then
    SNIPPET="$SSHD_SNIPPET_DIR/00-phase1.conf"
    cat > "$SNIPPET" <<EOF
Port $SSH_PORT
PermitRootLogin no
EOF
    chmod 644 "$SNIPPET"
    log_done "SSH config snippet written to $SNIPPET"
fi

# Validate config before restarting
if sshd -t 2>/dev/null; then
    log_done "sshd config validated"
else
    log_fail "sshd config has errors - NOT restarting SSH. Check manually."
fi

# ============================================================================
# STEP 8: Configure firewall (ufw)
# ============================================================================
step "Step 8: Configuring firewall (ufw)"

# Set defaults
ufw default deny incoming >/dev/null 2>&1
ufw default allow outgoing >/dev/null 2>&1

# Allow new SSH port BEFORE enabling firewall, so we don't lock out
if ufw status | grep -qE "^${SSH_PORT}/tcp\s+ALLOW"; then
    log_skip "Firewall already allows port $SSH_PORT/tcp"
else
    ufw allow ${SSH_PORT}/tcp >/dev/null 2>&1
    log_done "Firewall: allow $SSH_PORT/tcp (SSH)"
fi

# Allow standard web ports for later phases
for PORT in 80 443; do
    if ufw status | grep -qE "^${PORT}/tcp\s+ALLOW"; then
        log_skip "Firewall already allows port $PORT/tcp"
    else
        ufw allow ${PORT}/tcp >/dev/null 2>&1
        log_done "Firewall: allow $PORT/tcp"
    fi
done

# Clean up: if port 22 was allowed by a previous run, remove it
# (sshd does not listen on 22 - we use $SSH_PORT - so this rule is unnecessary)
if ufw status | grep -qE "^22/tcp\s+ALLOW"; then
    ufw delete allow 22/tcp >/dev/null 2>&1
    log_done "Firewall: removed leftover allow 22/tcp rule (no service listens there)"
fi

# Enable firewall if not active
if ufw status | grep -q "Status: active"; then
    log_skip "Firewall already active"
else
    echo "y" | ufw enable >/dev/null 2>&1
    log_done "Firewall enabled"
fi

# ============================================================================
# STEP 9: Configure fail2ban
# ============================================================================
step "Step 9: Configuring fail2ban"

JAIL_LOCAL="/etc/fail2ban/jail.local"
if [ -f "$JAIL_LOCAL" ] && grep -q "phase1-marker" "$JAIL_LOCAL"; then
    log_skip "fail2ban jail.local already configured"
else
    cat > "$JAIL_LOCAL" <<EOF
# phase1-marker - managed by phase1.sh
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 3

[sshd]
enabled = true
port    = $SSH_PORT
EOF
    log_done "fail2ban configured: 3 attempts, 1-hour ban, watching port $SSH_PORT"
fi

systemctl enable fail2ban >/dev/null 2>&1
systemctl restart fail2ban
if systemctl is-active --quiet fail2ban; then
    log_done "fail2ban running"
else
    log_fail "fail2ban failed to start"
fi

# ============================================================================
# STEP 10: Verify unattended-upgrades
# ============================================================================
step "Step 10: Verifying unattended-upgrades"

if systemctl is-enabled --quiet unattended-upgrades 2>/dev/null; then
    log_skip "unattended-upgrades already enabled"
else
    systemctl enable unattended-upgrades >/dev/null 2>&1
    log_done "unattended-upgrades enabled"
fi

if systemctl is-active --quiet unattended-upgrades; then
    log_done "unattended-upgrades running"
else
    systemctl start unattended-upgrades
    log_done "unattended-upgrades started"
fi

# ============================================================================
# STEP 11: Restart SSH (carefully)
# ============================================================================
step "Step 11: Restarting SSH"

# DO NOT restart if config is bad
if sshd -t 2>/dev/null; then
    systemctl restart ssh
    log_done "SSH restarted - now listening on port $SSH_PORT"
else
    log_fail "SSH config invalid, NOT restarted. Check $SSHD_CONFIG and $SSHD_SNIPPET_DIR"
fi

# ============================================================================
# REPORT
# ============================================================================
echo ""
echo "==================================================================="
echo "  PHASE 1 COMPLETE - SUMMARY REPORT"
echo "==================================================================="
echo ""
for line in "${REPORT[@]}"; do
    echo "  $line"
done

echo ""
echo "==================================================================="
echo "  CREDENTIALS (save these to your password manager NOW)"
echo "==================================================================="
if [ -n "$ADMIN_PW" ]; then
    echo "  Admin user: $ADMIN_USER"
    echo "  Password:   $ADMIN_PW"
    echo ""
fi
if [ -n "$STAFF_PW" ]; then
    echo "  Staff user: $STAFF_USER"
    echo "  Password:   $STAFF_PW"
    echo ""
fi
if [ -z "$ADMIN_PW" ] && [ -z "$STAFF_PW" ]; then
    echo "  (No new passwords generated - users already existed)"
    echo ""
fi

echo "==================================================================="
echo "  AUTOMATED VERIFICATION"
echo "==================================================================="
echo ""

VERIFY_PASS=0
VERIFY_FAIL=0

verify() {
    local description="$1"
    local expected="$2"
    local actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  [PASS] $description"
        VERIFY_PASS=$((VERIFY_PASS + 1))
    else
        echo "  [FAIL] $description"
        echo "         expected: $expected"
        echo "         actual:   $actual"
        VERIFY_FAIL=$((VERIFY_FAIL + 1))
    fi
}

verify_contains() {
    local description="$1"
    local haystack="$2"
    local needle="$3"
    if echo "$haystack" | grep -q "$needle"; then
        echo "  [PASS] $description"
        VERIFY_PASS=$((VERIFY_PASS + 1))
    else
        echo "  [FAIL] $description"
        echo "         looking for: $needle"
        echo "         in:          $haystack"
        VERIFY_FAIL=$((VERIFY_FAIL + 1))
    fi
}

verify_not_contains() {
    local description="$1"
    local haystack="$2"
    local needle="$3"
    if echo "$haystack" | grep -q "$needle"; then
        echo "  [FAIL] $description"
        echo "         unexpectedly found: $needle"
        VERIFY_FAIL=$((VERIFY_FAIL + 1))
    else
        echo "  [PASS] $description"
        VERIFY_PASS=$((VERIFY_PASS + 1))
    fi
}

# Hostname
verify "Hostname is $HOSTNAME_SHORT" \
    "$HOSTNAME_SHORT" \
    "$(hostname)"

# /etc/hosts
verify_contains "/etc/hosts has FQDN entry" \
    "$(cat /etc/hosts)" \
    "$HOSTNAME_FQDN"

# Timezone
verify "Timezone is $TIMEZONE" \
    "$TIMEZONE" \
    "$(timedatectl show --property=Timezone --value)"

# Admin user exists
if id "$ADMIN_USER" &>/dev/null; then
    echo "  [PASS] Admin user '$ADMIN_USER' exists"
    VERIFY_PASS=$((VERIFY_PASS + 1))
    # Admin user in sudo group
    verify_contains "Admin user '$ADMIN_USER' is in sudo group" \
        "$(id "$ADMIN_USER")" \
        "sudo"
else
    echo "  [FAIL] Admin user '$ADMIN_USER' does not exist"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# Staff user exists
if id "$STAFF_USER" &>/dev/null; then
    echo "  [PASS] Staff user '$STAFF_USER' exists"
    VERIFY_PASS=$((VERIFY_PASS + 1))
    verify_contains "Staff user '$STAFF_USER' is in sudo group" \
        "$(id "$STAFF_USER")" \
        "sudo"
else
    echo "  [FAIL] Staff user '$STAFF_USER' does not exist"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# Listening on the right SSH port
LISTENING=$(ss -tlnp 2>/dev/null)
verify_contains "SSH listening on port $SSH_PORT" \
    "$LISTENING" \
    ":$SSH_PORT "

# NOT listening on port 22
verify_not_contains "SSH NOT listening on port 22" \
    "$LISTENING" \
    ":22 "

# SSH config: Port set
SSHD_EFFECTIVE=$(sshd -T 2>/dev/null)
verify_contains "sshd effective config: Port $SSH_PORT" \
    "$SSHD_EFFECTIVE" \
    "^port $SSH_PORT$"

# SSH config: PermitRootLogin no
verify_contains "sshd effective config: PermitRootLogin no" \
    "$SSHD_EFFECTIVE" \
    "^permitrootlogin no$"

# Firewall active
UFW_STATUS=$(ufw status 2>/dev/null)
verify_contains "Firewall is active" \
    "$UFW_STATUS" \
    "Status: active"

# Firewall has SSH port
verify_contains "Firewall allows port $SSH_PORT/tcp" \
    "$UFW_STATUS" \
    "$SSH_PORT/tcp"

# Firewall has 80, 443
verify_contains "Firewall allows 80/tcp" "$UFW_STATUS" "80/tcp"
verify_contains "Firewall allows 443/tcp" "$UFW_STATUS" "443/tcp"

# Firewall does NOT allow port 22 (we use $SSH_PORT)
verify_not_contains "Firewall does NOT allow port 22/tcp" \
    "$UFW_STATUS" \
    "^22/tcp"

# fail2ban running
if systemctl is-active --quiet fail2ban; then
    echo "  [PASS] fail2ban service is active"
    VERIFY_PASS=$((VERIFY_PASS + 1))
else
    echo "  [FAIL] fail2ban service is not active"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# fail2ban watching sshd
if fail2ban-client status sshd &>/dev/null; then
    echo "  [PASS] fail2ban sshd jail is active"
    VERIFY_PASS=$((VERIFY_PASS + 1))
else
    echo "  [FAIL] fail2ban sshd jail is not active"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# ssh service active
if systemctl is-active --quiet ssh; then
    echo "  [PASS] ssh service is active"
    VERIFY_PASS=$((VERIFY_PASS + 1))
else
    echo "  [FAIL] ssh service is not active"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# unattended-upgrades enabled
if systemctl is-enabled --quiet unattended-upgrades 2>/dev/null; then
    echo "  [PASS] unattended-upgrades is enabled"
    VERIFY_PASS=$((VERIFY_PASS + 1))
else
    echo "  [FAIL] unattended-upgrades is not enabled"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# Local SSH port responds
if timeout 2 bash -c "</dev/tcp/127.0.0.1/$SSH_PORT" 2>/dev/null; then
    echo "  [PASS] SSH port $SSH_PORT responds locally"
    VERIFY_PASS=$((VERIFY_PASS + 1))
else
    echo "  [FAIL] SSH port $SSH_PORT does not respond locally"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# Port 22 NOT responding
if timeout 2 bash -c "</dev/tcp/127.0.0.1/22" 2>/dev/null; then
    echo "  [FAIL] Port 22 still responds (should be closed)"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
else
    echo "  [PASS] Port 22 not responding (correctly closed)"
    VERIFY_PASS=$((VERIFY_PASS + 1))
fi

echo ""
echo "  Verification: $VERIFY_PASS passed, $VERIFY_FAIL failed"
echo ""

if [ "$VERIFY_FAIL" -gt 0 ]; then
    echo "  *** $VERIFY_FAIL CHECK(S) FAILED. Review failures above before proceeding. ***"
    echo ""
fi

echo "==================================================================="
echo "  MANUAL VERIFICATION STEPS (cannot be automated)"
echo "==================================================================="
cat <<'EOF'

  These steps require an external connection and CANNOT be checked
  by this script. Do them from your Windows machine while keeping
  this session open as a safety net.

  1. Open a NEW terminal window and SSH in as the admin user:
       ssh -p 2222 wayne@66.55.78.148
     This proves the new port and user account work end-to-end.

  2. Verify root SSH is rejected (do this from another new session):
       ssh -p 2222 root@66.55.78.148
     This should fail with "Permission denied".

  3. Save the passwords printed above to your password manager.

  4. Clear your terminal scrollback after saving passwords:
       clear && history -c

  Once these four checks are done, Phase 1 is fully complete and you
  can proceed to Phase 2 (Web server + TLS foundation).

EOF
echo "==================================================================="

# Exit with non-zero status if any automated check failed
if [ "$VERIFY_FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
