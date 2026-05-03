#!/bin/bash
#
# phase4.sh - Phase 4: Mail server (Postfix + Dovecot + OpenDKIM + OpenDMARC
#                                   + SpamAssassin, with virtual users in MariaDB)
#
# Idempotent. Safe to re-run. Each step checks current state before acting.
# Produces a summary report and runs automated verification at the end.
#
# Run as root: sudo bash phase4.sh
#

set -u

# ============================================================================
# CONFIGURATION
# ============================================================================
# Non-domain-dependent constants. These are the same regardless of tenant.
MAIL_DOMAIN="docenttemplate.com"      # default - overridden by tenant.local
MAIL_HOSTNAME="mail.docenttemplate.com"  # default - overridden by tenant.local
TEST_MAILBOX_LOCAL="test"             # default - tenant.local sets TEST_MAILBOX

VMAIL_USER="vmail"
VMAIL_UID=5000
VMAIL_GID=5000
VMAIL_HOME="/var/vmail"

MAIL_DB="mailserver"
MAIL_DB_USER="mailuser"
ROOT_DEFAULTS_FILE="/root/.my.cnf"

DKIM_SELECTOR="default"

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

# Domain-dependent paths and values. These MUST be computed AFTER sourcing
# tenant.local so they pick up the correct MAIL_DOMAIN/MAIL_HOSTNAME values.
# (If we set them before sourcing, bash evaluates the variables immediately
# and they keep the docenttemplate.com defaults even after tenant.local
# overrides MAIL_DOMAIN.)
TEST_MAILBOX="${TEST_MAILBOX_LOCAL}@${MAIL_DOMAIN}"
DKIM_KEY_DIR="/etc/opendkim/keys/${MAIL_DOMAIN}"
CERT_DIR="/etc/letsencrypt/live/${MAIL_DOMAIN}"

# ============================================================================
# REPORT TRACKING
# ============================================================================
REPORT=()
# DO NOT initialize MAIL_DB_PW or TEST_MAILBOX_PW here - they were already
# set by sourcing secrets.local above. Setting them to "" would wipe out
# the canonical values from CREDENTIALS.txt and force the script to
# generate new ones, breaking the canonical-credentials design.
DKIM_TXT_VALUE=""

log_done() { REPORT+=("[DONE]    $1"); echo "  ✓ $1"; }
log_skip() { REPORT+=("[SKIPPED] $1 (already done)"); echo "  - $1 (already done)"; }
log_warn() { REPORT+=("[WARN]    $1"); echo "  ! $1"; }
log_fail() { REPORT+=("[FAIL]    $1"); echo "  ✗ $1"; }

step() { echo ""; echo "=== $1 ==="; }

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

echo "==================================================================="
echo "  Phase 4 - Mail server for $MAIL_DOMAIN"
echo "  Hostname: $MAIL_HOSTNAME"
echo "  $(date)"
echo "==================================================================="

# ============================================================================
# STEP 1: Extend Let's Encrypt cert to cover mail hostname
# ============================================================================
step "Step 1: Extending TLS cert to include $MAIL_HOSTNAME"

if openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -ext subjectAltName 2>/dev/null | \
   grep -qE "DNS:${MAIL_HOSTNAME}([,[:space:]]|$)"; then
    log_skip "Cert already covers $MAIL_HOSTNAME"
else
    if ! dig @8.8.8.8 +short "$MAIL_HOSTNAME" 2>/dev/null | grep -qE '^[0-9]'; then
        log_fail "$MAIL_HOSTNAME does not resolve in public DNS. Add A record at IONOS first."
        echo "         Run: dig @8.8.8.8 +short $MAIL_HOSTNAME"
        echo "         Expected: ${SERVER_IP:-(set in tenant.local)}"
        exit 1
    fi

    # Detect the active webroot for $MAIL_DOMAIN. After Phase 6 (WordPress)
    # the active vhost serves /srv/www/$MAIL_DOMAIN/. Before Phase 6 it's
    # /srv/www/default/. We test by writing a marker file and curling it.
    WEBROOT=""
    for candidate in "/srv/www/$MAIL_DOMAIN" "/srv/www/default"; do
        if [ -d "$candidate" ]; then
            mkdir -p "$candidate/.well-known/acme-challenge"
            MARKER="phase4-webroot-test-$$"
            echo "$MARKER" > "$candidate/.well-known/acme-challenge/test"
            chmod 644 "$candidate/.well-known/acme-challenge/test"
            FETCHED=$(curl -sL --max-time 5 "http://$MAIL_DOMAIN/.well-known/acme-challenge/test" 2>/dev/null || true)
            rm -f "$candidate/.well-known/acme-challenge/test"
            if [ "$FETCHED" = "$MARKER" ]; then
                WEBROOT="$candidate"
                break
            fi
        fi
    done

    if [ -z "$WEBROOT" ]; then
        log_fail "Could not determine active webroot for $MAIL_DOMAIN. Check Apache vhost."
        exit 1
    fi
    echo "  (using webroot: $WEBROOT)"

    if certbot certonly \
        --webroot \
        --webroot-path "$WEBROOT" \
        --non-interactive \
        --agree-tos \
        --email "wglover@docentims.com" \
        --cert-name "$MAIL_DOMAIN" \
        --expand \
        -d "$MAIL_DOMAIN" \
        -d "www.$MAIL_DOMAIN" \
        -d "$MAIL_HOSTNAME" 2>&1 | tail -10; then
        log_done "Cert extended to cover $MAIL_HOSTNAME"
        systemctl reload apache2 2>/dev/null || true
    else
        log_fail "certbot expansion failed - see output above"
        exit 1
    fi
fi

# ============================================================================
# STEP 2: Install mail server packages
# ============================================================================
step "Step 2: Installing mail server packages"

export DEBIAN_FRONTEND=noninteractive

echo "postfix postfix/main_mailer_type select Internet Site" | debconf-set-selections
echo "postfix postfix/mailname string $MAIL_HOSTNAME" | debconf-set-selections

MAIL_PACKAGES=(
    postfix
    postfix-mysql
    dovecot-core
    dovecot-imapd
    dovecot-lmtpd
    dovecot-mysql
    dovecot-sieve
    dovecot-managesieved
    opendkim
    opendkim-tools
    opendmarc
    spamassassin
    spamc
    spamass-milter
    sasl2-bin
    libsasl2-modules
    bsd-mailx
)

MISSING=""
for pkg in "${MAIL_PACKAGES[@]}"; do
    if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        MISSING="$MISSING $pkg"
    fi
done

if [ -z "$MISSING" ]; then
    log_skip "All mail packages already installed"
else
    apt-get update -qq
    apt-get install -y -qq -o Dpkg::Use-Pty=0 $MISSING < /dev/null
    log_done "Installed:$MISSING"
fi

# ============================================================================
# STEP 3: Create vmail user and directory
# ============================================================================
step "Step 3: Creating vmail user and directory"

if id "$VMAIL_USER" &>/dev/null; then
    log_skip "User $VMAIL_USER already exists"
