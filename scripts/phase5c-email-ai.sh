#!/bin/bash
#
# phase5c-email-ai.sh - Phase 5c: AI Assistant (xai plugin from Roundcube Plus)
#
# Installs and configures the xai plugin which provides:
#   - AI Composer:  user clicks an AI button in compose, picks style/length/
#                   language and instructions, gets a drafted email
#   - AI Summary:   one-sentence summary at the top of opened emails
#
# Provider: OpenAI (GPT-4o-mini). The xai plugin only supports openai or
# ollama. Anthropic Claude is NOT directly supported by xai because xai
# uses OpenAI's request schema and there is no openai_url override option.
#
# License: xai is a commercial plugin. The license key is the same RC+
# license already added to /etc/roundcube/config.inc.php by phase 5a.
# This script does NOT add a separate license key.
#
# API key: read from XAI_API_KEY in secrets.local (collected by phase 0).
# If the key is empty/missing, the script still installs the plugin and
# writes config, but warns that AI features won't work until the key is
# filled in manually at /usr/share/roundcube/plugins/xai/config.inc.php.
#
# Cost notes (for ~20 users sending ~30 emails/day on gpt-4o-mini):
#   - Composer only:           ~$1-3/month
#   - Composer + view summary: ~$4-7/month
#   - Plus list-hover summary: significantly more (xai's own warning),
#                              not enabled here.
#
# Idempotent. Safe to re-run.
#
# Run as root: sudo bash phase5c-email-ai.sh
#

set -u

# ============================================================================
# CONFIGURATION
# ============================================================================
ROUNDCUBE_CONFIG=/etc/roundcube/config.inc.php
ROUNDCUBE_PLUGINS_DIR=/usr/share/roundcube/plugins
ROUNDCUBE_PLUGINS_LOAD=/var/lib/roundcube/plugins

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
VENDOR_DIR="$REPO_ROOT/vendor/roundcube-plus"
XAI_TARBALL="$VENDOR_DIR/roundcube_plus_plugin_xai.tar.gz"

# What we configure xai to use
OPENAI_MODEL="gpt-4o-mini"

# Load shared helpers and per-tenant config. lib/common.sh sources
# tenant.local/secrets.local (overriding the hardcoded defaults above) and
# provides colors, logging helpers, and verification helpers.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

# XAI_API_KEY is what phase 0 collects. Default to empty so the script can
# still run (and warn) when the user hasn't supplied a real key yet.
: "${XAI_API_KEY:=}"


# ============================================================================
# REPORT TRACKING
# ============================================================================
REPORT=()


# ============================================================================
# SAFETY CHECKS
# ============================================================================
if [ "$(id -u)" -ne 0 ]; then
    echo "${RED}ERROR: This script must be run as root (use sudo).${RESET}"
    exit 1
fi

if [ ! -f "$ROUNDCUBE_CONFIG" ]; then
    echo "${RED}ERROR: $ROUNDCUBE_CONFIG not found. Phase 5 must run first.${RESET}"
    exit 1
fi

if [ ! -f "$XAI_TARBALL" ]; then
    echo "${RED}ERROR: xai tarball not found at $XAI_TARBALL${RESET}"
    echo "       Expected to be in vendor/ (committed to repo)."
    exit 1
fi

