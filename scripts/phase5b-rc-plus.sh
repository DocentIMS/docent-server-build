#!/bin/bash
#
# phase5b-rc-plus.sh - Phase 5b: Roundcube Plus plugins and skins
#
# Installs commercial Roundcube Plus products from .tar.gz files stored in
# this repo at vendor/roundcube-plus/. Activates them in Roundcube's main
# config and applies the license key from /root/secrets/roundcube-plus.conf.
#
# RC+ products supported by this script:
#   plugin_xai.tar.gz         -> xai plugin (AI Assistant)
#   plugin_xsignature.tar.gz  -> xsignature plugin (Signature Designer)
#   skin_outlook.tar.gz       -> outlook skin (free version)
#   skin_outlook_plus.tar.gz  -> outlook_plus skin (mobile-capable)
#
# All RC+ products require the xframework plugin which ships with each
# tarball. The script extracts xframework once and shares it.
#
# Prerequisites:
#   - Phase 5 (Roundcube webmail) must be complete and working
#   - License file at /root/secrets/roundcube-plus.conf with format:
#       license_key=RCP-xxxxxxxxxxxxxxxx
#   - .tar.gz files present in this script's expected vendor directory
#
# Idempotent. Safe to re-run. Each step checks current state before acting.
#
# Run as root: sudo bash phase5b-rc-plus.sh
#

set -u

# ============================================================================
# CONFIGURATION
# ============================================================================
MAIL_DOMAIN="docenttemplate.com"
ROUNDCUBE_CONFIG=/etc/roundcube/config.inc.php
ROUNDCUBE_PLUGINS_DIR=/usr/share/roundcube/plugins
ROUNDCUBE_SKINS_DIR=/usr/share/roundcube/skins
DEFAULT_SKIN="outlook_plus"

# Where the .tar.gz files live - this script expects to be run from the
# cloned repo, with vendor/ as a sibling of scripts/. Auto-detect:
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
VENDOR_DIR="$REPO_ROOT/vendor/roundcube-plus"

LICENSE_FILE=/root/secrets/roundcube-plus.conf

# Plugins to enable in Roundcube's $config['plugins'] array
RC_PLUS_PLUGINS=(xai xsignature)

# ============================================================================
# REPORT TRACKING
# ============================================================================
REPORT=()
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

if [ ! -f "$ROUNDCUBE_CONFIG" ]; then
    echo "ERROR: $ROUNDCUBE_CONFIG not found. Phase 5 must run first."
    exit 1
fi

if ! grep -q "phase5-marker" "$ROUNDCUBE_CONFIG"; then
    echo "ERROR: $ROUNDCUBE_CONFIG is not phase5-managed. Phase 5 must run first."
    exit 1
fi

if [ ! -f "$LICENSE_FILE" ]; then
    echo "ERROR: License file $LICENSE_FILE not found."
    echo ""
    echo "Create it with:"
    echo "  sudo mkdir -p /root/secrets"
    echo "  sudo chmod 700 /root/secrets"
    echo "  sudo tee /root/secrets/roundcube-plus.conf > /dev/null <<'EOF'"
    echo "license_key=RCP-yourkeyhere"
    echo "EOF"
    echo "  sudo chmod 600 /root/secrets/roundcube-plus.conf"
    exit 1
fi

# Read the license key
LICENSE_KEY=$(grep -oP '^license_key=\K.+' "$LICENSE_FILE" 2>/dev/null | head -1)
if [ -z "$LICENSE_KEY" ]; then
    echo "ERROR: Could not parse license_key from $LICENSE_FILE."
    echo "Expected format: license_key=RCP-xxxxxxxxxx"
    exit 1
fi

if [ ! -d "$VENDOR_DIR" ]; then
    echo "ERROR: Vendor directory not found: $VENDOR_DIR"
    echo ""
    echo "This script expects to be run from a cloned docent-server-build repo,"
    echo "with the .tar.gz files placed in vendor/roundcube-plus/."
    echo ""
    echo "Detected repo root: $REPO_ROOT"
    echo "Looking for: $VENDOR_DIR"
    exit 1
fi

