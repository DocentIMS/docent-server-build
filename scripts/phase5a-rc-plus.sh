#!/bin/bash
#
# phase5a-rc-plus.sh - Phase 5a: Roundcube Plus plugins and skins
#
# Installs commercial Roundcube Plus products from .tar.gz files stored in
# this repo at vendor/roundcube-plus/. Activates them in Roundcube's main
# config and applies the license key from /root/secrets/roundcube-plus.conf.
#
# RC+ products supported by this script:
#   plugin_xsignature.tar.gz  -> xsignature plugin (Signature Designer)
#   skin_outlook.tar.gz       -> outlook skin (free version)
#   skin_outlook_plus.tar.gz  -> outlook_plus skin (mobile-capable)
#
# NOTE: The xai plugin (AI Assistant) lives in phase 5c (Email AI), NOT here.
# The plugin_xai.tar.gz file is still expected in vendor/ because xframework
# (a shared dependency) is extracted from it. xai itself is not installed here.
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
# Run as root: sudo bash phase5a-rc-plus.sh
#

set -u

# ============================================================================
# CONFIGURATION
# ============================================================================
DOMAIN="docenttemplate.com"
ROUNDCUBE_CONFIG=/etc/roundcube/config.inc.php
ROUNDCUBE_PLUGINS_DIR=/usr/share/roundcube/plugins
ROUNDCUBE_SKINS_DIR=/usr/share/roundcube/skins
DEFAULT_SKIN="outlook_plus"

# Where the .tar.gz files live - this script expects to be run from the
# cloned repo, with vendor/ as a sibling of scripts/. Auto-detect:
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
VENDOR_DIR="$REPO_ROOT/vendor/roundcube-plus"

# RC+ plugins installed here (xai is in phase 5c, not here)
RC_PLUS_PLUGINS=(xsignature)

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

# ============================================================================
# Determine license key
# ============================================================================
# The Roundcube Plus license key comes from secrets.local (which phase0
# generates from your input). secrets.local is the single source of truth -
# CREDENTIALS.txt mirrors what's there.

if [ -z "${RC_PLUS_LICENSE_KEY:-}" ]; then
    echo "ERROR: RC_PLUS_LICENSE_KEY not found in secrets.local."
    echo ""
    echo "Run phase0-bootstrap.sh first - it captures the license key into"
    echo "secrets.local and CREDENTIALS.txt."
    exit 1
fi

LICENSE_KEY="$RC_PLUS_LICENSE_KEY"

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
echo "  Phase 5a - Roundcube Plus plugins & skins"
echo "  Roundcube config: $ROUNDCUBE_CONFIG"
echo "  Plugins dir:      $ROUNDCUBE_PLUGINS_DIR"
echo "  Skins dir:        $ROUNDCUBE_SKINS_DIR"
echo "  Vendor dir:       $VENDOR_DIR"
echo "  Default skin:     $DEFAULT_SKIN"
echo "  License key:      ${LICENSE_KEY:0:8}... (from secrets.local)"
echo "  $(date)"
echo "==================================================================="

# ============================================================================
# STEP 1: Verify all expected tarballs are present
# ============================================================================
step "Step 1: Checking RC+ tarball inventory"