# ============================================================================
# BANNER
# ============================================================================
echo "${BOLD}${CYAN}===================================================================${RESET}"
echo "${BOLD}${CYAN}  Phase 5c - AI Assistant (xai plugin)${RESET}"
echo "${BOLD}${CYAN}  Provider: OpenAI    Model: $OPENAI_MODEL${RESET}"
if [ -n "$XAI_API_KEY" ]; then
    # Show only first 6 and last 4 chars of the key, never the whole thing
    keylen=${#XAI_API_KEY}
    if [ "$keylen" -gt 12 ]; then
        masked="${XAI_API_KEY:0:6}...${XAI_API_KEY: -4}"
    else
        masked="(${keylen} chars - looks too short, please verify)"
    fi
    echo "${BOLD}${CYAN}  API key: $masked  (from secrets.local)${RESET}"
else
    echo "${BOLD}${YELLOW}  API key: NOT SET - AI features will not work until configured${RESET}"
fi
echo "${BOLD}${CYAN}  $(date)${RESET}"
echo "${BOLD}${CYAN}===================================================================${RESET}"

# ============================================================================
# STEP 1: Extract xai from the vendor tarball
# ============================================================================
step "Step 1: Extracting xai from vendor tarball"

STAGING=$(mktemp -d /tmp/xai-staging.XXXXXX)
trap 'rm -rf "$STAGING"' EXIT

if tar -xzf "$XAI_TARBALL" -C "$STAGING" 2>/dev/null; then
    log_done "Extracted xai tarball to staging area"
else
    log_fail "Failed to extract $XAI_TARBALL"
    exit 1
fi

if [ ! -d "$STAGING/xai" ]; then
    log_fail "Expected $STAGING/xai/ after extraction; not found"
    exit 1
fi

# ============================================================================
# STEP 2: Install xai into Roundcube's plugin directory
# ============================================================================
step "Step 2: Installing xai plugin"

XAI_TARGET="$ROUNDCUBE_PLUGINS_DIR/xai"
if [ -d "$XAI_TARGET" ]; then
    log_skip "xai already installed at $XAI_TARGET - updating files (preserving config)"
    rsync -a --exclude='config.inc.php' "$STAGING/xai/" "$XAI_TARGET/"
else
    cp -a "$STAGING/xai" "$ROUNDCUBE_PLUGINS_DIR/"
    log_done "Copied xai to $XAI_TARGET/"
fi

# ============================================================================
# STEP 3: Activate config.inc.php from the .dist template
# ============================================================================
step "Step 3: Activating xai config"

XAI_CONFIG="$XAI_TARGET/config.inc.php"
XAI_CONFIG_DIST="$XAI_TARGET/config.inc.php.dist"

if [ -f "$XAI_CONFIG" ]; then
    log_skip "config.inc.php exists (preserving customizations)"
elif [ -f "$XAI_CONFIG_DIST" ]; then
    cp "$XAI_CONFIG_DIST" "$XAI_CONFIG"
    log_done "Activated config.inc.php from .dist template"
else
    log_fail "Neither config.inc.php nor config.inc.php.dist found"
    exit 1
fi

# Set ownership and permissions: root:www-data 640 (apache reads it)
chown root:www-data "$XAI_CONFIG"
chmod 640 "$XAI_CONFIG"
log_done "Set xai config ownership root:www-data 640"

# ============================================================================
# STEP 4: Apply our settings to xai config (idempotent sed-based edits)
# ============================================================================
step "Step 4: Configuring xai for OpenAI gpt-4o-mini"

# Backup before editing
cp "$XAI_CONFIG" "$XAI_CONFIG.phase5c.bak"

# Helper: set a $config['key'] = value; line, replacing if present.
# Args: 1=key 2=php_value (already-quoted PHP literal like 'openai' or true)
set_xai_config() {
    local key="$1"
    local val="$2"
    # Match any line setting this config key (with various whitespace/value)
    if grep -qE "^\s*\\\$config\\['$key'\\]\s*=" "$XAI_CONFIG"; then
        # Replace existing line (preserve any leading whitespace / comments before it)
        sed -i -E "s|^(\s*)\\\$config\\['$key'\\]\s*=.*|\\1\$config['$key'] = $val;|" "$XAI_CONFIG"
        echo "  Updated \$config['$key'] = $val"
    else
        # Append at the end
        echo "\$config['$key'] = $val;" >> "$XAI_CONFIG"
        echo "  Appended \$config['$key'] = $val"
    fi
}

# Provider: OpenAI
set_xai_config "xai_provider"             "'openai'"

# Model: gpt-4o-mini (cheap, sufficient for email tasks)
set_xai_config "xai_openai_model"         "'$OPENAI_MODEL'"

# API key: from secrets.local, or null if unset
if [ -n "$XAI_API_KEY" ]; then
    # PHP-escape: API keys are alphanumeric+dash+underscore, but be paranoid
    escaped_key=$(echo "$XAI_API_KEY" | sed "s/'/\\\\'/g")
    set_xai_config "xai_openai_api_key"   "'$escaped_key'"
else
    set_xai_config "xai_openai_api_key"   "null"
fi

# Composer: ON (already default but be explicit)
set_xai_config "xai_enable_message_generation" "true"

# View summaries: feature ENABLED but per-user default OFF.
#
# Two separate xai settings control this:
#
#   xai_enable_view_summaries   - master switch. If true, the feature
#                                 EXISTS and users can toggle it in
#                                 Roundcube settings -> Mail -> AI features.
#                                 If false, the feature is invisible to users.
#                                 We want true so users CAN turn it on if
#                                 they choose.
#
#   xai_show_summary_on_mail_view - the per-user DEFAULT for that toggle.
#                                 If true, every email a user opens triggers
#                                 an OpenAI API call (cached encrypted in DB
#                                 after first generation, but the first hit
#                                 costs every time). If false, users see a
#                                 "Show summary" link instead and only pay
#                                 for the calls they actually want.
#                                 We want false because every-email-by-default
#                                 racks up real costs (~\$30-180/mo for 20 users
#                                 reading 30 emails/day each).
#
# Net effect: feature is fully available, users discover it in settings,
# but no automatic API calls happen until a user opts in.
set_xai_config "xai_enable_view_summaries"     "true"
set_xai_config "xai_show_summary_on_mail_view" "false"

# List-hover summaries: OFF. xai's own docs warn this "may significantly
# increase API costs" because it generates summaries for every email in
# the inbox list. View-summaries (above) is plenty.
set_xai_config "xai_enable_list_summaries"     "false"
set_xai_config "xai_show_summary_on_list_hover" "false"

# Validate the resulting file is still valid PHP
if ! php -l "$XAI_CONFIG" >/dev/null 2>&1; then
    log_fail "xai config has PHP syntax errors after edit - restoring backup"
    php -l "$XAI_CONFIG" 2>&1 | tail -5
    cp "$XAI_CONFIG.phase5c.bak" "$XAI_CONFIG"
    exit 1
fi
log_done "xai config validated as PHP-clean"

# ============================================================================
# STEP 5: Symlink xai into Debian's plugin load path
# ============================================================================
step "Step 5: Symlinking xai for Roundcube discovery"

XAI_LOAD_LINK="$ROUNDCUBE_PLUGINS_LOAD/xai"
if [ -L "$XAI_LOAD_LINK" ]; then
    log_skip "Load-path symlink already exists"
elif [ -e "$XAI_LOAD_LINK" ]; then
    log_warn "$XAI_LOAD_LINK exists but is not a symlink; leaving as-is"
else
    ln -s "$XAI_TARGET" "$XAI_LOAD_LINK"
    log_done "Symlinked $XAI_LOAD_LINK -> $XAI_TARGET"
fi

# ============================================================================
# STEP 6: Add xai to Roundcube's $config['plugins'] array
# ============================================================================
step "Step 6: Registering xai in Roundcube plugins array"

if grep -q "'xai'" "$ROUNDCUBE_CONFIG"; then
    log_skip "xai already in \$config['plugins']"
else
    # Insert before the closing ]; of the plugins array. Same pattern as
    # phase 5a uses for xsignature/xskin.
    sed -i "/\\\$config\\['plugins'\\]/,/^\\];/{ /^\\];/i\\
    'xai',
}" "$ROUNDCUBE_CONFIG"

    if grep -q "'xai'" "$ROUNDCUBE_CONFIG"; then
        log_done "Added 'xai' to \$config['plugins']"
    else
        log_fail "Failed to add 'xai' to \$config['plugins']"
        exit 1
    fi