else
    groupadd -g $VMAIL_GID "$VMAIL_USER"
    useradd --system -u $VMAIL_UID -g $VMAIL_GID --home-dir "$VMAIL_HOME" \
        --shell /usr/sbin/nologin "$VMAIL_USER"
    log_done "Created vmail user (uid=$VMAIL_UID gid=$VMAIL_GID)"
fi

if [ -d "$VMAIL_HOME" ]; then
    CURRENT_OWNER=$(stat -c '%U:%G' "$VMAIL_HOME")
    if [ "$CURRENT_OWNER" = "$VMAIL_USER:$VMAIL_USER" ]; then
        log_skip "$VMAIL_HOME already owned by $VMAIL_USER:$VMAIL_USER"
    else
        chown -R "$VMAIL_USER:$VMAIL_USER" "$VMAIL_HOME"
        chmod 770 "$VMAIL_HOME"
        log_done "Set $VMAIL_HOME ownership to $VMAIL_USER:$VMAIL_USER mode 770"
    fi
else
    mkdir -p "$VMAIL_HOME"
    chown "$VMAIL_USER:$VMAIL_USER" "$VMAIL_HOME"
    chmod 770 "$VMAIL_HOME"
    log_done "Created $VMAIL_HOME (owner $VMAIL_USER, mode 770)"
fi

# ============================================================================
# STEP 4: Create mail database and schema
# ============================================================================
step "Step 4: Creating mail database and schema"

DB_EXISTS=$(mysql --defaults-file="$ROOT_DEFAULTS_FILE" -Nse \
    "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$MAIL_DB';" 2>/dev/null || echo "0")
if [ "$DB_EXISTS" -gt 0 ]; then
    log_skip "Database $MAIL_DB exists"
else
    mysql --defaults-file="$ROOT_DEFAULTS_FILE" -e \
        "CREATE DATABASE \`$MAIL_DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    log_done "Created database $MAIL_DB"
fi

USER_EXISTS=$(mysql --defaults-file="$ROOT_DEFAULTS_FILE" -Nse \
    "SELECT COUNT(*) FROM mysql.user WHERE User='$MAIL_DB_USER' AND Host='localhost';" 2>/dev/null || echo "0")
if [ "$USER_EXISTS" -gt 0 ]; then
    log_skip "DB user $MAIL_DB_USER exists"
    if [ -f /etc/postfix/mysql-virtual-mailbox-domains.cf ]; then
        MAIL_DB_PW=$(grep "^password" /etc/postfix/mysql-virtual-mailbox-domains.cf | cut -d= -f2- | tr -d ' ')
    fi
else
    # Use MAIL_DB_PW from secrets.local if available, otherwise generate.
    # When phase0 was used, MAIL_DB_PW is the password documented in
    # CREDENTIALS.txt - we MUST use it so CREDENTIALS.txt stays canonical.
    if [ -z "${MAIL_DB_PW:-}" ]; then
        MAIL_DB_PW=$(openssl rand -base64 24 | tr -d '/+=' | head -c 28)
        log_warn "No MAIL_DB_PW in secrets.local - generated a random one (NOT in CREDENTIALS.txt)"
    fi
    mysql --defaults-file="$ROOT_DEFAULTS_FILE" <<SQL