EXPECTED_TARBALLS=(
    roundcube_plus_plugin_xai.tar.gz
    roundcube_plus_plugin_xsignature.tar.gz
    roundcube_plus_skin_outlook.tar.gz
    roundcube_plus_skin_outlook_plus.tar.gz
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

# RC+ tarball layouts vary:
#   plugin_xai.tar.gz       -> xai/, xframework/ (at top level)
#   plugin_xsignature.tar.gz -> xsignature/, xframework/ (at top level)
#   skin_outlook.tar.gz      -> plugins/xskin/, skins/outlook/, README, VERSIONS
#   skin_outlook_plus.tar.gz -> plugins/xskin/, skins/outlook_plus/, README, VERSIONS
#
# Each tarball ships its own copy of xframework. We use the version from
# the LAST extracted tarball (they should be identical or compatible).
# Each tarball gets extracted into its own subdirectory of the staging
# area so we can find things deterministically.

STAGING=$(mktemp -d /tmp/rcplus-staging.XXXXXX)
trap "rm -rf $STAGING" EXIT

for tb in "${EXPECTED_TARBALLS[@]}"; do
    # Strip .tar.gz and the roundcube_plus_ prefix for the staging dir name
    SUBDIR="${tb%.tar.gz}"
    SUBDIR="${SUBDIR#roundcube_plus_}"
    mkdir -p "$STAGING/$SUBDIR"
    tar -xzf "$VENDOR_DIR/$tb" -C "$STAGING/$SUBDIR/"
    log_done "Extracted $tb to staging/$SUBDIR/"
done

# Now staging looks like:
#   $STAGING/plugin_xai/xai/
#   $STAGING/plugin_xai/xframework/
#   $STAGING/plugin_xsignature/xsignature/
#   $STAGING/plugin_xsignature/xframework/
#   $STAGING/skin_outlook/plugins/xskin/
#   $STAGING/skin_outlook/skins/outlook/
#   $STAGING/skin_outlook_plus/plugins/xskin/
#   $STAGING/skin_outlook_plus/skins/outlook_plus/

# ============================================================================
# STEP 3: Install xframework (shared dependency)
# ============================================================================
step "Step 3: Installing xframework (shared by all RC+ products)"

# Take xframework from the xai tarball - all copies should be the same version
XFRAMEWORK_SRC="$STAGING/plugin_xai/xframework"
if [ ! -d "$XFRAMEWORK_SRC" ]; then
    # Fall back to xsignature if xai doesn't have it
    XFRAMEWORK_SRC="$STAGING/plugin_xsignature/xframework"
fi
if [ ! -d "$XFRAMEWORK_SRC" ]; then
    log_fail "Could not find xframework in any extracted tarball"
    exit 1
fi

if [ -d "$ROUNDCUBE_PLUGINS_DIR/xframework" ]; then
    log_skip "xframework already installed - updating files (preserving config)"
    rsync -a --exclude='config.inc.php' "$XFRAMEWORK_SRC/" "$ROUNDCUBE_PLUGINS_DIR/xframework/"
else
    cp -a "$XFRAMEWORK_SRC" "$ROUNDCUBE_PLUGINS_DIR/"
    log_done "Copied xframework to $ROUNDCUBE_PLUGINS_DIR/xframework/"
fi

# ============================================================================
# STEP 4: Install plugins (xsignature only - xai is in phase 5c)
# ============================================================================
step "Step 4: Installing RC+ plugins"

# Map plugin name -> staging source path
declare -A PLUGIN_SRC_MAP=(
    [xsignature]="$STAGING/plugin_xsignature/xsignature"
)

for plugin in "${RC_PLUS_PLUGINS[@]}"; do
    SRC="${PLUGIN_SRC_MAP[$plugin]}"
    if [ ! -d "$SRC" ]; then
        log_warn "$plugin source not found at $SRC - skipping"
        continue
    fi

    PLUGIN_TARGET="$ROUNDCUBE_PLUGINS_DIR/$plugin"
    if [ -d "$PLUGIN_TARGET" ]; then
        log_skip "$plugin already installed - updating files (preserving config)"
        rsync -a --exclude='config.inc.php' "$SRC/" "$PLUGIN_TARGET/"
    else
        cp -a "$SRC" "$ROUNDCUBE_PLUGINS_DIR/"
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
# STEP 5: Install skins (outlook, outlook_plus) and xskin plugin
# ============================================================================
step "Step 5: Installing RC+ skins and xskin plugin"

# xskin plugin lives inside the skin tarballs at <staging>/skin_*/plugins/xskin
# Take it from skin_outlook_plus (default skin) since that's our preferred version
XSKIN_SRC="$STAGING/skin_outlook_plus/plugins/xskin"
if [ ! -d "$XSKIN_SRC" ]; then
    XSKIN_SRC="$STAGING/skin_outlook/plugins/xskin"
fi

if [ -d "$XSKIN_SRC" ]; then
    if [ -d "$ROUNDCUBE_PLUGINS_DIR/xskin" ]; then
        log_skip "xskin already installed - updating files (preserving config)"
        rsync -a --exclude='config.inc.php' "$XSKIN_SRC/" "$ROUNDCUBE_PLUGINS_DIR/xskin/"
    else
        cp -a "$XSKIN_SRC" "$ROUNDCUBE_PLUGINS_DIR/"
        log_done "Copied xskin to $ROUNDCUBE_PLUGINS_DIR/xskin/"
    fi
    if [ ! -f "$ROUNDCUBE_PLUGINS_DIR/xskin/config.inc.php" ] && \
       [ -f "$ROUNDCUBE_PLUGINS_DIR/xskin/config.inc.php.dist" ]; then
        cp "$ROUNDCUBE_PLUGINS_DIR/xskin/config.inc.php.dist" "$ROUNDCUBE_PLUGINS_DIR/xskin/config.inc.php"
        chown root:www-data "$ROUNDCUBE_PLUGINS_DIR/xskin/config.inc.php"
        chmod 640 "$ROUNDCUBE_PLUGINS_DIR/xskin/config.inc.php"
        log_done "Activated xskin/config.inc.php from .dist"
    fi
else
    log_warn "xskin source not found in any skin tarball"
fi

# Now the actual skin folders - look in each skin tarball's skins/ directory
for skin_tb_dir in "$STAGING/skin_outlook" "$STAGING/skin_outlook_plus"; do
    [ -d "$skin_tb_dir/skins" ] || continue
    for skin_dir in "$skin_tb_dir/skins"/*/; do
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
done

# ============================================================================
# STEP 6: Update Roundcube config to enable plugins, set skin, set license
# ============================================================================
step "Step 6: Updating Roundcube config"

# We need to do three things in /etc/roundcube/config.inc.php:
#   1. Add xsignature to the $config['plugins'] array
#      (xframework and xskin are loaded by the others, NOT added to plugins)
#      (xai is added by phase 5c)
#   2. Set $config['skin'] = 'outlook_plus'
#   3. Add $config['license_key'] = '...'
#
# The config was written by phase5.sh and we need to preserve everything else.
# We use sed (avoids the cross-language escaping bugs that came from running
# Python via heredoc - $config in PHP collides with bash $variable expansion).

cp "$ROUNDCUBE_CONFIG" "$ROUNDCUBE_CONFIG.phase5a.bak"

# 1. Add plugins to the array. Roundcube's array is multi-line, so we use
#    sed to find the closing ']; and inject our plugin entries just before it,
#    but only if those plugins aren't already there.
for plugin in "${RC_PLUS_PLUGINS[@]}"; do
    if grep -q "'$plugin'" "$ROUNDCUBE_CONFIG"; then
        echo "  Plugin $plugin already in \$config['plugins']"
    else
        # Find the line containing only "];" that closes the plugins array
        # and insert "    'plugin'," before it. We narrow this down by using
        # sed's address ranges: from the line matching $config['plugins']
        # up to the next standalone "];".
        sed -i "/\\\$config\\['plugins'\\]/,/^\\];/{ /^\\];/i\\
    '$plugin',
}" "$ROUNDCUBE_CONFIG"
        echo "  Added '$plugin' to \$config['plugins']"
    fi
done

# 2. Set skin - either replace existing line or append
if grep -q "^\$config\\['skin'\\]" "$ROUNDCUBE_CONFIG"; then
    sed -i "s|^\$config\\['skin'\\].*|\$config['skin'] = '$DEFAULT_SKIN';|" "$ROUNDCUBE_CONFIG"
    echo "  Updated existing \$config['skin'] = '$DEFAULT_SKIN'"
else
    echo "\$config['skin'] = '$DEFAULT_SKIN';" >> "$ROUNDCUBE_CONFIG"
    echo "  Appended \$config['skin'] = '$DEFAULT_SKIN'"
fi

# 3. Set license_key - either replace existing or append
if grep -q "^\$config\\['license_key'\\]" "$ROUNDCUBE_CONFIG"; then
    sed -i "s|^\$config\\['license_key'\\].*|\$config['license_key'] = '$LICENSE_KEY';|" "$ROUNDCUBE_CONFIG"
    echo "  Updated existing \$config['license_key']"
else
    echo "\$config['license_key'] = '$LICENSE_KEY';" >> "$ROUNDCUBE_CONFIG"
    echo "  Appended \$config['license_key']"
fi

# Verify the resulting file is valid PHP - if not, restore backup
if ! php -l "$ROUNDCUBE_CONFIG" > /dev/null 2>&1; then
    log_fail "Resulting config has PHP syntax errors - restoring backup"
    php -l "$ROUNDCUBE_CONFIG" 2>&1 | tail -5
    cp "$ROUNDCUBE_CONFIG.phase5a.bak" "$ROUNDCUBE_CONFIG"
    exit 1
fi

log_done "Updated $ROUNDCUBE_CONFIG (plugins, skin, license_key)"

# ============================================================================
# STEP 6b: Create symlinks under /var/lib/roundcube/
# ============================================================================
step "Step 6b: Creating symlinks for Roundcube plugin/skin discovery"

# On Ubuntu, Roundcube's runtime path is /var/lib/roundcube/, but plugins
# and skins installed via apt go to /usr/share/roundcube/. Phase 5 set up
# symlinks for the core dirs (program, plugins, skins) so /var/lib/roundcube/
# already has 'plugins' and 'skins' symlinks pointing at /usr/share/roundcube/.
#
# However, Roundcube's plugin loader looks for individual plugin directories
# under /var/lib/roundcube/plugins/<plugin-name>/. Even when 'plugins' is a
# symlink, the file resolves to /usr/share/roundcube/plugins/<plugin-name>/.
# This works for the bundled plugins because they were placed there by apt.
#
# RC+ plugins we copy into /usr/share/roundcube/plugins/ are visible too -
# IF the parent symlink is in place. For safety, also create per-plugin
# symlinks just in case the parent linking is incomplete on some installs.

for plugin in xframework xskin "${RC_PLUS_PLUGINS[@]}"; do
    SRC="$ROUNDCUBE_PLUGINS_DIR/$plugin"
    DST="/var/lib/roundcube/plugins/$plugin"
    if [ ! -d "$SRC" ]; then
        continue
    fi
    if [ -L "$DST" ] || [ -d "$DST" ]; then
        log_skip "Plugin symlink/dir $DST already exists"
    else
        ln -sf "$SRC" "$DST"
        log_done "Created symlink: $DST -> $SRC"
    fi
done

for skin in outlook outlook_plus; do
    SRC="$ROUNDCUBE_SKINS_DIR/$skin"
    DST="/var/lib/roundcube/skins/$skin"
    if [ ! -d "$SRC" ]; then
        continue
    fi
    if [ -L "$DST" ] || [ -d "$DST" ]; then
        log_skip "Skin symlink/dir $DST already exists"
    else
        ln -sf "$SRC" "$DST"
        log_done "Created symlink: $DST -> $SRC"
    fi
done

# ============================================================================
# STEP 6c: Apply xskin customizations
# ============================================================================
step "Step 6c: Applying xskin customizations"

# Customizations applied to make the webmail look "Outlook-like" with Docent
# IMS branding. Each setting is applied idempotently: if it exists in the
# config, replace; if not, append.
#
# IMPORTANT NOTES from real-world install:
# - xskin_color must be a 6-char hex WITHOUT the '#' prefix. xskin.php
#   validates strlen($color) == 6 and rejects 7-char strings like '#00829a'.
# - The chosen color must be in the xskin_colors palette array AND match a
#   precompiled .xcolor-XXXXXX class in the active skin's styles.css. The
#   18 colors below are the built-in palette compiled into outlook_plus.
# - Setting xskin_color_<skin> is the strongest override (per-skin), checked
#   before the global xskin_color fallback.

XSKIN_CONFIG="$ROUNDCUBE_PLUGINS_DIR/xskin/config.inc.php"

apply_setting() {
    local file="$1"
    local key="$2"
    local value="$3"

    # Match lines like: $config['key'] = anything;
    if grep -qE "^\$config\\['$key'\\]" "$file" 2>/dev/null; then
        sed -i "s|^\$config\\['$key'\\].*|\$config['$key'] = $value;|" "$file"
        echo "  Updated \$config['$key']"
    else
        echo "\$config['$key'] = $value;" >> "$file"
        echo "  Appended \$config['$key']"
    fi
}

if [ -f "$XSKIN_CONFIG" ]; then
    # Branding controls
    apply_setting "$XSKIN_CONFIG" "remove_vendor_branding" "true"
    apply_setting "$XSKIN_CONFIG" "disable_menu_skins" "true"
    apply_setting "$XSKIN_CONFIG" "disable_menu_languages" "true"
    apply_setting "$XSKIN_CONFIG" "preview_branding" \
        "'https://${DOMAIN}/branding/docent-watermark.png'"

    # Brand color (Docent teal). Must match a precompiled .xcolor-XXXXXX
    # class in the active skin. We set both the global default and the
    # per-skin override for outlook_plus.
    apply_setting "$XSKIN_CONFIG" "xskin_color" "'00829a'"
    apply_setting "$XSKIN_CONFIG" "xskin_color_outlook_plus" "'00829a'"
    apply_setting "$XSKIN_CONFIG" "disable_colors" "true"

    # Palette of valid colors - validator rejects anything not in this list.
    # These are the 18 colors compiled into outlook_plus's _colors.scss.
    if ! grep -q "^\$config\\['xskin_colors'\\]" "$XSKIN_CONFIG"; then
        cat >> "$XSKIN_CONFIG" <<'PALETTE'
$config['xskin_colors'] = [
    'df5aad', 'b0263b', 'd74c1b', 'ff9022', '83b600', '00860e',
    '00b2b3', '00829a', '0075c8', '47b4ff', '3c2cb6', '8d2297',
    '004e8d', '001b41', '5a0600', '3a0300', '585858', '000000',
];
PALETTE
        echo "  Appended \$config['xskin_colors'] palette"
    fi

    log_done "Applied xskin customizations to $XSKIN_CONFIG"
else
    log_warn "xskin config not found - skipping customizations"
fi

# ============================================================================
# STEP 6d: Configure Roundcube branding (skin_logo) and folder ordering
# ============================================================================
step "Step 6d: Configuring Roundcube skin_logo and folder ordering"

# Add 'xskin' to the plugins array if not already there. Phase 5 only
# enabled archive/zipdownload/managesieve; xai/xsignature came in Step 6;
# and xskin is required by RC+ skins per its README.
for plugin in xskin; do
    if grep -q "'$plugin'" "$ROUNDCUBE_CONFIG"; then
        echo "  Plugin $plugin already in \$config['plugins']"
    else
        sed -i "/\\\$config\\['plugins'\\]/,/^\\];/{ /^\\];/i\\
    '$plugin',
}" "$ROUNDCUBE_CONFIG"
        echo "  Added '$plugin' to \$config['plugins']"
    fi
done

# Branding logo - one logo for login page, top-bar, and avatar circle.
# Path is served by the per-domain WordPress vhost.
#
# IMPORTANT: skin_logo array keys MUST include a skin-name prefix followed
# by a colon, per Roundcube docs. Bare keys like '*' or 'login' do NOT
# reliably resolve - the lookup falls through to the global '*' fallback,
# which is why the login splash logo wasn't showing in earlier builds even
# though the small icon worked.
#
# Lookup order (most-specific to least): outlook_plus:login -> outlook_plus:*
# -> *:login -> *. We provide all four so any context renders the right logo.
if ! grep -q "skin_logo" "$ROUNDCUBE_CONFIG"; then
    cat >> "$ROUNDCUBE_CONFIG" <<EOF

// Branding logo - per-skin, per-template resolution.
//   outlook_plus:login = login page splash (full wordmark, looks correct large)
//   outlook_plus:*     = compact slot in outlook_plus (top-bar, avatar circle).
//                        Use the square icon - the wide wordmark gets crushed.
//   *:login            = fallback for any other skin's login page
//   *                  = global fallback (compact icon)
// Images live at /srv/www/${DOMAIN}/branding/.
\$config['skin_logo'] = [
    'outlook_plus:login' => 'https://${DOMAIN}/branding/docent-logo.svg',
    'outlook_plus:*'     => 'https://${DOMAIN}/branding/docent-icon.svg',
    '*:login'            => 'https://${DOMAIN}/branding/docent-logo.svg',
    '*'                  => 'https://${DOMAIN}/branding/docent-icon.svg',
];
EOF
    # Verify the heredoc actually wrote what we expected. Heredocs under
    # set -u can silently fail (write zero bytes) if any unescaped $word
    # in the body references an unbound variable. Grep for a unique marker
    # from the body; if it's not there, the heredoc didn't actually write.
    if grep -q "skin_logo" "$ROUNDCUBE_CONFIG"; then
        echo "  Appended \$config['skin_logo']"
    else
        echo "  ERROR: heredoc failed to write \$config['skin_logo'] to $ROUNDCUBE_CONFIG"
        echo "  (heredoc body may contain an unescaped \$word - check for unbound vars)"
        exit 1
    fi
fi

# Update sent_mbox to "Sent Items" (Outlook convention)
sed -i "s|^\$config\\['sent_mbox'\\].*|\$config['sent_mbox']   = 'Sent Items';|" \
    "$ROUNDCUBE_CONFIG"

# Update junk_mbox to point at "Spam" (the actual folder name created by
# Phase 4's Sieve config). Phase 4 had a mismatch: Sieve delivers to "Spam"
# but Roundcube was told to look at "Junk". Fixed here.
sed -i "s|^\$config\\['junk_mbox'\\].*|\$config['junk_mbox']   = 'Spam';|" \
    "$ROUNDCUBE_CONFIG"

# Set folder display order: Inbox, Sent Items, Drafts, Spam, Trash
if grep -q "default_folders" "$ROUNDCUBE_CONFIG"; then
    sed -i "s|^\$config\\['default_folders'\\].*|\$config['default_folders'] = ['INBOX', 'Sent Items', 'Drafts', 'Spam', 'Trash'];|" "$ROUNDCUBE_CONFIG"
else
    echo "\$config['default_folders'] = ['INBOX', 'Sent Items', 'Drafts', 'Spam', 'Trash'];" >> "$ROUNDCUBE_CONFIG"
fi

# Validate resulting PHP
if ! php -l "$ROUNDCUBE_CONFIG" > /dev/null 2>&1; then
    log_fail "Roundcube config has PHP syntax errors after edits"
    php -l "$ROUNDCUBE_CONFIG" 2>&1 | tail -5
    exit 1
fi

log_done "Updated Roundcube config (skin_logo, sent_mbox, junk_mbox, folder order)"

# ============================================================================
# STEP 6e: Inject CSS override to hide compose-page right-hand options pane
# ============================================================================
step "Step 6e: Hiding compose-page right-hand options pane"

# The outlook_plus skin inherits from the LARRY skin (not Elastic - an
# earlier version of this comment got this wrong, which led to the CSS
# targeting nonexistent IDs). Larry's compose template renders a right-
# hand pane containing 'Options and attachments': Return receipt,
# Delivery status notification, Keep formatting, Priority dropdown,
# Save sent message in dropdown, and a dashed file-drop zone. User
# wants this entire pane hidden to maximize compose-area real estate.
# The Attach button in the top toolbar still works (opens upload dialog).
#
# Approach: drop a custom CSS file into the outlook_plus skin's styles
# directory, and register it via the skin's meta.json "links.stylesheet"
# array. We use Python to edit meta.json safely (JSON parse/modify/write)
# rather than text-mangling it - text edits to JSON break too easily.

CUSTOM_CSS="/usr/share/roundcube/skins/outlook_plus/assets/styles/docent-overrides.css"
CUSTOM_CSS_REL="/assets/styles/docent-overrides.css"
SKIN_META="/usr/share/roundcube/skins/outlook_plus/meta.json"

# Note: outlook_plus stores its own CSS in /assets/styles/ (e.g.
# styles.css), so we put our override file there too. An earlier
# version of this script tried /usr/share/roundcube/skins/outlook_plus
# /styles/ - that directory doesn't exist in outlook_plus, only in
# the parent Elastic skin, so Step 6e silently warned-and-skipped
# without ever writing the CSS. Diagnosed May 14 2026.

if [ ! -d "$(dirname "$CUSTOM_CSS")" ]; then
    log_warn "outlook_plus assets/styles dir not found - skipping compose-pane CSS override"
elif [ ! -f "$SKIN_META" ]; then
    log_warn "outlook_plus meta.json not found - skipping compose-pane CSS override"
else
    # Write the CSS file (regenerated each run - idempotent)
    cat > "$CUSTOM_CSS" <<'EOF'
/* Docent overrides - applied by phase 5a, regenerated on each run.
 * Per-server customizations to the outlook_plus skin.
 *
 * Hide the right-hand "Options and attachments" pane on the compose
 * page and expand the message body into the freed space. The Attach
 * button in the top toolbar still works (opens upload dialog), so
 * file attachments remain accessible. The options panel contents
 * (Return receipt, Delivery status, Keep formatting, Priority,
 * Save-sent-folder) and the dashed file-drop zone are deliberately
 * removed to maximize the compose-body area.
 *
 * Verified by browser DevTools inspection on a live outlook_plus
 * build (May 14 2026):
 *   #compose-options      - the toggles (Return receipt, Priority,
 *                           etc.); NOTE the hyphen - earlier guesses
 *                           used #composeoptions (no hyphen) which
 *                           does not exist in the DOM.
 *   #compose-attachments  - the dashed drop-zone "Attach a file" panel.
 *   #layout-sidebar       - the outer pane containing the "Options
 *                           and attachments" header; hidden so that
 *                           text doesn't remain visible above the
 *                           now-empty area.
 *   #layout-content       - the main compose-area container; the
 *                           skin's CSS leaves space on the right for
 *                           #layout-sidebar (rect-width 1714 of 2560
 *                           on a typical desktop). We force this
 *                           container to fill all the way to the
 *                           right edge so there is no vertical line
 *                           where the sidebar used to be. Earlier
 *                           attempts targeted #composebodycontainer
 *                           directly with `right: 0` but that element
 *                           has position:relative (not absolute), so
 *                           `right` does nothing - the real constraint
 *                           is on its ancestor #layout-content.
 *
 * Scoped to body.task-mail.action-compose so we only affect the
 * compose page, not inbox or settings.
 */
body.task-mail.action-compose #compose-options {
    display: none !important;
}
body.task-mail.action-compose #compose-attachments {
    display: none !important;
}
body.task-mail.action-compose #layout-sidebar {
    display: none !important;
}
body.task-mail.action-compose #layout-content {
    right: 0 !important;
    width: auto !important;
}
EOF
    chown root:www-data "$CUSTOM_CSS"
    chmod 644 "$CUSTOM_CSS"
    log_done "Wrote $CUSTOM_CSS"

    # Register the CSS in meta.json's links.stylesheet array.
    # Python is the safe way to edit JSON in-place.
    python3 - "$SKIN_META" "$CUSTOM_CSS_REL" <<'PYEOF'
