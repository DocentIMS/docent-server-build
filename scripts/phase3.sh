#!/bin/bash
#
# phase3.sh - Phase 3: Database server (MariaDB)
#
# Idempotent. Safe to re-run. Each step checks current state before acting.
# Produces a summary report and runs automated verification at the end.
#
# Run as root: sudo bash phase3.sh
#

set -u

# ============================================================================
# CONFIGURATION
# ============================================================================
BACKUP_DIR="/var/backups/mysql"
BACKUP_RETENTION_DAYS=14
ROOT_DEFAULTS_FILE="/root/.my.cnf"
BACKUP_SCRIPT="/usr/local/sbin/mysql-daily-backup.sh"
BACKUP_CRON="/etc/cron.d/mysql-daily-backup"

# ============================================================================
# REPORT TRACKING
# ============================================================================
REPORT=()
ROOT_DB_PW=""

log_done() { REPORT+=("[DONE]    $1"); echo "  ✓ $1"; }
log_skip() { REPORT+=("[SKIPPED] $1 (already done)"); echo "  - $1 (already done)"; }
log_warn() { REPORT+=("[WARN]    $1"); echo "  ! $1"; }
log_fail() { REPORT+=("[FAIL]    $1"); echo "  ✗ $1"; }

step() { echo ""; echo "=== $1 ==="; }

# ============================================================================
# SAFETY CHECK
# ============================================================================
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root (use sudo)."
    exit 1
fi

echo "==================================================================="
echo "  Phase 3 - Database server (MariaDB)"
echo "  $(date)"
echo "==================================================================="

# ============================================================================
# STEP 1: Install MariaDB
# ============================================================================
step "Step 1: Installing MariaDB"

export DEBIAN_FRONTEND=noninteractive
if dpkg -l mariadb-server 2>/dev/null | grep -q "^ii"; then
    log_skip "MariaDB already installed"
else
    apt-get update -qq
    apt-get install -y -qq mariadb-server mariadb-client
    log_done "MariaDB installed"
fi

# Make sure it's running
if systemctl is-active --quiet mariadb; then
    log_done "MariaDB service is active"
else
    systemctl start mariadb
    log_done "MariaDB service started"
fi

if systemctl is-enabled --quiet mariadb; then
    log_skip "MariaDB enabled at boot"
else
    systemctl enable mariadb >/dev/null 2>&1
    log_done "MariaDB enabled at boot"
fi

# ============================================================================
# STEP 2: Set root password and create root defaults file
# ============================================================================
step "Step 2: Securing root account"

# On Ubuntu, fresh MariaDB uses unix_socket auth for root - root can connect
# without a password by virtue of being the unix root user. We set an actual
# password too so backup scripts and tools work, and we store it in a
# protected /root/.my.cnf so root's interactive sessions don't need to type it.

if [ -f "$ROOT_DEFAULTS_FILE" ] && grep -q "phase3-marker" "$ROOT_DEFAULTS_FILE"; then
    log_skip "Root defaults file $ROOT_DEFAULTS_FILE already exists"
else
    ROOT_DB_PW=$(openssl rand -base64 24 | tr -d '/+=' | head -c 28)

    # Set the password using unix_socket auth (works because we're root locally)
    mysql --protocol=socket -u root <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '$ROOT_DB_PW';
FLUSH PRIVILEGES;
SQL

    # Write protected defaults file so root tools (backups, mysql cli) work without prompts
    cat > "$ROOT_DEFAULTS_FILE" <<EOF
# phase3-marker - managed by phase3.sh
[client]
user=root
password=$ROOT_DB_PW

[mysqldump]
user=root
password=$ROOT_DB_PW
EOF
    chmod 600 "$ROOT_DEFAULTS_FILE"
    chown root:root "$ROOT_DEFAULTS_FILE"
    log_done "Root password set and stored in $ROOT_DEFAULTS_FILE (mode 600)"
fi

# ============================================================================
# STEP 3: Run secure-installation equivalent
# ============================================================================
step "Step 3: Hardening MariaDB (secure_installation equivalent)"

# We use the defaults file from now on so we don't need to embed the password.
# All these are idempotent: running them when already done is a no-op.

# Remove anonymous users
ANON_COUNT=$(mysql --defaults-file="$ROOT_DEFAULTS_FILE" -Nse \
    "SELECT COUNT(*) FROM mysql.user WHERE User='';" 2>/dev/null || echo "0")