fi

# Validate the resulting Roundcube config is still valid PHP
if ! php -l "$ROUNDCUBE_CONFIG" >/dev/null 2>&1; then
    log_fail "Roundcube config has PHP syntax errors after edit - check manually"
    php -l "$ROUNDCUBE_CONFIG" 2>&1 | tail -5
    exit 1
fi
log_done "Roundcube config validated as PHP-clean"

# ============================================================================
# STEP 7: Set ownership/permissions on the plugin directory
# ============================================================================
step "Step 7: Setting xai directory ownership and permissions"

# Plugin source directory: root:www-data, dirs 750, files 640
chown -R root:www-data "$XAI_TARGET"
find "$XAI_TARGET" -type d -exec chmod 750 {} \;
find "$XAI_TARGET" -type f -exec chmod 640 {} \;
log_done "Set ownership and permissions on $XAI_TARGET"

# ============================================================================
# STEP 8: Reload Apache
# ============================================================================
step "Step 8: Reloading Apache"

if apache2ctl configtest >/dev/null 2>&1; then
    if systemctl reload apache2; then
        log_done "Apache config valid, reloaded"
    else
        log_fail "Apache reload failed"
        exit 1
    fi
else
    log_fail "Apache config test failed - not reloading"
    apache2ctl configtest
    exit 1