import json
import sys
import os

meta_path = sys.argv[1]
css_rel = sys.argv[2]

with open(meta_path) as f:
    meta = json.load(f)

# Ensure links.stylesheet is an array containing our CSS
links = meta.setdefault("links", {})
sheets = links.get("stylesheet")

if sheets is None:
    links["stylesheet"] = [css_rel]
elif isinstance(sheets, str):
    # Existing single string - convert to list and add ours if missing
    if sheets != css_rel:
        links["stylesheet"] = [sheets, css_rel]
elif isinstance(sheets, list):
    # Existing list - add ours if missing (idempotent)
    if css_rel not in sheets:
        sheets.append(css_rel)
else:
    # Unexpected type - bail out without touching the file
    print(f"ERROR: links.stylesheet has unexpected type {type(sheets).__name__}", file=sys.stderr)
    sys.exit(1)

# Atomic write: write to temp file, then rename
tmp = meta_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(meta, f, indent=4)
os.replace(tmp, meta_path)
print(f"  meta.json updated: links.stylesheet now includes {css_rel}")
PYEOF

    if [ $? -eq 0 ]; then
        log_done "Registered $CUSTOM_CSS_REL in $SKIN_META"
    else
        log_fail "Failed to update $SKIN_META"
        exit 1
    fi