echo "==================================================================="
echo "  Phase 5b - Roundcube Plus plugins & skins"
echo "  Roundcube config: $ROUNDCUBE_CONFIG"
echo "  Plugins dir:      $ROUNDCUBE_PLUGINS_DIR"
echo "  Skins dir:        $ROUNDCUBE_SKINS_DIR"
echo "  Vendor dir:       $VENDOR_DIR"
echo "  Default skin:     $DEFAULT_SKIN"
echo "  License key:      ${LICENSE_KEY:0:8}... (loaded from $LICENSE_FILE)"
echo "  $(date)"
echo "==================================================================="

# ============================================================================
# STEP 1: Verify all expected tarballs are present
# ============================================================================
step "Step 1: Checking RC+ tarball inventory"

EXPECTED_TARBALLS=(
    plugin_xai.tar.gz
    plugin_xsignature.tar.gz
    skin_outlook.tar.gz
    skin_outlook_plus.tar.gz
)

MISSING=()
PRESENT=()
for tb in "${EXPECTED_TARBALLS[@]}"; do
    if [ -f "$VENDOR_DIR/$tb" ]; then
        SIZE=$(stat -c%s "$VENDOR_DIR/$tb")
        PRESENT+=("$tb (${SIZE} bytes)")
    else
        MISSING+=("$tb")
    fi
done

for tb in "${PRESENT[@]}"; do
    log_done "Found $tb"
done