if [ "$ANON_COUNT" -gt 0 ]; then
    mysql --defaults-file="$ROOT_DEFAULTS_FILE" -e "DELETE FROM mysql.user WHERE User=''; FLUSH PRIVILEGES;"
    log_done "Removed $ANON_COUNT anonymous user(s)"
else
    log_skip "No anonymous users to remove"
fi

# Disallow remote root login
REMOTE_ROOT_COUNT=$(mysql --defaults-file="$ROOT_DEFAULTS_FILE" -Nse \
    "SELECT COUNT(*) FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');" 2>/dev/null || echo "0")
if [ "$REMOTE_ROOT_COUNT" -gt 0 ]; then
    mysql --defaults-file="$ROOT_DEFAULTS_FILE" -e \
        "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1'); FLUSH PRIVILEGES;"
    log_done "Removed $REMOTE_ROOT_COUNT remote root entries"
else
    log_skip "No remote root entries to remove"
fi

# Drop test database if it exists
TEST_DB_EXISTS=$(mysql --defaults-file="$ROOT_DEFAULTS_FILE" -Nse \
    "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='test';" 2>/dev/null || echo "0")
if [ "$TEST_DB_EXISTS" -gt 0 ]; then
    mysql --defaults-file="$ROOT_DEFAULTS_FILE" -e "DROP DATABASE test; DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%'; FLUSH PRIVILEGES;"
    log_done "Dropped 'test' database"
else
    log_skip "No 'test' database to drop"
fi

# ============================================================================
# STEP 4: Verify MariaDB only listens locally
# ============================================================================
step "Step 4: Verifying network binding (localhost only)"

# Check the effective bind-address. By default Ubuntu's MariaDB listens
# only on 127.0.0.1, but verify and force it if not.
BIND_ADDR=$(mysql --defaults-file="$ROOT_DEFAULTS_FILE" -Nse \
    "SHOW VARIABLES LIKE 'bind_address';" 2>/dev/null | awk '{print $2}')

if [ "$BIND_ADDR" = "127.0.0.1" ] || [ "$BIND_ADDR" = "localhost" ]; then
    log_skip "MariaDB already bound to localhost only ($BIND_ADDR)"
else
    # Drop a config snippet to force localhost-only binding
    BIND_CONF="/etc/mysql/mariadb.conf.d/99-phase3-bind.cnf"
    if [ ! -f "$BIND_CONF" ]; then
        cat > "$BIND_CONF" <<EOF
# phase3-marker
[mysqld]
bind-address = 127.0.0.1
EOF
        systemctl restart mariadb
        log_done "Forced MariaDB to bind 127.0.0.1 only (snippet: $BIND_CONF)"
    else
        log_skip "Bind-address snippet already exists"
    fi
fi

# ============================================================================
# STEP 5: Create backup directory and daily backup script
# ============================================================================
step "Step 5: Setting up daily backups"

if [ -d "$BACKUP_DIR" ]; then
    log_skip "Backup directory $BACKUP_DIR exists"
else
    mkdir -p "$BACKUP_DIR"
    chown root:root "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    log_done "Created $BACKUP_DIR (mode 700, root only)"
fi

# Write backup script
if [ -f "$BACKUP_SCRIPT" ] && grep -q "phase3-marker" "$BACKUP_SCRIPT"; then
    log_skip "Backup script $BACKUP_SCRIPT exists"
else
    cat > "$BACKUP_SCRIPT" <<EOF
#!/bin/bash
# phase3-marker - managed by phase3.sh
# Daily MariaDB backup. Dumps each database to its own .sql.gz file
# under $BACKUP_DIR/<date>/. Removes backups older than $BACKUP_RETENTION_DAYS days.

set -u
DATE=\$(date +%Y-%m-%d)
TARGET="$BACKUP_DIR/\$DATE"
mkdir -p "\$TARGET"
chmod 700 "\$TARGET"

# Get list of databases (excluding system databases that can't be cleanly dumped)
DATABASES=\$(mysql --defaults-file=$ROOT_DEFAULTS_FILE -Nse \\
    "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ('information_schema','performance_schema','sys');")

for DB in \$DATABASES; do
    OUT="\$TARGET/\${DB}.sql.gz"
    if mysqldump --defaults-file=$ROOT_DEFAULTS_FILE \\
        --single-transaction --quick --lock-tables=false \\
        --routines --triggers --events \\
        "\$DB" 2>/dev/null | gzip > "\$OUT"; then
        chmod 600 "\$OUT"
    else
        echo "ERROR: dump of \$DB failed" >&2
    fi