fi

# ============================================================================
# STEP 6f: Install branding assets
# ============================================================================
step "Step 6f: Installing branding assets"

# Branding assets (logo, watermark) are served by the WordPress/Apache vhost
# at /srv/www/<DOMAIN>/branding/. Sources are in this repo at
# branding/<DOMAIN>/ so each server can have its own brand identity.

BRANDING_REPO="$REPO_ROOT/branding/$DOMAIN"
BRANDING_DEFAULT="$REPO_ROOT/branding/_default"
BRANDING_INSTALL="/srv/www/$DOMAIN/branding"

# Pick per-domain branding if it exists, otherwise fall back to _default.
# Per-domain dirs override _default file-by-file via a two-pass rsync below.
if [ -d "$BRANDING_REPO" ]; then
    BRANDING_SRC="$BRANDING_REPO"
    BRANDING_SRC_LABEL="per-domain ($DOMAIN)"
elif [ -d "$BRANDING_DEFAULT" ]; then
    BRANDING_SRC="$BRANDING_DEFAULT"
    BRANDING_SRC_LABEL="_default"
else
    BRANDING_SRC=""
fi

if [ -n "$BRANDING_SRC" ]; then
    mkdir -p "$BRANDING_INSTALL"
    # First pass: lay down _default if it exists (baseline)
    if [ -d "$BRANDING_DEFAULT" ]; then
        rsync -a "$BRANDING_DEFAULT/" "$BRANDING_INSTALL/"
    fi
    # Second pass: per-domain overrides on top (only if different from _default)
    if [ -d "$BRANDING_REPO" ]; then
        rsync -a "$BRANDING_REPO/" "$BRANDING_INSTALL/"
    fi
    chown -R www-data:www-data "$BRANDING_INSTALL"
    find "$BRANDING_INSTALL" -type d -exec chmod 755 {} \;
    find "$BRANDING_INSTALL" -type f -exec chmod 644 {} \;
    BRAND_COUNT=$(find "$BRANDING_INSTALL" -type f | wc -l)
    log_done "Installed $BRAND_COUNT branding asset(s) to $BRANDING_INSTALL (source: $BRANDING_SRC_LABEL)"