fi

# ============================================================================
# SUMMARY REPORT
# ============================================================================
echo ""
echo "${BOLD}${CYAN}===================================================================${RESET}"
echo "${BOLD}${CYAN}  PHASE 5c COMPLETE - SUMMARY REPORT${RESET}"
echo "${BOLD}${CYAN}===================================================================${RESET}"
echo ""
for line in "${REPORT[@]}"; do
    echo "  $line"
done

# ============================================================================
# AUTOMATED VERIFICATION
# ============================================================================
echo ""
echo "${BOLD}${CYAN}===================================================================${RESET}"
echo "${BOLD}${CYAN}  AUTOMATED VERIFICATION${RESET}"
echo "${BOLD}${CYAN}===================================================================${RESET}"
echo ""

VERIFY_PASS=0
VERIFY_FAIL=0

vp() { echo "  ${GREEN}[PASS]${RESET} $1"; VERIFY_PASS=$((VERIFY_PASS + 1)); }
vf() { echo "  ${RED}[FAIL]${RESET} $1"; VERIFY_FAIL=$((VERIFY_FAIL + 1)); }

# Plugin files in place
if [ -d "$XAI_TARGET" ]; then
    vp "Plugin directory $XAI_TARGET exists"
else
    vf "Plugin directory $XAI_TARGET MISSING"
fi

if [ -f "$XAI_TARGET/config.inc.php" ]; then
    vp "Plugin config exists"
else
    vf "Plugin config MISSING"
fi

if php -l "$XAI_CONFIG" >/dev/null 2>&1; then
    vp "xai config is valid PHP"
else
    vf "xai config has PHP syntax errors"
fi

if php -l "$ROUNDCUBE_CONFIG" >/dev/null 2>&1; then
    vp "Roundcube main config is valid PHP"
else
    vf "Roundcube main config has PHP syntax errors"
fi

# Provider/model wired correctly
if grep -qE "^\\\$config\\['xai_provider'\\]\s*=\s*'openai'" "$XAI_CONFIG"; then
    vp "Provider set to openai"
else
    vf "Provider NOT set to openai"
fi

if grep -qE "^\\\$config\\['xai_openai_model'\\]\s*=\s*'$OPENAI_MODEL'" "$XAI_CONFIG"; then
    vp "Model set to $OPENAI_MODEL"
else
    vf "Model NOT set to $OPENAI_MODEL"
fi

# API key present (or warn if not)
if grep -qE "^\\\$config\\['xai_openai_api_key'\\]\s*=\s*'[^']+'" "$XAI_CONFIG"; then
    vp "API key is set in xai config"
elif grep -qE "^\\\$config\\['xai_openai_api_key'\\]\s*=\s*null" "$XAI_CONFIG"; then
    vf "API key is null - AI features will not work until set"
else
    vf "Cannot determine API key state in xai config"
fi

# Feature flags
if grep -qE "^\\\$config\\['xai_enable_message_generation'\\]\s*=\s*true" "$XAI_CONFIG"; then
    vp "AI Composer enabled"