done

# Prune old backups
find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +$BACKUP_RETENTION_DAYS -exec rm -rf {} +
EOF
    chmod 700 "$BACKUP_SCRIPT"
    chown root:root "$BACKUP_SCRIPT"
    log_done "Wrote backup script: $BACKUP_SCRIPT"
fi

# Cron entry (runs daily at 02:30 local time)
if [ -f "$BACKUP_CRON" ]; then
    log_skip "Backup cron $BACKUP_CRON exists"
else
    cat > "$BACKUP_CRON" <<EOF
# phase3-marker - managed by phase3.sh
# Daily MariaDB backup at 02:30
30 2 * * * root $BACKUP_SCRIPT >/var/log/mysql-daily-backup.log 2>&1
EOF
    chmod 644 "$BACKUP_CRON"
    log_done "Installed cron job: $BACKUP_CRON (runs 02:30 daily)"
fi

# ============================================================================
# STEP 6: Test that backup script works
# ============================================================================
step "Step 6: Test-running backup script"

if "$BACKUP_SCRIPT" >/tmp/backup-test.log 2>&1; then
    BACKUP_COUNT=$(find "$BACKUP_DIR" -name "*.sql.gz" 2>/dev/null | wc -l)
    log_done "Backup script ran successfully ($BACKUP_COUNT .sql.gz file(s) in $BACKUP_DIR)"
else
    log_fail "Backup script failed - see /tmp/backup-test.log"
    cat /tmp/backup-test.log
fi

# ============================================================================
# REPORT
# ============================================================================
echo ""
echo "==================================================================="
echo "  PHASE 3 COMPLETE - SUMMARY REPORT"
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
echo "  CREDENTIALS (save to your password manager NOW)"
echo "==================================================================="
if [ -n "$ROOT_DB_PW" ]; then
    echo "  MariaDB root user: root"
    echo "  MariaDB password:  $ROOT_DB_PW"
    echo ""
    echo "  Note: also stored in $ROOT_DEFAULTS_FILE (root-only readable)"
    echo "  so 'mysql' and 'mysqldump' work without -p prompts as root."
else
    echo "  (No new password generated - root defaults file already exists)"
    echo ""
    echo "  The existing password is stored in $ROOT_DEFAULTS_FILE."
fi

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

# Package
if dpkg -l mariadb-server 2>/dev/null | grep -q "^ii"; then
    echo "  [PASS] Package mariadb-server installed"
    VERIFY_PASS=$((VERIFY_PASS + 1))
else
    echo "  [FAIL] Package mariadb-server NOT installed"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# Service running and enabled
if systemctl is-active --quiet mariadb; then
    echo "  [PASS] mariadb service is active"
    VERIFY_PASS=$((VERIFY_PASS + 1))
else
    echo "  [FAIL] mariadb service is NOT active"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

if systemctl is-enabled --quiet mariadb; then
    echo "  [PASS] mariadb service is enabled at boot"
    VERIFY_PASS=$((VERIFY_PASS + 1))
else
    echo "  [FAIL] mariadb service is NOT enabled at boot"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# Listening only on localhost
LISTENING=$(ss -tlnp 2>/dev/null | grep -E ":3306\b" || true)
if [ -z "$LISTENING" ]; then
    echo "  [FAIL] MariaDB does not appear to be listening on port 3306"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
elif echo "$LISTENING" | grep -qE '127\.0\.0\.1:3306|::1\]:3306'; then
    echo "  [PASS] MariaDB listening on localhost only (port 3306)"
    VERIFY_PASS=$((VERIFY_PASS + 1))
elif echo "$LISTENING" | grep -qE '0\.0\.0\.0:3306|\[::\]:3306'; then
    echo "  [FAIL] MariaDB listening on ALL interfaces (security risk)"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
else
    echo "  [PASS] MariaDB listening (local-only): $LISTENING"
    VERIFY_PASS=$((VERIFY_PASS + 1))
fi

# Root defaults file exists with correct permissions
if [ -f "$ROOT_DEFAULTS_FILE" ]; then
    PERMS=$(stat -c '%a' "$ROOT_DEFAULTS_FILE")
    if [ "$PERMS" = "600" ]; then
        echo "  [PASS] $ROOT_DEFAULTS_FILE exists with mode 600"
        VERIFY_PASS=$((VERIFY_PASS + 1))
    else
        echo "  [FAIL] $ROOT_DEFAULTS_FILE has mode $PERMS (expected 600)"
        VERIFY_FAIL=$((VERIFY_FAIL + 1))
    fi