else
    log_warn "No branding source found at $BRANDING_REPO or $BRANDING_DEFAULT - skipping"
fi

# ============================================================================
# STEP 6f: Rename "Sent" mailbox to "Sent Items" for existing users
# ============================================================================
step "Step 6f: Renaming Sent -> Sent Items in user mailboxes"

# Loop through every Dovecot user and rename the Sent folder if it exists.
# This is idempotent: skips users where Sent doesn't exist or where Sent
# Items already exists.
USERS=$(doveadm user '*' 2>/dev/null | head -30)
if [ -z "$USERS" ]; then
    log_skip "No Dovecot users to rename yet (mailbox rename runs on next phase 5a execution after users are created)"
else
    for u in $USERS; do
        if doveadm mailbox list -u "$u" 2>/dev/null | grep -qx "Sent"; then
            if ! doveadm mailbox list -u "$u" 2>/dev/null | grep -qx "Sent Items"; then
                doveadm mailbox rename -u "$u" Sent "Sent Items" 2>/dev/null \
                    && echo "  Renamed Sent -> Sent Items for $u" \
                    || echo "  Could not rename Sent for $u"
            fi
        fi
    done
    log_done "Mailbox rename pass complete"
fi

# ============================================================================
# STEP 6g: Install custom font (Aptos with Inter fallback)
# ============================================================================
step "Step 6g: Installing custom font and CSS overrides"