CREATE USER '$MAIL_DB_USER'@'localhost' IDENTIFIED BY '$MAIL_DB_PW';
GRANT SELECT ON \`$MAIL_DB\`.* TO '$MAIL_DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL
    log_done "Created DB user $MAIL_DB_USER (read-only on $MAIL_DB)"
fi

SCHEMA_EXISTS=$(mysql --defaults-file="$ROOT_DEFAULTS_FILE" -Nse \
    "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$MAIL_DB' AND TABLE_NAME='virtual_mailboxes';" 2>/dev/null || echo "0")
if [ "$SCHEMA_EXISTS" -gt 0 ]; then
    log_skip "Mail schema already exists"
else
    mysql --defaults-file="$ROOT_DEFAULTS_FILE" "$MAIL_DB" <<SQL
CREATE TABLE virtual_domains (
    id INT NOT NULL AUTO_INCREMENT,
    name VARCHAR(50) NOT NULL,
    PRIMARY KEY (id),
    UNIQUE KEY name (name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE virtual_mailboxes (
    id INT NOT NULL AUTO_INCREMENT,
    domain_id INT NOT NULL,
    email VARCHAR(120) NOT NULL,
    password VARCHAR(255) NOT NULL,
    PRIMARY KEY (id),
    UNIQUE KEY email (email),
    FOREIGN KEY (domain_id) REFERENCES virtual_domains(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE virtual_aliases (
    id INT NOT NULL AUTO_INCREMENT,
    domain_id INT NOT NULL,
    source VARCHAR(120) NOT NULL,
    destination VARCHAR(120) NOT NULL,
    PRIMARY KEY (id),
    FOREIGN KEY (domain_id) REFERENCES virtual_domains(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
SQL
    log_done "Created tables: virtual_domains, virtual_mailboxes, virtual_aliases"
fi

DOMAIN_EXISTS=$(mysql --defaults-file="$ROOT_DEFAULTS_FILE" "$MAIL_DB" -Nse \
    "SELECT COUNT(*) FROM virtual_domains WHERE name='$MAIL_DOMAIN';" 2>/dev/null || echo "0")
if [ "$DOMAIN_EXISTS" -gt 0 ]; then
    log_skip "Domain $MAIL_DOMAIN already in virtual_domains"
else
    mysql --defaults-file="$ROOT_DEFAULTS_FILE" "$MAIL_DB" -e \
        "INSERT INTO virtual_domains (name) VALUES ('$MAIL_DOMAIN');"
    log_done "Inserted $MAIL_DOMAIN into virtual_domains"
fi

MBOX_EXISTS=$(mysql --defaults-file="$ROOT_DEFAULTS_FILE" "$MAIL_DB" -Nse \
    "SELECT COUNT(*) FROM virtual_mailboxes WHERE email='$TEST_MAILBOX';" 2>/dev/null || echo "0")
if [ "$MBOX_EXISTS" -gt 0 ]; then
    log_skip "Mailbox $TEST_MAILBOX already exists"
else
    # Use TEST_MAILBOX_PW from secrets.local if available, otherwise generate.
    # When phase0 was used, TEST_MAILBOX_PW is the password documented in
    # CREDENTIALS.txt - we MUST use it so CREDENTIALS.txt stays canonical.
    if [ -z "${TEST_MAILBOX_PW:-}" ]; then
        TEST_MAILBOX_PW=$(openssl rand -base64 18 | tr -d '/+=' | head -c 22)
        log_warn "No TEST_MAILBOX_PW in secrets.local - generated a random one (NOT in CREDENTIALS.txt)"
    fi
    HASHED_PW=$(doveadm pw -s SHA512-CRYPT -p "$TEST_MAILBOX_PW" 2>/dev/null)
    if [ -z "$HASHED_PW" ]; then
        log_fail "doveadm pw failed - cannot create mailbox"
        exit 1
    fi
    mysql --defaults-file="$ROOT_DEFAULTS_FILE" "$MAIL_DB" -e \
        "INSERT INTO virtual_mailboxes (domain_id, email, password)
         SELECT id, '$TEST_MAILBOX', '$HASHED_PW' FROM virtual_domains WHERE name='$MAIL_DOMAIN';"
    log_done "Created test mailbox $TEST_MAILBOX"
fi

# ============================================================================
# STEP 5: Configure Postfix
# ============================================================================
step "Step 5: Configuring Postfix"

POSTFIX_BACKUP="/etc/postfix/main.cf.phase4.bak"
if [ ! -f "$POSTFIX_BACKUP" ]; then
    cp /etc/postfix/main.cf "$POSTFIX_BACKUP"
    log_done "Backed up /etc/postfix/main.cf"
fi

if [ -z "$MAIL_DB_PW" ]; then
    log_warn "DB password unknown - resetting"
    # Use the value from secrets.local if it's there (CREDENTIALS.txt must
    # stay canonical). Otherwise generate.
    if [ -z "${MAIL_DB_PW:-}" ]; then
        MAIL_DB_PW=$(openssl rand -base64 24 | tr -d '/+=' | head -c 28)
        log_warn "No MAIL_DB_PW in secrets.local - generated a random one (NOT in CREDENTIALS.txt)"
    fi
    mysql --defaults-file="$ROOT_DEFAULTS_FILE" -e \
        "ALTER USER '$MAIL_DB_USER'@'localhost' IDENTIFIED BY '$MAIL_DB_PW'; FLUSH PRIVILEGES;"
fi

write_postfix_mysql_cf() {
    local file="$1"
    local query="$2"
    cat > "$file" <<EOF
user = $MAIL_DB_USER
password = $MAIL_DB_PW
hosts = 127.0.0.1
dbname = $MAIL_DB
query = $query
EOF
    chown root:postfix "$file"
    chmod 640 "$file"
}

write_postfix_mysql_cf /etc/postfix/mysql-virtual-mailbox-domains.cf \
    "SELECT 1 FROM virtual_domains WHERE name='%s'"
write_postfix_mysql_cf /etc/postfix/mysql-virtual-mailbox-maps.cf \
    "SELECT 1 FROM virtual_mailboxes WHERE email='%s'"
write_postfix_mysql_cf /etc/postfix/mysql-virtual-alias-maps.cf \
    "SELECT destination FROM virtual_aliases WHERE source='%s'"
log_done "Wrote Postfix MariaDB lookup configs"

postconf -e "myhostname = $MAIL_HOSTNAME"
postconf -e "mydomain = $MAIL_DOMAIN"
postconf -e "myorigin = \$mydomain"
postconf -e "inet_interfaces = all"
postconf -e "inet_protocols = ipv4"
postconf -e "mydestination = localhost"
postconf -e "mynetworks = 127.0.0.0/8 [::1]/128"
postconf -e "smtpd_banner = \$myhostname ESMTP"
postconf -e "biff = no"
postconf -e "append_dot_mydomain = no"
postconf -e "readme_directory = no"
postconf -e "compatibility_level = 3.6"

postconf -e "smtpd_tls_cert_file = $CERT_DIR/fullchain.pem"
postconf -e "smtpd_tls_key_file = $CERT_DIR/privkey.pem"
postconf -e "smtpd_use_tls = yes"
postconf -e "smtpd_tls_security_level = may"
postconf -e "smtp_tls_security_level = may"
postconf -e "smtpd_tls_session_cache_database = btree:\${data_directory}/smtpd_scache"
postconf -e "smtp_tls_session_cache_database = btree:\${data_directory}/smtp_scache"

postconf -e "virtual_transport = lmtp:unix:private/dovecot-lmtp"
postconf -e "virtual_mailbox_domains = mysql:/etc/postfix/mysql-virtual-mailbox-domains.cf"
postconf -e "virtual_mailbox_maps = mysql:/etc/postfix/mysql-virtual-mailbox-maps.cf"
postconf -e "virtual_alias_maps = mysql:/etc/postfix/mysql-virtual-alias-maps.cf"

postconf -e "smtpd_sasl_type = dovecot"
postconf -e "smtpd_sasl_path = private/auth"
postconf -e "smtpd_sasl_auth_enable = yes"
postconf -e "smtpd_relay_restrictions = permit_mynetworks permit_sasl_authenticated reject_unauth_destination"
postconf -e "smtpd_recipient_restrictions = permit_mynetworks permit_sasl_authenticated reject_unauth_destination reject_unknown_recipient_domain"

postconf -e "milter_default_action = accept"
postconf -e "milter_protocol = 6"
postconf -e "smtpd_milters = inet:127.0.0.1:8891 inet:127.0.0.1:8893 unix:/run/spamass-milter/spamass-milter.sock"
postconf -e "non_smtpd_milters = inet:127.0.0.1:8891 inet:127.0.0.1:8893 unix:/run/spamass-milter/spamass-milter.sock"

log_done "Configured /etc/postfix/main.cf"

if grep -qE '^submission\s' /etc/postfix/master.cf; then
    log_skip "Submission port (587) already enabled in master.cf"
else
    cat >> /etc/postfix/master.cf <<'EOF'

# phase4-marker - submission port 587 (encrypted client submission)
submission inet n       -       y       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_reject_unlisted_recipient=no
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING
EOF
    log_done "Enabled submission port 587 in master.cf"
fi

# ============================================================================
# STEP 6: Configure Dovecot (2.4 syntax)
# ============================================================================
step "Step 6: Configuring Dovecot (2.4 syntax)"

# Dovecot 2.4 has fundamentally different config syntax from 2.3:
#   - dovecot_config_version is mandatory at the top of dovecot.conf
#   - .conf.ext include files are gone; passdb/userdb settings are inline
#   - SSL settings renamed (ssl_cert -> ssl_server_cert_file, no '<' prefix)
#   - mail_location split into mail_driver / mail_path / mail_home
#   - Variable expansion changed: %d -> %{user|domain}, %n -> %{user|username}
#   - disable_plaintext_auth replaced by auth_allow_cleartext (default: no)
#
# We disable Ubuntu's default conf.d/*.conf includes to avoid 2.3-style settings
# leaking in, and put everything we need into a single dovecot.conf.

# Backup the package-shipped config files (they have the old 2.3 syntax)
DOVECOT_BACKUP_DIR="/etc/dovecot/conf.d.phase4.bak"
if [ ! -d "$DOVECOT_BACKUP_DIR" ] && [ -d /etc/dovecot/conf.d ]; then
    mv /etc/dovecot/conf.d "$DOVECOT_BACKUP_DIR"
    mkdir /etc/dovecot/conf.d   # empty - we don't use any includes
    log_done "Backed up package conf.d to $DOVECOT_BACKUP_DIR"
fi

# Remove the old dovecot-sql.conf.ext if it exists (no longer needed in 2.4)
if [ -f /etc/dovecot/dovecot-sql.conf.ext ] && \
   [ ! -f /etc/dovecot/dovecot-sql.conf.ext.phase4.bak ]; then
    mv /etc/dovecot/dovecot-sql.conf.ext /etc/dovecot/dovecot-sql.conf.ext.phase4.bak
    log_done "Backed up dovecot-sql.conf.ext (no longer used in 2.4)"
fi

# Write the single, complete dovecot.conf for 2.4
cat > /etc/dovecot/dovecot.conf <<EOF
# phase4-marker - managed by phase4.sh - Dovecot 2.4 syntax

# Mandatory in 2.4
dovecot_config_version = 2.4.0
dovecot_storage_version = 2.4.0

# Protocols this server speaks (no POP3 - we deliberately don't support it)
protocols {
    imap = yes
    lmtp = yes
    sieve = yes
}

protocol imap {
    mail_max_userip_connections = 50
    imap_idle_notify_interval = 29 mins
}

protocol lmtp {
    postmaster_address = postmaster@${MAIL_DOMAIN}
    # Sieve runs at LMTP delivery time. The 'global' sieve_script (defined
    # below) routes spam-flagged messages to the Junk folder.
    mail_plugins {
        sieve = yes
    }
}

# Sieve script locations (Dovecot 2.4 syntax - replaces old sieve_default).
# 'global' runs the admin-controlled spam-filing script for every user.
# 'personal' lets each user upload their own additional script via ManageSieve.
sieve_script global {
    sieve_script_type = global
    path = /var/lib/dovecot/sieve/default.sieve
}

sieve_script personal {
    driver = file
    path = ~/sieve
    active_path = ~/.dovecot.sieve
}

service managesieve-login {
    inet_listener sieve {
        port = 4190
    }
}

# TLS (using our Let's Encrypt cert)
ssl = required
ssl_server_cert_file = ${CERT_DIR}/fullchain.pem
ssl_server_key_file = ${CERT_DIR}/privkey.pem

# Mail storage (maildir under /var/vmail/<domain>/<user>/mail)
mail_uid = ${VMAIL_UID}
mail_gid = ${VMAIL_GID}
mail_privileged_group = vmail
mail_home = ${VMAIL_HOME}/%{user | domain}/%{user | username}
mail_driver = maildir
mail_path = ~/mail
mailbox_list_layout = fs

# Authentication
auth_mechanisms = plain login
auth_username_format = %{user | lower}

# SQL connection (used by passdb sql below)
sql_driver = mysql
mysql 127.0.0.1 {
    user = ${MAIL_DB_USER}
    password = ${MAIL_DB_PW}
    dbname = ${MAIL_DB}
}

# passdb: how to verify a user's password
passdb sql {
    query = SELECT email AS user, password FROM virtual_mailboxes WHERE email = '%{user | lower}';
    default_password_scheme = SHA512-CRYPT
}

# userdb: where the user's mail lives. We use static here because all
# virtual users share the same uid/gid; the per-user directory is from mail_home.
# Dovecot 2.4 requires the userdb_fields { } block syntax (NOT fields = ...).
userdb static {
    userdb_fields {
        uid = ${VMAIL_UID}
        gid = ${VMAIL_GID}
        home = ${VMAIL_HOME}/%{user | domain}/%{user | username}
    }
}

# Default mailbox folders (created on first login)
namespace inbox {
    inbox = yes

    mailbox Drafts {
        auto = subscribe
        special_use = \Drafts
    }
    mailbox "Sent Items" {
        auto = subscribe
        special_use = \Sent
    }
    mailbox Trash {
        auto = subscribe
        special_use = \Trash
    }
    mailbox Spam {
        auto = subscribe
        special_use = \Junk
    }
}

# Listening services
service imap-login {
    inet_listener imap {
        port = 0
    }
    inet_listener imaps {
        port = 993
        ssl = yes
    }
}

# LMTP socket - this is how Postfix delivers mail to Dovecot
service lmtp {
    unix_listener /var/spool/postfix/private/dovecot-lmtp {
        mode = 0660
        user = postfix
        group = postfix
    }
}

# Auth socket - this is how Postfix authenticates SMTP submission users
service auth {
    unix_listener /var/spool/postfix/private/auth {
        mode = 0660
        user = postfix
        group = postfix
    }
    unix_listener auth-userdb {
        mode = 0660
        user = ${VMAIL_USER}
        group = ${VMAIL_USER}
    }
}
EOF
chmod 600 /etc/dovecot/dovecot.conf
chown root:root /etc/dovecot/dovecot.conf
log_done "Wrote /etc/dovecot/dovecot.conf (2.4 syntax, mode 600)"

# ============================================================================
# STEP 7: Configure OpenDKIM
# ============================================================================
step "Step 7: Configuring OpenDKIM"

cat > /etc/opendkim.conf <<'EOF'
# phase4-marker - managed by phase4.sh
Syslog                  yes
SyslogSuccess           yes
LogWhy                  yes
UMask                   002
UserID                  opendkim
PidFile                 /run/opendkim/opendkim.pid

Mode                    sv
Canonicalization        relaxed/simple
SignatureAlgorithm      rsa-sha256
MinimumKeyBits          1024

KeyTable                file:/etc/opendkim/key.table
SigningTable            refile:/etc/opendkim/signing.table
ExternalIgnoreList      refile:/etc/opendkim/trusted.hosts
InternalHosts           refile:/etc/opendkim/trusted.hosts

Socket                  inet:8891@127.0.0.1
EOF
log_done "Wrote /etc/opendkim.conf"

cat > /etc/default/opendkim <<'EOF'
# phase4-marker - managed by phase4.sh
RUNDIR=/run/opendkim
SOCKET=inet:8891@127.0.0.1
USER=opendkim
GROUP=opendkim
PIDFILE=$RUNDIR/$NAME.pid
EXTRAAFTER=
EOF
log_done "Wrote /etc/default/opendkim"

if [ -f "$DKIM_KEY_DIR/$DKIM_SELECTOR.private" ]; then
    log_skip "DKIM key already exists at $DKIM_KEY_DIR/$DKIM_SELECTOR.private"
else
    mkdir -p "$DKIM_KEY_DIR"
    cd "$DKIM_KEY_DIR"
    opendkim-genkey -b 2048 -d "$MAIL_DOMAIN" -s "$DKIM_SELECTOR" 2>/dev/null
    chown -R opendkim:opendkim /etc/opendkim
    chmod 700 "$DKIM_KEY_DIR"
    chmod 600 "$DKIM_KEY_DIR/$DKIM_SELECTOR.private"
    cd - >/dev/null
    log_done "Generated 2048-bit DKIM key at $DKIM_KEY_DIR/$DKIM_SELECTOR.private"
fi

mkdir -p /etc/opendkim
cat > /etc/opendkim/key.table <<EOF
# phase4-marker - managed by phase4.sh
${DKIM_SELECTOR}._domainkey.${MAIL_DOMAIN} ${MAIL_DOMAIN}:${DKIM_SELECTOR}:${DKIM_KEY_DIR}/${DKIM_SELECTOR}.private
EOF
cat > /etc/opendkim/signing.table <<EOF
# phase4-marker - managed by phase4.sh
*@${MAIL_DOMAIN}    ${DKIM_SELECTOR}._domainkey.${MAIL_DOMAIN}
EOF
cat > /etc/opendkim/trusted.hosts <<'EOF'
# phase4-marker - managed by phase4.sh
127.0.0.1
::1
localhost
EOF
chown opendkim:opendkim /etc/opendkim/key.table /etc/opendkim/signing.table /etc/opendkim/trusted.hosts
chmod 644 /etc/opendkim/key.table /etc/opendkim/signing.table /etc/opendkim/trusted.hosts
log_done "Wrote OpenDKIM tables"

if [ -f "$DKIM_KEY_DIR/$DKIM_SELECTOR.txt" ]; then
    DKIM_TXT_VALUE=$(cat "$DKIM_KEY_DIR/$DKIM_SELECTOR.txt" | tr -d '\n\t' | sed 's/  */ /g')
fi

# ============================================================================
# STEP 8: Configure OpenDMARC
# ============================================================================
step "Step 8: Configuring OpenDMARC"

cat > /etc/opendmarc.conf <<EOF
# phase4-marker - managed by phase4.sh
AuthservID              $MAIL_HOSTNAME
PidFile                 /run/opendmarc/opendmarc.pid
RejectFailures          false
Syslog                  true
TrustedAuthservIDs      $MAIL_HOSTNAME
UserID                  opendmarc:opendmarc
IgnoreHosts             /etc/opendmarc/ignore.hosts
HistoryFile             /var/lib/opendmarc/opendmarc.dat
Socket                  inet:8893@127.0.0.1
EOF
log_done "Wrote /etc/opendmarc.conf"

mkdir -p /etc/opendmarc
cat > /etc/opendmarc/ignore.hosts <<'EOF'
# phase4-marker
127.0.0.1
::1
localhost
EOF
# Create OpenDMARC's data directory (the package post-install does NOT create it
# on Ubuntu 26.04, and OpenDMARC will milter-reject all inbound mail with
# "4.7.1 Service unavailable" until this exists).
mkdir -p /var/lib/opendmarc
touch /var/lib/opendmarc/opendmarc.dat
chown -R opendmarc:opendmarc /etc/opendmarc /var/lib/opendmarc
chmod 750 /var/lib/opendmarc
log_done "Wrote /etc/opendmarc/ignore.hosts"
log_done "Created /var/lib/opendmarc/ for OpenDMARC history file"

# ============================================================================
# STEP 8b: Configure SpamAssassin + spamass-milter + Sieve auto-filing
# ============================================================================
# Strategy: mark all spam (X-Spam-Flag, X-Spam-Score headers), reject only the
# extreme stuff (score >= 15, the obvious "free Viagra" tier) at SMTP, and let
# Dovecot Sieve file the rest into the user's Junk folder at LMTP delivery time.
# Result: users see clean inboxes, junk is reviewable in Junk, no false-positive
# losses, and obvious garbage never hits disk.
step "Step 8b: Configuring SpamAssassin + spamass-milter + Sieve"

# --- spamd (the SpamAssassin daemon) ---------------------------------------
# Ubuntu 26.04 ships SpamAssassin as a systemd-native service named 'spamd'
# (NOT 'spamassassin'). There's no /etc/default/spamassassin to edit anymore -
# all defaults are in the unit file at /lib/systemd/system/spamd.service.
# The unit ships pre-configured with sane defaults (--create-prefs, --max-children 5)
# and starts cleanly out of the box. We just verify it's there.
if systemctl list-unit-files 2>/dev/null | grep -qE '^spamd\.service'; then
    log_done "spamd.service unit available (Ubuntu 26.04 systemd-native config)"
elif systemctl list-unit-files 2>/dev/null | grep -qE '^spamassassin\.service'; then
    log_warn "Found legacy spamassassin.service - not Ubuntu 26.04, may need adjustment"
else
    log_fail "Neither spamd.service nor spamassassin.service found"
fi

# Update SpamAssassin rules database (silent fail OK - just means we use the
# package-shipped rules until next sa-update cron run)
sa-update --no-gpg 2>/dev/null && log_done "Updated SpamAssassin rules database" || log_warn "sa-update failed (using shipped rules - daily cron will retry; harmless on first run)"

# --- spamass-milter ---------------------------------------------------------
# Flags:
#   -u spamass-milter   run as the dedicated milter user
#   -i 127.0.0.1        ignore loopback (don't double-scan our own outbound)
#   -m                  add X-Spam-* headers (so Sieve can find them)
#   -r 15               reject mail with spam score >= 15 (obvious spam only)
#   -- -d 127.0.0.1     pass to spamc, which talks to spamd on localhost
SPAMASS_DEFAULTS=/etc/default/spamass-milter
cat > "$SPAMASS_DEFAULTS" <<'EOF'
# phase4-marker - managed by phase4.sh
OPTIONS="-u spamass-milter -i 127.0.0.1 -m -r 15 -- -d 127.0.0.1"
SOCKET="/run/spamass-milter/spamass-milter.sock"
SOCKETOWNER="postfix:postfix"
SOCKETMODE="0660"
EOF
log_done "Wrote $SPAMASS_DEFAULTS (mark all + reject score >= 15)"

# Make sure the spamass-milter socket directory exists with right ownership
mkdir -p /run/spamass-milter
chown spamass-milter:spamass-milter /run/spamass-milter
# Add postfix user to spamass-milter group so it can read the socket
usermod -a -G spamass-milter postfix 2>/dev/null || true
# Ubuntu 26.04 requirement: spamass-milter's pre-start script refuses to start
# unless spamass-milter is in the postfix group (because the socket gets
# chowned to postfix:postfix in $SOCKETOWNER below, and you can't chown to a
# group you're not in).
usermod -a -G postfix spamass-milter 2>/dev/null || true
log_done "Set up /run/spamass-milter/ socket directory"

# --- Dovecot Sieve script ---------------------------------------------------
# This is the global default Sieve script - applies to every user unless they
# upload their own via ManageSieve. Files X-Spam-Flag: YES into Junk.
SIEVE_DIR=/var/lib/dovecot/sieve
mkdir -p "$SIEVE_DIR"
cat > "$SIEVE_DIR/default.sieve" <<'EOF'
# phase4-marker - managed by phase4.sh
# Default global Sieve script: file flagged spam into Junk folder.
require ["fileinto", "imap4flags"];

if header :contains "X-Spam-Flag" "YES" {
    fileinto "Junk";
    stop;
}
EOF
# Compile the script (Dovecot Sieve uses .svbin compiled output for speed)
sievec "$SIEVE_DIR/default.sieve" 2>/dev/null || true
chown -R vmail:vmail "$SIEVE_DIR"
chmod 644 "$SIEVE_DIR/default.sieve"
[ -f "$SIEVE_DIR/default.svbin" ] && chmod 644 "$SIEVE_DIR/default.svbin"
log_done "Wrote and compiled global Sieve script: $SIEVE_DIR/default.sieve"

# Open ManageSieve port in firewall (so users can edit their own scripts
# from Thunderbird's Sieve extension or Roundcube's Sieve plugin later)
if ! ufw status | grep -qE "^4190/tcp\s+ALLOW"; then
    ufw allow 4190/tcp >/dev/null 2>&1
    log_done "Firewall: allow 4190/tcp (ManageSieve)"
fi

# ============================================================================
# STEP 9: Open mail ports in firewall
# ============================================================================
step "Step 9: Opening mail ports in firewall"

for port in 25 587 993; do
    if ufw status | grep -qE "^${port}/tcp\s+ALLOW"; then
        log_skip "Firewall already allows $port/tcp"
    else
        ufw allow ${port}/tcp >/dev/null 2>&1
        log_done "Firewall: allow $port/tcp"
    fi
done

# Clean up: if 465 or 995 were allowed by a previous run, remove them
# (we deliberately do not support legacy SMTPS or POP3S)
for port in 465 995; do
    if ufw status | grep -qE "^${port}/tcp\s+ALLOW"; then
        ufw delete allow ${port}/tcp >/dev/null 2>&1
        log_done "Firewall: removed legacy port $port/tcp"
    fi
done

# ============================================================================
# STEP 9b: Generate BIND zone file for DNS provider import
# ============================================================================
# Produces a complete, ready-to-import BIND zone file at
# /root/server_setup/dns/<MAIL_DOMAIN>.zone. This file can be uploaded
# directly to Cloudflare DNS (Records -> Import and Export -> Import) or
# used as a reference when entering records manually at IONOS or any other
# DNS provider. The DKIM key is read from the live OpenDKIM key file so
# the output is always in sync with what's actually deployed on the server.
step "Step 9b: Generating BIND zone file for DNS import"

ZONE_DIR="/root/server_setup/dns"
ZONE_FILE="$ZONE_DIR/${MAIL_DOMAIN}.zone"
mkdir -p "$ZONE_DIR"
chmod 700 "$ZONE_DIR"

# Detect server IP. Prefer the IP that owns the default route (works even
# on multi-homed hosts).
SERVER_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
if [ -z "$SERVER_IP" ]; then
    # Fallback: first non-loopback IPv4
    SERVER_IP=$(hostname -I | awk '{print $1}')
fi

# Extract the DKIM TXT record content from the file OpenDKIM generated.
# default.txt looks like:
#   default._domainkey IN TXT ( "v=DKIM1; h=sha256; k=rsa; "
#     "p=MIIBIj..." "...eyRzN..." ) ; ----- DKIM key default for ...
#
# We need the value between the parens, joined into a single string,
# minus the trailing comment. Cloudflare accepts both split-string and
# single-string forms; we go with split (more compatible with strict parsers).
DKIM_KEY_TXT_FILE="$DKIM_KEY_DIR/$DKIM_SELECTOR.txt"
DKIM_RECORD=""
if [ -f "$DKIM_KEY_TXT_FILE" ]; then
    # Pull everything between the first ( and the last ), preserving the
    # quoted-string structure so Cloudflare/BIND parsers handle it.
    DKIM_RECORD=$(awk '
        /^[a-zA-Z0-9_]+\._domainkey/ { in_record = 1 }
        in_record {
            line = $0
            sub(/.*\(/, "", line)
            sub(/\).*/, "", line)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            if (length(line) > 0) {
                if (out) { out = out " " line } else { out = line }
            }
            if (/\)/) { in_record = 0 }
        }
        END { print out }
    ' "$DKIM_KEY_TXT_FILE")
fi

if [ -z "$DKIM_RECORD" ]; then
    log_warn "Could not extract DKIM record from $DKIM_KEY_TXT_FILE - zone file will have a placeholder"
    DKIM_RECORD='"v=DKIM1; h=sha256; k=rsa; p=REPLACE_WITH_KEY_FROM_default.txt"'
fi

cat > "$ZONE_FILE" <<EOF
; BIND zone file for ${MAIL_DOMAIN}
; Generated by phase4.sh on $(date '+%Y-%m-%d %H:%M:%S %Z')
;
; To import at Cloudflare:
;   Dashboard -> DNS -> Records -> Import and Export -> Import
;
; To use at another DNS provider that supports BIND import,
; consult that provider's documentation.

\$ORIGIN ${MAIL_DOMAIN}.
\$TTL 3600

; ----- Web server (Phase 2) -----
@        IN  A      ${SERVER_IP}
www      IN  A      ${SERVER_IP}

; ----- Mail server (Phase 4) -----
mail     IN  A      ${SERVER_IP}
@        IN  MX 10  mail.${MAIL_DOMAIN}.

; ----- SPF: only this server (via MX) is allowed to send for the domain -----
@        IN  TXT    "v=spf1 mx ~all"

; ----- DKIM: public key for verifying our outbound signatures -----
${DKIM_SELECTOR}._domainkey IN TXT ${DKIM_RECORD}

; ----- DMARC: policy + reporting address -----
_dmarc   IN  TXT    "v=DMARC1; p=none; rua=mailto:wglover@docentims.com"

; ----- CAA: only Let's Encrypt may issue certs for this domain -----
@        IN  CAA  0 issue "letsencrypt.org"
@        IN  CAA  0 issuewild "letsencrypt.org"
@        IN  CAA  0 iodef "mailto:wglover@docentims.com"
EOF

chmod 600 "$ZONE_FILE"
chown root:root "$ZONE_FILE"
log_done "Wrote BIND zone file: $ZONE_FILE"
echo "  (transfer to your workstation with:  scp wayne@$MAIL_HOSTNAME:$ZONE_FILE  )"

# ============================================================================
# STEP 10: Restart all services
# ============================================================================
step "Step 10: Restarting services"

if postfix check 2>&1 | grep -qE 'fatal|error'; then
    log_fail "postfix check found errors"
    postfix check
    exit 1
fi

systemctl restart opendkim
systemctl enable opendkim >/dev/null 2>&1
if systemctl is-active --quiet opendkim; then
    log_done "opendkim restarted and enabled"
else
    log_fail "opendkim failed to start - check 'journalctl -u opendkim'"
fi

systemctl restart opendmarc
systemctl enable opendmarc >/dev/null 2>&1
if systemctl is-active --quiet opendmarc; then
    log_done "opendmarc restarted and enabled"
else
    log_fail "opendmarc failed to start - check 'journalctl -u opendmarc'"
fi

systemctl restart dovecot
systemctl enable dovecot >/dev/null 2>&1
if systemctl is-active --quiet dovecot; then
    log_done "dovecot restarted and enabled"
else
    log_fail "dovecot failed to start - check 'journalctl -u dovecot'"
fi

systemctl restart postfix
systemctl enable postfix >/dev/null 2>&1
if systemctl is-active --quiet postfix; then
    log_done "postfix restarted and enabled"
else
    log_fail "postfix failed to start - check 'journalctl -u postfix'"
fi

systemctl restart spamd
systemctl enable spamd >/dev/null 2>&1
if systemctl is-active --quiet spamd; then
    log_done "spamd (SpamAssassin daemon) restarted and enabled"
else
    log_fail "spamd failed to start - check 'journalctl -u spamd'"
fi

systemctl restart spamass-milter
systemctl enable spamass-milter >/dev/null 2>&1
if systemctl is-active --quiet spamass-milter; then
    log_done "spamass-milter restarted and enabled"
else
    log_fail "spamass-milter failed to start - check 'journalctl -u spamass-milter'"
fi

# Postfix must restart AFTER spamass-milter so the milter socket exists by the
# time Postfix tries to connect. We restart Postfix once more here as a safety.
systemctl reload postfix 2>/dev/null || true

# ============================================================================
# REPORT
# ============================================================================
echo ""
echo "==================================================================="
echo "  PHASE 4 COMPLETE - SUMMARY REPORT"
echo "==================================================================="
echo ""
for line in "${REPORT[@]}"; do
    echo "  $line"
done

# ============================================================================
# CREDENTIALS
# ============================================================================
# ============================================================================
# PASSWORDS
# ============================================================================
echo ""
echo "==================================================================="
echo "  PASSWORDS"
echo "==================================================================="
echo ""
echo "  All passwords are in CREDENTIALS.txt at the repo root."
echo "  This script does NOT print passwords (to avoid scrollback exposure)."
echo ""
echo "  The mail DB password is also stored in:"
echo "    /etc/postfix/mysql-*.cf"
echo "    /etc/dovecot/dovecot-sql.conf.ext"
echo ""

# ============================================================================
# DKIM RECORD FOR DNS
# ============================================================================
echo ""
echo "==================================================================="
echo "  DNS RECORDS TO ADD AT IONOS"
echo "==================================================================="
cat <<EOF

  After this script completes, add these records at IONOS for $MAIL_DOMAIN:

  1. MX record
       Host:  @
       Value: $MAIL_HOSTNAME
       Priority: 10

  2. TXT record (SPF)
       Host:  @
       Value: v=spf1 mx ~all

  3. TXT record (DKIM)
       Host:  ${DKIM_SELECTOR}._domainkey
       Value: (see below — copy the contents inside the parentheses, on one line)

EOF
if [ -n "$DKIM_TXT_VALUE" ]; then
    echo "$DKIM_TXT_VALUE"
    echo ""
    echo "  Or read the raw key file directly:"
    echo "       sudo cat $DKIM_KEY_DIR/$DKIM_SELECTOR.txt"
    echo ""
fi
cat <<EOF
  4. TXT record (DMARC)
       Host:  _dmarc
       Value: v=DMARC1; p=none; rua=mailto:wglover@docentims.com

  REMEMBER: remove the existing IONOS-managed mail records first
  (see ionos-dns-reference.docx for the full list).

EOF

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

for pkg in postfix postfix-mysql dovecot-core dovecot-imapd dovecot-mysql dovecot-sieve opendkim opendmarc spamassassin spamass-milter; do
    if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        vp "Package $pkg installed"
    else
        vf "Package $pkg NOT installed"
    fi
done

for svc in postfix dovecot opendkim opendmarc spamd spamass-milter; do
    if systemctl is-active --quiet "$svc"; then
        vp "Service $svc is active"
    else
        vf "Service $svc is NOT active"
    fi
done

if openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -ext subjectAltName 2>/dev/null | \
   grep -qE "DNS:${MAIL_HOSTNAME}([,[:space:]]|$)"; then
    vp "TLS cert covers $MAIL_HOSTNAME"
else
    vf "TLS cert does NOT cover $MAIL_HOSTNAME"
fi

if id "$VMAIL_USER" &>/dev/null; then
    vp "User $VMAIL_USER exists"
else
    vf "User $VMAIL_USER does NOT exist"
fi

if [ -d "$VMAIL_HOME" ] && [ "$(stat -c '%U' "$VMAIL_HOME")" = "$VMAIL_USER" ]; then
    vp "$VMAIL_HOME owned by $VMAIL_USER"
else
    vf "$VMAIL_HOME ownership wrong"
fi

if mysql --defaults-file="$ROOT_DEFAULTS_FILE" -Nse \
   "SELECT 1 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$MAIL_DB';" 2>/dev/null | grep -q 1; then
    vp "Database $MAIL_DB exists"
else
    vf "Database $MAIL_DB does NOT exist"
fi

if mysql --defaults-file="$ROOT_DEFAULTS_FILE" "$MAIL_DB" -Nse \
   "SELECT 1 FROM virtual_mailboxes WHERE email='$TEST_MAILBOX';" 2>/dev/null | grep -q 1; then
    vp "Test mailbox $TEST_MAILBOX exists in DB"
else
    vf "Test mailbox $TEST_MAILBOX missing from DB"
fi

if [ -f "$DKIM_KEY_DIR/$DKIM_SELECTOR.private" ]; then
    vp "DKIM private key exists"
else
    vf "DKIM private key missing"
fi

# OpenDMARC needs /var/lib/opendmarc/ to exist or it milter-rejects all mail.
# Verify it exists AND is writable by the opendmarc user.
if [ -d /var/lib/opendmarc ] && [ "$(stat -c '%U' /var/lib/opendmarc)" = "opendmarc" ]; then
    vp "OpenDMARC data directory exists and is owned by opendmarc"
else
    vf "OpenDMARC data directory /var/lib/opendmarc/ is missing or wrong owner"
fi

# SpamAssassin (Ubuntu 26.04 service is 'spamd' with systemd-native config -
# no /etc/default file). We verify the unit exists and is enabled.
if systemctl list-unit-files 2>/dev/null | grep -qE '^spamd\.service\s+enabled'; then
    vp "spamd service is enabled at boot"
else
    vf "spamd service is NOT enabled at boot"
fi

if [ -S /run/spamass-milter/spamass-milter.sock ]; then
    vp "spamass-milter socket exists at /run/spamass-milter/spamass-milter.sock"
else
    vf "spamass-milter socket missing at /run/spamass-milter/spamass-milter.sock"
fi

# Sieve: default script should exist and be compiled
if [ -f /var/lib/dovecot/sieve/default.sieve ]; then
    vp "Default Sieve script exists at /var/lib/dovecot/sieve/default.sieve"
else
    vf "Default Sieve script missing"
fi

if [ -f /var/lib/dovecot/sieve/default.svbin ]; then
    vp "Default Sieve script is compiled (.svbin present)"
else
    vf "Default Sieve script not compiled (sievec failed?)"
fi

# Verify Postfix actually has the spamass-milter in its milter chain
if postconf -h smtpd_milters 2>/dev/null | grep -q "spamass-milter"; then
    vp "Postfix smtpd_milters includes spamass-milter"
else
    vf "Postfix smtpd_milters does NOT include spamass-milter"
fi
for port_check in "25:smtp" "587:submission" "993:imaps" "4190:managesieve" "8891:opendkim" "8893:opendmarc"; do
    PORT="${port_check%%:*}"
    NAME="${port_check##*:}"
    if ss -tlnp 2>/dev/null | grep -qE ":${PORT}\b"; then
        vp "Port $PORT ($NAME) is listening"
    else
        vf "Port $PORT ($NAME) is NOT listening"
    fi
done

# Verify POP3 ports are NOT listening (we deliberately don't support POP)
for port in 110 995; do
    if ss -tlnp 2>/dev/null | grep -qE ":${port}\b"; then
        vf "Port $port (POP3) is listening but should NOT be"
    else
        vp "Port $port (POP3) correctly not listening"
    fi
done

if postfix check 2>&1 | grep -qE 'fatal|error'; then
    vf "postfix check found errors"
else
    vp "postfix check passed"
fi

UFW_STATUS=$(ufw status 2>/dev/null)
for port in 25 587 993; do
    if echo "$UFW_STATUS" | grep -qE "^${port}/tcp\s+ALLOW"; then
        vp "Firewall allows $port/tcp"
    else
        vf "Firewall does NOT allow $port/tcp"
    fi
done

# Verify legacy ports are NOT in firewall
for port in 465 995; do
    if echo "$UFW_STATUS" | grep -qE "^${port}/tcp\s+ALLOW"; then
        vf "Firewall allows legacy $port/tcp (should NOT)"
    else
        vp "Firewall correctly denies legacy $port/tcp"
    fi
done

if postmap -q "$MAIL_DOMAIN" mysql:/etc/postfix/mysql-virtual-mailbox-domains.cf 2>/dev/null | grep -q 1; then
    vp "Postfix can resolve $MAIL_DOMAIN via MariaDB"
else
    vf "Postfix cannot resolve $MAIL_DOMAIN via MariaDB"
fi

if postmap -q "$TEST_MAILBOX" mysql:/etc/postfix/mysql-virtual-mailbox-maps.cf 2>/dev/null | grep -q 1; then
    vp "Postfix can resolve $TEST_MAILBOX via MariaDB"
else
    vf "Postfix cannot resolve $TEST_MAILBOX via MariaDB"
fi

# SMTP banner check - read greeting via openssl (clean disconnect, no
# pipelining warnings). We use openssl's -starttls smtp because plain TCP
# reads via bash TCP redirect proved unreliable when the kernel races
# Postfix's banner output. Wait, no STARTTLS - just a plain banner read.
# Use python for a reliable line read with timeout.
SMTP_BANNER=$(timeout 5 python3 -c "
import socket
s = socket.socket()
s.settimeout(3)
s.connect(('127.0.0.1', 25))
banner = s.recv(1024).decode('utf-8', errors='replace').split('\n')[0].strip()
s.close()
print(banner)
" 2>/dev/null)
if echo "$SMTP_BANNER" | grep -qE "^220.*${MAIL_HOSTNAME}"; then
    vp "SMTP banner correct: $SMTP_BANNER"
else
    vf "SMTP banner unexpected: $SMTP_BANNER"
fi

# Zone file checks
if [ -f "$ZONE_FILE" ]; then
    vp "BIND zone file exists at $ZONE_FILE"
    if grep -q "REPLACE_WITH_KEY" "$ZONE_FILE"; then
        vf "Zone file still has DKIM placeholder - DKIM extraction failed"
    else
        vp "Zone file has real DKIM key (no placeholder)"
    fi
    # Check it has all 4 mail records + CAA
    for needed in "MX 10" "v=spf1" "v=DKIM1" "v=DMARC1" "letsencrypt.org"; do
        if grep -qF "$needed" "$ZONE_FILE"; then
            vp "Zone file contains: $needed"
        else
            vf "Zone file missing: $needed"
        fi
    done
else
    vf "BIND zone file NOT created at $ZONE_FILE"
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

  INTERNAL TESTING (works without PTR or DNS records):

  1. Confirm CREDENTIALS.txt is saved in your password manager. The
     test mailbox password is in section 4. The Mail DB password is
     in BACKEND PASSWORDS.

  2. Send a test message from the local server to the test mailbox:
       echo "test body" | mail -s "test subject" $TEST_MAILBOX

  3. Confirm it landed in the maildir:
       sudo find $VMAIL_HOME/$MAIL_DOMAIN -name 'new' -type d
       sudo ls -la $VMAIL_HOME/$MAIL_DOMAIN/$TEST_MAILBOX_LOCAL/new/

  4. Check the mail logs for any errors:
       sudo tail -50 /var/log/mail.log

  EXTERNAL CONFIGURATION (DNS - choose ONE method):

  5a. MANUAL at IONOS:
      Add the four DNS records listed above at IONOS DNS for $MAIL_DOMAIN.
      Remove the IONOS-managed mail records before/while adding the new ones.
      See dns-reference.docx for the full list.

  5b. BULK IMPORT to Cloudflare (or any provider that accepts BIND files):
      The script wrote a complete BIND zone file at:
        $ZONE_FILE
      Transfer it to your workstation:
        scp wayne@$MAIL_HOSTNAME:$ZONE_FILE  .
      At Cloudflare: DNS -> Records -> Import and Export -> Import
      (Requires migrating DNS hosting from IONOS to Cloudflare first;
       see dns-reference.docx Section "Future option: migrate DNS hosting
       to Cloudflare" for the migration steps.)

  6. After DNS has propagated (usually < 1 minute), verify:
       dig @8.8.8.8 MX $MAIL_DOMAIN
       dig @8.8.8.8 TXT $MAIL_DOMAIN
       dig @8.8.8.8 TXT ${DKIM_SELECTOR}._domainkey.$MAIL_DOMAIN
       dig @8.8.8.8 TXT _dmarc.$MAIL_DOMAIN

  EXTERNAL TESTING (limited until PTR is set):

  7. Configure Thunderbird/Outlook to connect to:
       IMAP server:    $MAIL_HOSTNAME  port 993  SSL/TLS
       SMTP server:    $MAIL_HOSTNAME  port 587  STARTTLS
       Username:       $TEST_MAILBOX  (full email address)
       Password:       (the test mailbox password)
       (POP3 is deliberately not supported - use IMAP only)

  8. Send mail TO $TEST_MAILBOX from your existing Gmail/Outlook/etc.
     Should arrive in the test mailbox. (Inbound is not affected by PTR.)

  9. Send mail FROM $TEST_MAILBOX to a tolerant address. Will likely
     land in spam at major providers until PTR is set. This is expected.

  10. SPAM FILTER TEST:
      To verify SpamAssassin + Sieve are filing junk into Junk folder, send
      a test message containing the GTUBE string (a standard test marker that
      SpamAssassin always scores as spam):

         XJS*C4JDBQADN1.NSBN3*2IDNEN*GTUBE-STANDARD-ANTI-UBE-TEST-EMAIL*C.34X

      Send this from any external account TO $TEST_MAILBOX with that string
      in the body. Within seconds it should land in the JUNK folder (not the
      INBOX). Check the mail log:
         sudo tail /var/log/mail.log
      You'll see the X-Spam-Flag header added and Sieve filing it into Junk.

  11. Clear scrollback:  clear && history -c

  Once PTR is granted (separate ticket with Kamatera), outbound deliverability
  to Gmail/Outlook/etc. will improve dramatically without any code changes.

EOF
echo "==================================================================="

if [ "$VERIFY_FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