if [ ${#MISSING[@]} -gt 0 ]; then
    for tb in "${MISSING[@]}"; do
        log_fail "Missing $tb"
    done
    echo ""
    echo "Place all expected tarballs in $VENDOR_DIR/ before running."
    exit 1
fi

# ============================================================================
# STEP 2: Extract tarballs to a staging area
# ============================================================================
step "Step 2: Extracting tarballs to staging area"

STAGING=$(mktemp -d /tmp/rcplus-staging.XXXXXX)
trap "rm -rf $STAGING" EXIT

for tb in "${EXPECTED_TARBALLS[@]}"; do
    tar -xzf "$VENDOR_DIR/$tb" -C "$STAGING/"
    log_done "Extracted $tb"
done

# RC+ tarballs include a top-level plugins/ and sometimes skins/ folder.
# Merge structure should now be:
#   $STAGING/plugins/xframework/
#   $STAGING/plugins/xai/
#   $STAGING/plugins/xsignature/
#   $STAGING/plugins/xskin/        (provided by skin tarballs)
#   $STAGING/skins/outlook/
#   $STAGING/skins/outlook_plus/

if [ ! -d "$STAGING/plugins/xframework" ]; then
    log_fail "Expected $STAGING/plugins/xframework not found after extraction"
    echo "  Tarball contents may have changed. Inspect with:"
    echo "    tar -tzf $VENDOR_DIR/plugin_xai.tar.gz | head"
    exit 1
fi

# ============================================================================
# STEP 3: Install xframework (shared dependency)
# ============================================================================
step "Step 3: Installing xframework (shared by all RC+ products)"

if [ -d "$ROUNDCUBE_PLUGINS_DIR/xframework" ]; then
    log_skip "xframework already installed - updating files (preserving config)"
    # Sync everything except the config file
    rsync -a --exclude='config.inc.php' "$STAGING/plugins/xframework/" "$ROUNDCUBE_PLUGINS_DIR/xframework/"
else
    cp -a "$STAGING/plugins/xframework" "$ROUNDCUBE_PLUGINS_DIR/"
    log_done "Copied xframework to $ROUNDCUBE_PLUGINS_DIR/xframework/"
fi

# ============================================================================
# STEP 4: Install plugins (xai, xsignature)
# ============================================================================
step "Step 4: Installing RC+ plugins"

for plugin in "${RC_PLUS_PLUGINS[@]}"; do
    if [ ! -d "$STAGING/plugins/$plugin" ]; then
        log_warn "$plugin not found in staging - skipping"
        continue
    fi

    PLUGIN_TARGET="$ROUNDCUBE_PLUGINS_DIR/$plugin"
    if [ -d "$PLUGIN_TARGET" ]; then
        log_skip "$plugin already installed - updating files (preserving config)"
        rsync -a --exclude='config.inc.php' "$STAGING/plugins/$plugin/" "$PLUGIN_TARGET/"
    else
        cp -a "$STAGING/plugins/$plugin" "$ROUNDCUBE_PLUGINS_DIR/"
        log_done "Copied $plugin to $PLUGIN_TARGET/"
    fi

    # Activate config.inc.php from the .dist template if not already activated
    if [ -f "$PLUGIN_TARGET/config.inc.php" ]; then
        log_skip "$plugin/config.inc.php exists (preserving customizations)"
    elif [ -f "$PLUGIN_TARGET/config.inc.php.dist" ]; then
        cp "$PLUGIN_TARGET/config.inc.php.dist" "$PLUGIN_TARGET/config.inc.php"
        chown root:www-data "$PLUGIN_TARGET/config.inc.php"
        chmod 640 "$PLUGIN_TARGET/config.inc.php"
        log_done "Activated $plugin/config.inc.php from .dist"
    else
        log_warn "$plugin has no config.inc.php.dist - skipping config activation"
    fi
done

# ============================================================================
# STEP 5: Install skins (outlook, outlook_plus)
# ============================================================================
step "Step 5: Installing RC+ skins"

# The skin tarballs also include the xskin plugin which provides shared
# skin functionality. Install it like the others.
if [ -d "$STAGING/plugins/xskin" ]; then
    if [ -d "$ROUNDCUBE_PLUGINS_DIR/xskin" ]; then
        log_skip "xskin already installed - updating files (preserving config)"
        rsync -a --exclude='config.inc.php' "$STAGING/plugins/xskin/" "$ROUNDCUBE_PLUGINS_DIR/xskin/"
    else
        cp -a "$STAGING/plugins/xskin" "$ROUNDCUBE_PLUGINS_DIR/"
        log_done "Copied xskin to $ROUNDCUBE_PLUGINS_DIR/xskin/"
    fi
    if [ ! -f "$ROUNDCUBE_PLUGINS_DIR/xskin/config.inc.php" ] && \
       [ -f "$ROUNDCUBE_PLUGINS_DIR/xskin/config.inc.php.dist" ]; then
        cp "$ROUNDCUBE_PLUGINS_DIR/xskin/config.inc.php.dist" "$ROUNDCUBE_PLUGINS_DIR/xskin/config.inc.php"
        chown root:www-data "$ROUNDCUBE_PLUGINS_DIR/xskin/config.inc.php"
        chmod 640 "$ROUNDCUBE_PLUGINS_DIR/xskin/config.inc.php"
        log_done "Activated xskin/config.inc.php from .dist"
    fi
fi

# Now the actual skin folders
if [ -d "$STAGING/skins" ]; then
    for skin_dir in "$STAGING/skins"/*/; do
        [ -d "$skin_dir" ] || continue
        skin_name=$(basename "$skin_dir")
        SKIN_TARGET="$ROUNDCUBE_SKINS_DIR/$skin_name"

        if [ -d "$SKIN_TARGET" ]; then
            log_skip "Skin $skin_name already present - updating"
            rsync -a "$skin_dir" "$SKIN_TARGET/"
        else
            cp -a "$skin_dir" "$ROUNDCUBE_SKINS_DIR/"
            log_done "Installed skin: $skin_name"
        fi
    done
else
    log_warn "No skins/ directory in staging - no skins to install"
fi

# ============================================================================
# STEP 6: Update Roundcube config to enable plugins, set skin, set license
# ============================================================================
step "Step 6: Updating Roundcube config"

# We need to do three things in /etc/roundcube/config.inc.php:
#   1. Add xai, xsignature to the $config['plugins'] array
#      (xframework and xskin are loaded by the others, NOT added to plugins)
#   2. Set $config['skin'] = 'outlook_plus'
#   3. Add $config['license_key'] = '...'
#
# The config was written by phase5.sh and we need to preserve everything else.
# Strategy: use sed/python to surgically modify it. Backup first.

cp "$ROUNDCUBE_CONFIG" "$ROUNDCUBE_CONFIG.phase5b.bak"

# Use python because the array manipulation is finicky with sed
python3 <<PYEOF
import re

path = '$ROUNDCUBE_CONFIG'
with open(path, 'r') as f:
    content = f.read()

# 1. Update plugins array - add xai, xsignature if not already there
plugins_to_add = ['xai', 'xsignature']

# Match the \$config['plugins'] = [ ... ]; block (multi-line)
plugins_pattern = re.compile(
    r"(\\\$config\['plugins'\]\s*=\s*\[)(.*?)(\];)",
    re.DOTALL
)
m = plugins_pattern.search(content)
if not m:
    print("ERROR: Could not find \$config['plugins'] in $ROUNDCUBE_CONFIG")
    exit(1)

opening, body, closing = m.group(1), m.group(2), m.group(3)
existing_plugins = re.findall(r"'([^']+)'", body)

new_plugins = list(existing_plugins)
added = []
for p in plugins_to_add:
    if p not in new_plugins:
        new_plugins.append(p)
        added.append(p)

# Reformat the array body cleanly
new_body = '\n'
for p in new_plugins:
    new_body += "    '" + p + "',\n"
new_block = opening + new_body + closing
content = plugins_pattern.sub(lambda m: new_block, content)

# 2. Update skin
skin_pattern = re.compile(r"\\\$config\['skin'\]\s*=\s*'[^']*';")
if skin_pattern.search(content):
    content = skin_pattern.sub("\$config['skin'] = '$DEFAULT_SKIN';", content)
else:
    # Append before the closing PHP tag (or end of file)
    content = content.rstrip() + "\n\\\$config['skin'] = '$DEFAULT_SKIN';\n"

# 3. License key - update or insert
license_pattern = re.compile(r"\\\$config\['license_key'\]\s*=\s*'[^']*';")
if license_pattern.search(content):
    content = license_pattern.sub("\$config['license_key'] = '$LICENSE_KEY';", content)
else:
    content = content.rstrip() + "\n\\\$config['license_key'] = '$LICENSE_KEY';\n"

with open(path, 'w') as f:
    f.write(content)

if added:
    print("  Added plugins to \$config['plugins']: " + ', '.join(added))
else:
    print("  All plugins already in \$config['plugins']")
print("  Set \$config['skin'] = '$DEFAULT_SKIN'")
print("  Set \$config['license_key'] = '${LICENSE_KEY:0:8}...'")
PYEOF

if [ $? -ne 0 ]; then
    log_fail "Failed to update Roundcube config - restoring backup"
    cp "$ROUNDCUBE_CONFIG.phase5b.bak" "$ROUNDCUBE_CONFIG"
    exit 1
fi

log_done "Updated $ROUNDCUBE_CONFIG (plugins, skin, license_key)"

# ============================================================================
# STEP 7: Set ownership and permissions on plugin/skin files
# ============================================================================
step "Step 7: Setting ownership and permissions"

# RC+ plugins and skins should be readable by Apache (www-data) but only
# writable by root. The config.inc.php files inside each plugin should be
# 640 root:www-data so the world can't read API keys etc.
for plugin in xframework xskin "${RC_PLUS_PLUGINS[@]}"; do
    if [ -d "$ROUNDCUBE_PLUGINS_DIR/$plugin" ]; then
        chown -R root:www-data "$ROUNDCUBE_PLUGINS_DIR/$plugin"
        find "$ROUNDCUBE_PLUGINS_DIR/$plugin" -type d -exec chmod 750 {} \;
        find "$ROUNDCUBE_PLUGINS_DIR/$plugin" -type f -exec chmod 640 {} \;
        log_done "Set permissions on $ROUNDCUBE_PLUGINS_DIR/$plugin"
    fi
done

for skin in outlook outlook_plus; do
    if [ -d "$ROUNDCUBE_SKINS_DIR/$skin" ]; then
        chown -R root:www-data "$ROUNDCUBE_SKINS_DIR/$skin"
        find "$ROUNDCUBE_SKINS_DIR/$skin" -type d -exec chmod 755 {} \;
        find "$ROUNDCUBE_SKINS_DIR/$skin" -type f -exec chmod 644 {} \;
        log_done "Set permissions on $ROUNDCUBE_SKINS_DIR/$skin"
    fi
done

# ============================================================================
# STEP 8: Reload Apache
# ============================================================================
step "Step 8: Reloading Apache"

if apache2ctl configtest 2>&1 | grep -q "Syntax OK"; then
    systemctl reload apache2
    log_done "Apache config valid, reloaded"
else
    log_fail "Apache config has errors. NOT reloading."
    apache2ctl configtest 2>&1 | tail -5
    exit 1
fi

# ============================================================================
# REPORT
# ============================================================================
echo ""
echo "==================================================================="
echo "  PHASE 5b COMPLETE - SUMMARY REPORT"
echo "==================================================================="
echo ""
for line in "${REPORT[@]}"; do
    echo "  $line"
done

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

# All required directories present
for d in xframework xskin xai xsignature; do
    if [ -d "$ROUNDCUBE_PLUGINS_DIR/$d" ]; then
        vp "Plugin directory $d installed"
    else
        vf "Plugin directory $d MISSING"
    fi
done

for s in outlook outlook_plus; do
    if [ -d "$ROUNDCUBE_SKINS_DIR/$s" ]; then
        vp "Skin directory $s installed"
    else
        vf "Skin directory $s MISSING"
    fi
done

# License key in config
if grep -q "\$config\['license_key'\] = '$LICENSE_KEY'" "$ROUNDCUBE_CONFIG"; then
    vp "License key present in $ROUNDCUBE_CONFIG"
else
    vf "License key MISSING in $ROUNDCUBE_CONFIG"
fi

# Plugins in array
for plugin in "${RC_PLUS_PLUGINS[@]}"; do
    if grep -qE "'$plugin'" "$ROUNDCUBE_CONFIG"; then
        vp "Plugin $plugin enabled in \$config['plugins']"
    else
        vf "Plugin $plugin NOT in \$config['plugins']"
    fi
done

# Skin set
if grep -q "\$config\['skin'\] = '$DEFAULT_SKIN'" "$ROUNDCUBE_CONFIG"; then
    vp "Default skin set to $DEFAULT_SKIN"
else
    vf "Default skin not set to $DEFAULT_SKIN"
fi

# Apache happy
if apache2ctl configtest 2>&1 | grep -q "Syntax OK"; then
    vp "Apache config syntax OK"
else
    vf "Apache config has errors"
fi

if systemctl is-active --quiet apache2; then
    vp "Apache is running"
else
    vf "Apache is NOT running"
fi

# www-data can read the configs
if sudo -u www-data test -r "$ROUNDCUBE_PLUGINS_DIR/xai/config.inc.php" 2>/dev/null; then
    vp "www-data can read xai config"
else
    vf "www-data CANNOT read xai config"
fi

# License file is properly secured
if [ -f "$LICENSE_FILE" ]; then
    PERMS=$(stat -c '%a' "$LICENSE_FILE")
    if [ "$PERMS" = "600" ]; then
        vp "License file mode 600 (root-only)"
    else
        vf "License file has permissions $PERMS (should be 600)"
    fi
fi

echo ""
echo "  Verification: $VERIFY_PASS passed, $VERIFY_FAIL failed"
echo ""

if [ "$VERIFY_FAIL" -gt 0 ]; then
    echo "  *** $VERIFY_FAIL CHECK(S) FAILED. Review above before proceeding. ***"
fi

# ============================================================================
# MANUAL VERIFICATION & NEXT STEPS
# ============================================================================
echo "==================================================================="
echo "  MANUAL VERIFICATION & NEXT STEPS"
echo "==================================================================="
cat <<EOF

  1. Open https://${MAIL_DOMAIN}/mail/ in your browser (or hard-refresh
     if you already had it open) and log in.

  2. The interface should now use the "outlook_plus" skin (Outlook-style
     navigation, modern layout, mobile-capable).

  3. Verify each plugin works:
       - AI Assistant (xai): you may see an AI button somewhere in the compose
         interface. Configuration is in $ROUNDCUBE_PLUGINS_DIR/xai/config.inc.php
         - this is where you set your AI API key (OpenAI, etc.)

       - Signature Designer (xsignature): go to Settings -> Identities -> edit
         your identity. There should now be a richer signature editor than
         the default plain text box.

  4. Check for any plugin errors:
       sudo tail /var/log/roundcube/errors.log
       sudo tail /var/log/apache2/error.log

  5. AI Assistant configuration:
       Edit $ROUNDCUBE_PLUGINS_DIR/xai/config.inc.php to add your AI API
       credentials. The config file lists supported providers (OpenAI, etc.)
       and how to authenticate to each.

  Re-running this script is safe - it preserves any plugin-specific config
  customizations you make in plugins/<plugin>/config.inc.php.

EOF
echo "==================================================================="

if [ "$VERIFY_FAIL" -gt 0 ]; then
    exit 1
fi
exit 0