# Font strategy:
# 1. Aptos       (Windows 11 / Office 365 - locally installed on user's device)
# 2. Inter       (self-hosted woff2 files, downloaded if not already present)
# 3. Segoe UI    (Windows 10/11 fallback)
# 4. system-ui   (macOS / Linux fallback)
#
# Aptos is Microsoft proprietary and can't be hosted. Inter is the closest
# open-source visual match, OFL-licensed, and we self-host it.
#
# CSS file lives in xskin's assets/ dir so xskin's overwrite_css setting
# can find it via a relative path. Important: overwrite_css must be a path
# RELATIVE TO THE XSKIN PLUGIN DIR (assets/styles/docent-overrides.css).
# An absolute path or "plugins/xskin/..." prefix gets doubled by the
# plugin loader and 404s.

FONTS_INSTALL="$BRANDING_INSTALL/fonts"
INTER_FILES=(
    "Inter-Regular.woff2"
    "Inter-Italic.woff2"
    "Inter-Medium.woff2"
    "Inter-SemiBold.woff2"
    "Inter-Bold.woff2"
)
INTER_BASE_URL="https://rsms.me/inter/font-files"

# Download Inter font files if not already present in the repo
INTER_REPO_DIR="$REPO_ROOT/branding/$DOMAIN/fonts"
INTER_DEFAULT_DIR="$REPO_ROOT/branding/_default/fonts"

