#!/bin/bash
#
# Phase 5b — Install globaladdressbook plugin (Project Contacts)
#
# Per-tenant shared address book named "Project Contacts".
# Visible to all users on this Roundcube install with full read/write.
# Each cloned tenant has its own isolated copy via its own database.
#
# Idempotent: safe to re-run. Skips work that's already done.
# Also defensively cleans up phantom on-disk Sent directories if found
# (covers running phase5b on a server that was built with the old phase4.sh
# before the mailbox "Sent Items" fix).

set -u

# ============================================================================
# CONFIGURATION
# ============================================================================
ROUNDCUBE_CONFIG=/etc/roundcube/config.inc.php
ROUNDCUBE_PLUGINS_SRC=/usr/share/roundcube/plugins
ROUNDCUBE_PLUGINS_LOAD=/var/lib/roundcube/plugins
ROUNDCUBE_PLUGIN_CONFIG_DIR=/etc/roundcube/plugins/globaladdressbook
PLUGIN_NAME=globaladdressbook
PLUGIN_REPO=https://github.com/johndoh/roundcube-globaladdressbook.git
# Pin to a stable tagged release. The plugin's README explicitly warns that
# master is unstable and intended only for git-master Roundcube. Tag 2.1 is
# the latest stable release and is documented as "For Roundcube 1.5 and
# above" - Ubuntu 26.04 ships Roundcube 1.6.x so this matches.
# Review and bump this every 6-12 months: see
#   https://github.com/johndoh/roundcube-globaladdressbook/releases
PLUGIN_VERSION=2.1
ADDRESSBOOK_DISPLAY_NAME="Project Contacts"
ADDRESSBOOK_USER="_project_contacts_user_"
VMAIL_ROOT=/var/vmail

# Load shared helpers and per-tenant config. lib/common.sh sources
# tenant.local/secrets.local (overriding the hardcoded defaults above) and
# provides colors, logging helpers, and verification helpers.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

# ============================================================================
# REPORT TRACKING
# ============================================================================
REPORT=()


# ============================================================================
# SAFETY CHECKS
# ============================================================================
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root (use sudo)."
    exit 1
fi

if [ ! -f "$ROUNDCUBE_CONFIG" ]; then
    echo "ERROR: $ROUNDCUBE_CONFIG not found. Phase 5 must run first."
    exit 1
fi

if ! grep -q "phase5-marker" "$ROUNDCUBE_CONFIG"; then
    echo "ERROR: $ROUNDCUBE_CONFIG is not phase5-managed. Phase 5 must run first."
    exit 1
fi

# ============================================================================
# BANNER
# ============================================================================
echo "==================================================================="
echo "  Phase 5b - globaladdressbook plugin (Project Contacts)"
echo "  $(date)"
echo "==================================================================="

# ============================================================================
# STEP 1: Defensive cleanup of phantom Sent directories
# ============================================================================
# This covers servers built before phase4.sh was fixed to use
# mailbox "Sent Items" instead of mailbox Sent. On those servers,
# Dovecot was previously advertising both Sent and Sent Items, leaving
# a phantom Sent folder in the sidebar and on disk.
step "Step 1: Defensive cleanup of phantom Sent directories"

if [ -d "$VMAIL_ROOT" ]; then
    PHANTOM_COUNT=0
    while IFS= read -r -d '' phantom_dir; do
        # Only remove if it has no mail (cur and new are empty/missing)
        if [ -z "$(find "$phantom_dir" -type f 2>/dev/null | head -1)" ]; then
            rm -rf "$phantom_dir"
            PHANTOM_COUNT=$((PHANTOM_COUNT + 1))
            log_done "Removed empty phantom directory: $phantom_dir"
        else
            log_warn "Phantom Sent directory has mail, skipping: $phantom_dir"
        fi
    done < <(find "$VMAIL_ROOT" -type d -name "Sent" -print0 2>/dev/null)

    if [ "$PHANTOM_COUNT" -eq 0 ]; then
        log_skip "No phantom Sent directories found"
    fi
else
    log_skip "$VMAIL_ROOT does not exist; nothing to clean"
fi

# ============================================================================
# STEP 2: Install the globaladdressbook plugin
# ============================================================================
step "Step 2: Installing globaladdressbook plugin"