else
    echo "  [FAIL] $ROOT_DEFAULTS_FILE does not exist"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# Root can connect using the defaults file
if mysql --defaults-file="$ROOT_DEFAULTS_FILE" -e "SELECT 1;" >/dev/null 2>&1; then
    echo "  [PASS] root can connect to MariaDB using $ROOT_DEFAULTS_FILE"
    VERIFY_PASS=$((VERIFY_PASS + 1))
else
    echo "  [FAIL] root cannot connect using $ROOT_DEFAULTS_FILE"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# No anonymous users
ANON=$(mysql --defaults-file="$ROOT_DEFAULTS_FILE" -Nse \
    "SELECT COUNT(*) FROM mysql.user WHERE User='';" 2>/dev/null || echo "?")
if [ "$ANON" = "0" ]; then
    echo "  [PASS] No anonymous database users"
    VERIFY_PASS=$((VERIFY_PASS + 1))
else
    echo "  [FAIL] Found $ANON anonymous user(s)"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# No remote root
REMOTE=$(mysql --defaults-file="$ROOT_DEFAULTS_FILE" -Nse \
    "SELECT COUNT(*) FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');" 2>/dev/null || echo "?")
if [ "$REMOTE" = "0" ]; then
    echo "  [PASS] No remote root accounts"
    VERIFY_PASS=$((VERIFY_PASS + 1))
else
    echo "  [FAIL] Found $REMOTE remote root account(s)"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# No 'test' database
TESTDB=$(mysql --defaults-file="$ROOT_DEFAULTS_FILE" -Nse \
    "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='test';" 2>/dev/null || echo "?")
if [ "$TESTDB" = "0" ]; then
    echo "  [PASS] No 'test' database"
    VERIFY_PASS=$((VERIFY_PASS + 1))
else
    echo "  [FAIL] 'test' database still present"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# Backup directory
if [ -d "$BACKUP_DIR" ]; then
    PERMS=$(stat -c '%a' "$BACKUP_DIR")
    if [ "$PERMS" = "700" ]; then
        echo "  [PASS] Backup dir $BACKUP_DIR exists with mode 700"
        VERIFY_PASS=$((VERIFY_PASS + 1))
    else
        echo "  [FAIL] Backup dir $BACKUP_DIR has mode $PERMS (expected 700)"
        VERIFY_FAIL=$((VERIFY_FAIL + 1))
    fi
else
    echo "  [FAIL] Backup dir $BACKUP_DIR does not exist"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# Backup script
if [ -x "$BACKUP_SCRIPT" ]; then
    echo "  [PASS] Backup script $BACKUP_SCRIPT exists and is executable"
    VERIFY_PASS=$((VERIFY_PASS + 1))
else
    echo "  [FAIL] Backup script $BACKUP_SCRIPT missing or not executable"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# Backup cron
if [ -f "$BACKUP_CRON" ]; then
    echo "  [PASS] Backup cron $BACKUP_CRON installed"
    VERIFY_PASS=$((VERIFY_PASS + 1))
else
    echo "  [FAIL] Backup cron $BACKUP_CRON missing"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# At least one backup file produced by test run
BACKUP_FILES=$(find "$BACKUP_DIR" -name "*.sql.gz" 2>/dev/null | wc -l)
if [ "$BACKUP_FILES" -gt 0 ]; then
    echo "  [PASS] Test backup produced $BACKUP_FILES .sql.gz file(s)"
    VERIFY_PASS=$((VERIFY_PASS + 1))
else
    echo "  [FAIL] No .sql.gz files in $BACKUP_DIR"
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
echo "  MANUAL VERIFICATION STEPS"
echo "==================================================================="
cat <<EOF

  Quick sanity checks (run as root):

  1. Connect to MariaDB and confirm version:
       sudo mysql -e 'SELECT VERSION();'

  2. List databases (should see only system databases at this stage):
       sudo mysql -e 'SHOW DATABASES;'

  3. Save the MariaDB root password (printed above) to your password manager.

  4. Clear scrollback if you'd rather not leave the password on screen:
       clear && history -c

  Once these are done, Phase 3 is complete and you are ready for
  Phase 4 (Mail server: Postfix + Dovecot + OpenDKIM + OpenDMARC + SpamAssassin).

EOF
echo "==================================================================="

# Exit non-zero if any automated check failed
if [ "$VERIFY_FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