# Pick per-domain fonts if present, else _default. Both can be empty
# (the wget fallback below downloads into the chosen dir).
if [ -d "$INTER_REPO_DIR" ]; then
    INTER_SRC_DIR="$INTER_REPO_DIR"
elif [ -d "$INTER_DEFAULT_DIR" ]; then
    INTER_SRC_DIR="$INTER_DEFAULT_DIR"
else
    # Neither dir exists yet - create the _default one (baseline for all servers)
    INTER_SRC_DIR="$INTER_DEFAULT_DIR"
fi

if [ -d "$INTER_SRC_DIR" ] && [ "$(ls -A "$INTER_SRC_DIR" 2>/dev/null | grep -c .woff2)" -eq 5 ]; then
    log_skip "Inter fonts already in repo at $INTER_SRC_DIR"
else
    mkdir -p "$INTER_SRC_DIR"
    cd "$INTER_SRC_DIR"
    for f in "${INTER_FILES[@]}"; do
        if [ ! -f "$f" ]; then
            wget -q "$INTER_BASE_URL/$f" -O "$f"
            if [ -s "$f" ]; then
                log_done "Downloaded $f"
            else
                rm -f "$f"
                log_warn "Failed to download $f - font fallback chain still works without it"
            fi
        fi
    done
    cd - > /dev/null