if [ -d "$ROUNDCUBE_PLUGINS_SRC/$PLUGIN_NAME/.git" ]; then
    # Already cloned. Check whether it's at the pinned tag.
    current_ref=$(cd "$ROUNDCUBE_PLUGINS_SRC/$PLUGIN_NAME" && \
        git describe --tags --exact-match 2>/dev/null || \
        git rev-parse --abbrev-ref HEAD 2>/dev/null || \
        echo "unknown")
    if [ "$current_ref" = "$PLUGIN_VERSION" ]; then
        log_skip "Plugin already cloned at tag $PLUGIN_VERSION"
    else
        log_warn "Plugin clone exists but is on '$current_ref', not pinned tag '$PLUGIN_VERSION' - leaving as-is (delete the directory and re-run to pin)"
    fi
elif [ -d "$ROUNDCUBE_PLUGINS_SRC/$PLUGIN_NAME" ]; then
    log_warn "$ROUNDCUBE_PLUGINS_SRC/$PLUGIN_NAME exists but is not a git clone; leaving as-is"
else
    if ! command -v git >/dev/null 2>&1; then
        log_fail "git not installed; cannot clone plugin"
        exit 1
    fi
    # Pin to a stable tagged release with a shallow clone (--depth 1).
    if ! git clone --quiet --depth 1 --branch "$PLUGIN_VERSION" \
        "$PLUGIN_REPO" "$ROUNDCUBE_PLUGINS_SRC/$PLUGIN_NAME"; then
        log_fail "git clone of $PLUGIN_NAME ($PLUGIN_VERSION) failed - see output above"
        exit 1
    fi
    chown -R root:www-data "$ROUNDCUBE_PLUGINS_SRC/$PLUGIN_NAME"
    chmod -R g+r "$ROUNDCUBE_PLUGINS_SRC/$PLUGIN_NAME"
    log_done "Cloned $PLUGIN_NAME plugin at tag $PLUGIN_VERSION"
fi

# ============================================================================
# STEP 3: Write the plugin's config (Project Contacts)
# ============================================================================
step "Step 3: Writing plugin config at $ROUNDCUBE_PLUGIN_CONFIG_DIR"

if [ ! -d "$ROUNDCUBE_PLUGIN_CONFIG_DIR" ]; then
    mkdir -p "$ROUNDCUBE_PLUGIN_CONFIG_DIR"
    log_done "Created $ROUNDCUBE_PLUGIN_CONFIG_DIR"
else
    log_skip "$ROUNDCUBE_PLUGIN_CONFIG_DIR already exists"
fi

cat > "$ROUNDCUBE_PLUGIN_CONFIG_DIR/config.inc.php" << 'CONFIG_EOF'
<?php
/**
 * GlobalAddressbook configuration - Project Contacts
 * Per-tenant shared address book.
 * Each cloned tenant has its own isolated copy via its own database.
 */
$config = [];

$config['globaladdressbooks']['project_contacts'] = [
    'name' => 'Project Contacts',
    'user' => '_project_contacts_user_',
    'perms' => 1,                  // 1 = users can add/edit/delete
    'force_copy' => true,          // copy not move from global book
    'groups' => true,              // allow groups (categories)
    'admin' => null,               // optional list of admin usernames
    'autocomplete' => true,        // show in compose autocomplete
    'check_safe' => true,          // trust senders for inline images
    'visibility' => null,          // visible to all users on this install
];

$config['globaladdressbook_allowed_hosts'] = null;
CONFIG_EOF

chown root:root "$ROUNDCUBE_PLUGIN_CONFIG_DIR/config.inc.php"
chmod 644 "$ROUNDCUBE_PLUGIN_CONFIG_DIR/config.inc.php"
log_done "Wrote $ROUNDCUBE_PLUGIN_CONFIG_DIR/config.inc.php"

# Symlink Roundcube's per-plugin config location to the system config
# (this is the pattern other plugins on Debian Roundcube use)
PLUGIN_CONFIG_LINK="$ROUNDCUBE_PLUGINS_SRC/$PLUGIN_NAME/config.inc.php"
if [ -L "$PLUGIN_CONFIG_LINK" ]; then
    log_skip "Plugin config symlink already exists"
elif [ -e "$PLUGIN_CONFIG_LINK" ]; then
    log_warn "$PLUGIN_CONFIG_LINK exists but is not a symlink; leaving as-is"
else
    ln -s "$ROUNDCUBE_PLUGIN_CONFIG_DIR/config.inc.php" "$PLUGIN_CONFIG_LINK"
    log_done "Symlinked $PLUGIN_CONFIG_LINK -> $ROUNDCUBE_PLUGIN_CONFIG_DIR/config.inc.php"