else
    vf "AI Composer NOT enabled"
fi

if grep -qE "^\\\$config\\['xai_enable_view_summaries'\\]\s*=\s*true" "$XAI_CONFIG"; then
    vp "AI view summaries available (users can toggle in settings)"
else
    vf "AI view summaries NOT available"
fi

if grep -qE "^\\\$config\\['xai_show_summary_on_mail_view'\\]\s*=\s*false" "$XAI_CONFIG"; then
    vp "AI view summaries default is OFF (cost guard - users must opt in)"
else
    vf "AI view summaries default is ON - every opened email triggers an API call"
fi

if grep -qE "^\\\$config\\['xai_enable_list_summaries'\\]\s*=\s*false" "$XAI_CONFIG"; then
    vp "AI list-hover summaries disabled (cost guard)"
else
    vf "AI list-hover summaries NOT explicitly disabled (potential cost issue)"
fi

# Plugin registered + loadable
if grep -q "'xai'" "$ROUNDCUBE_CONFIG"; then
    vp "xai registered in Roundcube plugins array"
else
    vf "xai NOT registered in Roundcube plugins array"
fi

if [ -L "$XAI_LOAD_LINK" ]; then
    vp "Load-path symlink exists"
else
    vf "Load-path symlink missing"
fi

# Apache running
if systemctl is-active --quiet apache2; then
    vp "Apache is running"
else
    vf "Apache is NOT running"
fi

# www-data can read the xai config
if sudo -u www-data test -r "$XAI_CONFIG" 2>/dev/null; then
    vp "www-data can read xai config"
else
    vf "www-data CANNOT read xai config"
fi

echo ""
echo "  Verification: $VERIFY_PASS passed, $VERIFY_FAIL failed"
echo ""

# ============================================================================
# MANUAL VERIFICATION & NEXT STEPS
# ============================================================================
echo "${BOLD}${CYAN}===================================================================${RESET}"
echo "${BOLD}${CYAN}  MANUAL VERIFICATION & NEXT STEPS${RESET}"
echo "${BOLD}${CYAN}===================================================================${RESET}"

if [ -z "$XAI_API_KEY" ]; then
    cat <<EOF

  ${YELLOW}IMPORTANT: API key not set${RESET}

  Your secrets.local has XAI_API_KEY empty (or missing). The plugin is
  installed and configured, but AI features will fail until you set a
  real OpenAI API key.

  To finish setup:

  1. Get an API key from https://platform.openai.com/api-keys
     (You'll need to add credits to your account first - even a few
      dollars goes a long way with gpt-4o-mini.)

  2. Edit secrets.local:
       cd $REPO_ROOT
       chmod 600 secrets.local
       vi secrets.local
       # Set: XAI_API_KEY=sk-proj-...your-real-key...

  3. Re-run this phase:
       sudo bash $SCRIPT_DIR/$(basename "$0")
     It will pick up the new key and update xai's config.

EOF
fi

cat <<EOF

  1. Open Roundcube webmail and log in (hard-refresh if already open).

  2. AI Composer:
     - Click "Compose" to open the new-mail page
     - Look for an AI button or icon in the compose toolbar
     - Click it, fill in style/length/instructions, click Generate
     - You should get drafted email text inserted into the body

  3. AI Summary:
     - Open a longer email (more than a couple paragraphs)
     - You should see a one-sentence summary at the top
     - The first time may take a few seconds (cached in DB after that)

  4. If something doesn't work, check:
       sudo tail /var/log/roundcube/errors.log
       sudo tail /var/log/apache2/error.log

  5. To monitor your OpenAI spend:
       https://platform.openai.com/usage

  6. To turn AI features off later, edit:
       $XAI_CONFIG
     Set xai_enable_message_generation = false (or _view_summaries = false).
     Then: sudo systemctl reload apache2

  Re-running this script is safe. It preserves any plugin-specific
  config customizations you make in $XAI_CONFIG.

EOF
echo "${BOLD}${CYAN}===================================================================${RESET}"

if [ "$VERIFY_FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