fi

# Install fonts to the WordPress vhost branding dir
mkdir -p "$FONTS_INSTALL"
if [ -d "$INTER_SRC_DIR" ]; then
    rsync -a "$INTER_SRC_DIR/" "$FONTS_INSTALL/"
    chown -R www-data:www-data "$FONTS_INSTALL"
    chmod 644 "$FONTS_INSTALL"/*.woff2 2>/dev/null
    FONT_COUNT=$(find "$FONTS_INSTALL" -name "*.woff2" | wc -l)
    log_done "Installed $FONT_COUNT Inter font file(s) to $FONTS_INSTALL"
fi

# Install the CSS override file. It lives in xskin's assets dir so xskin's
# relative-path resolver finds it. Per-domain CSS overrides _default.
CSS_REPO="$REPO_ROOT/branding/$DOMAIN/docent-overrides.css"
CSS_DEFAULT="$REPO_ROOT/branding/_default/docent-overrides.css"
CSS_INSTALL="$ROUNDCUBE_PLUGINS_DIR/xskin/assets/styles/docent-overrides.css"

if [ -f "$CSS_REPO" ]; then
    cp "$CSS_REPO" "$CSS_INSTALL"
    chown root:www-data "$CSS_INSTALL"
    chmod 640 "$CSS_INSTALL"
    log_done "Installed CSS overrides at $CSS_INSTALL (source: per-domain)"
elif [ -f "$CSS_DEFAULT" ]; then
    cp "$CSS_DEFAULT" "$CSS_INSTALL"
    chown root:www-data "$CSS_INSTALL"
    chmod 640 "$CSS_INSTALL"
    log_done "Installed CSS overrides at $CSS_INSTALL (source: _default)"
else
    log_skip "No CSS overrides found at $CSS_REPO or $CSS_DEFAULT - skinning unmodified (optional)"
fi

# Configure xskin to load our CSS file. Path is relative to the xskin plugin dir.
apply_setting "$XSKIN_CONFIG" "overwrite_css" "'assets/styles/docent-overrides.css'"

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
echo "  PHASE 5a COMPLETE - SUMMARY REPORT"
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

# All required directories present (xai is in phase 5c, not here)
for d in xframework xskin xsignature; do
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
if sudo -u www-data test -r "$ROUNDCUBE_PLUGINS_DIR/xsignature/config.inc.php" 2>/dev/null; then
    vp "www-data can read xsignature config"
else
    vf "www-data CANNOT read xsignature config"
fi

# secrets.local is properly secured
SECRETS_FILE="$REPO_ROOT/secrets.local"
if [ -f "$SECRETS_FILE" ]; then
    PERMS=$(stat -c '%a' "$SECRETS_FILE")
    if [ "$PERMS" = "600" ]; then
        vp "secrets.local mode 600 (owner-only)"
    else
        vf "secrets.local has permissions $PERMS (should be 600)"
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

  1. Open https://${DOMAIN}/mail/ in your browser (or hard-refresh
     if you already had it open) and log in.

  2. The interface should now use the "outlook_plus" skin (Outlook-style
     navigation, modern layout, mobile-capable).

  3. Verify the plugin works:
       - Signature Designer (xsignature): go to Settings -> Identities -> edit
         your identity. There should now be a richer signature editor than
         the default plain text box.

  4. Check for any plugin errors:
       sudo tail /var/log/roundcube/errors.log
       sudo tail /var/log/apache2/error.log

  5. AI Assistant (xai) is installed by Phase 5c (Email AI), not this phase.
     Run that next if you want AI features in Roundcube.

  Re-running this script is safe - it preserves any plugin-specific config
  customizations you make in plugins/<plugin>/config.inc.php.

EOF
echo "==================================================================="

if [ "$VERIFY_FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