fi

# ============================================================================
# STEP 4: Symlink plugin into Debian's plugin load path
# ============================================================================
# Debian Roundcube loads plugins from /var/lib/roundcube/plugins/, not
# from /usr/share/roundcube/plugins/. Other plugins (xskin, etc.) follow
# this same symlink pattern.
step "Step 4: Symlinking plugin into $ROUNDCUBE_PLUGINS_LOAD"

LOAD_LINK="$ROUNDCUBE_PLUGINS_LOAD/$PLUGIN_NAME"
if [ -L "$LOAD_LINK" ]; then
    log_skip "Load-path symlink already exists"
elif [ -e "$LOAD_LINK" ]; then
    log_warn "$LOAD_LINK exists but is not a symlink; leaving as-is"
else
    ln -s "$ROUNDCUBE_PLUGINS_SRC/$PLUGIN_NAME" "$LOAD_LINK"
    log_done "Symlinked $LOAD_LINK -> $ROUNDCUBE_PLUGINS_SRC/$PLUGIN_NAME"
fi

# ============================================================================
# STEP 5: Add globaladdressbook to Roundcube's $config['plugins'] array
# ============================================================================
step "Step 5: Registering plugin in $ROUNDCUBE_CONFIG"

if grep -q "'$PLUGIN_NAME'" "$ROUNDCUBE_CONFIG"; then
    log_skip "$PLUGIN_NAME already in plugins array"
else
    # Insert before the closing ]; of the plugins array.
    # The address pattern uses sed's range syntax: from the line matching
    # $config['plugins'] up to the next standalone "];".
    sed -i "/\\\$config\\['plugins'\\]/,/^\\];/{ /^\\];/i\\
    '$PLUGIN_NAME',
}" "$ROUNDCUBE_CONFIG"
    if grep -q "'$PLUGIN_NAME'" "$ROUNDCUBE_CONFIG"; then
        log_done "Added '$PLUGIN_NAME' to \$config['plugins']"
    else
        log_fail "Failed to insert '$PLUGIN_NAME' into \$config['plugins'] (unexpected config format)"
        exit 1
    fi
fi

# ============================================================================
# STEP 6: Reload Apache so the new plugin loads
# ============================================================================
step "Step 6: Reloading Apache"

if systemctl reload apache2; then
    log_done "Apache reloaded"
else
    log_fail "Apache reload failed"
    exit 1
fi

# ============================================================================
# STEP 7: Verification
# ============================================================================
step "Step 7: Verification"

VERIFY_PASS=0
VERIFY_FAIL=0


verify_cmd "Plugin source directory exists" \
    test -d "$ROUNDCUBE_PLUGINS_SRC/$PLUGIN_NAME"
verify_cmd "Plugin clone is at pinned tag $PLUGIN_VERSION" \
    bash -c "cd '$ROUNDCUBE_PLUGINS_SRC/$PLUGIN_NAME' && [ \"\$(git describe --tags --exact-match 2>/dev/null)\" = '$PLUGIN_VERSION' ]"
verify_cmd "Plugin main PHP file exists" \
    test -f "$ROUNDCUBE_PLUGINS_SRC/$PLUGIN_NAME/$PLUGIN_NAME.php"
verify_cmd "Plugin config exists" \
    test -f "$ROUNDCUBE_PLUGIN_CONFIG_DIR/config.inc.php"
verify_cmd "Plugin config syntax is valid PHP" \
    php -l "$ROUNDCUBE_PLUGIN_CONFIG_DIR/config.inc.php"
verify_cmd "Roundcube main config syntax is valid PHP" \
    php -l "$ROUNDCUBE_CONFIG"
verify_cmd "Plugin load symlink exists" \
    test -L "$ROUNDCUBE_PLUGINS_LOAD/$PLUGIN_NAME"
verify_cmd "Plugin appears in plugins array" \
    grep -q "'$PLUGIN_NAME'" "$ROUNDCUBE_CONFIG"
verify_cmd "Apache is running" \
    systemctl is-active --quiet apache2

echo ""
echo "  Verification: $VERIFY_PASS passed, $VERIFY_FAIL failed"
echo ""

if [ "$VERIFY_FAIL" -gt 0 ]; then
    echo "  *** $VERIFY_FAIL CHECK(S) FAILED. Review above before proceeding. ***"
fi


if [ "$VERIFY_FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
