#!/bin/bash
#
# Phase 5c — Email AI (xai plugin from Roundcube Plus)
#
# STATUS: PLACEHOLDER — not yet implemented.
#
# This phase is the home for the xai plugin (AI Assistant in Roundcube Plus).
# It was previously installed by phase 5b alongside xsignature, but has been
# moved out into its own phase so that it can be developed and configured
# independently of the rest of the RC+ install.
#
# Intent and design notes for when this gets built out:
#
# 1. Install the xai plugin from vendor/roundcube-plus/plugin_xai.tar.gz.
#    The tarball is already present in the repo because phase 5a (rc-plus)
#    extracts xframework from it. xai itself is not currently installed.
#
# 2. Activate xai's config.inc.php from the .dist template, set ownership
#    root:www-data 640.
#
# 3. Symlink /usr/share/roundcube/plugins/xai into /var/lib/roundcube/plugins/
#    so Debian Roundcube can discover it.
#
# 4. Add 'xai' to $config['plugins'] in /etc/roundcube/config.inc.php.
#
# 5. Configure the AI provider. Phase 0 already collects an AI API key
#    (XAI_API_KEY in secrets.local). Wire it into xai's config.
#    - Pick provider (OpenAI, Anthropic, etc.)
#    - Pick default model (gpt-4o-mini, claude-haiku, etc.)
#    - Set rate limits / cost guardrails
#    - Decide which features to enable (compose helper, summarize, translate)
#
# 6. Verification: plugin loaded, www-data can read config, API key works
#    (do a tiny test call), error log is clean.
#
# Reasons this got its own phase rather than living in 5a:
#   - AI features have meaningfully different operational concerns from the
#     rest of RC+ (cost tracking, prompt engineering, model selection,
#     content filtering).
#   - Some clients won't want AI features at all. Separate phase = trivial
#     to skip.
#   - The xai config has more knobs than the other RC+ plugins combined.
#     Better to manage in isolation.
#
# Idempotent: when implemented, must be safe to re-run.
#
# Run as root: sudo bash phase5c-email-ai.sh
#

set -u

# ============================================================================
# CONFIGURATION
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# ============================================================================
# SAFETY CHECKS
# ============================================================================
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root (use sudo)."
    exit 1
fi

# ============================================================================
# STUB BEHAVIOR
# ============================================================================
echo ""
echo "==================================================================="
echo "  Phase 5c - Email AI (xai plugin)"
echo "==================================================================="
echo ""
echo "  STATUS: NOT YET IMPLEMENTED"
echo ""
echo "  This phase is a placeholder for the xai (AI Assistant) plugin"
echo "  installation. It will be filled in when AI features are needed."
echo ""
echo "  Until then, this script is a no-op and exits successfully."
echo "  Phase 6 (WordPress) will run next as if 5c had completed."
echo ""
echo "  Vendor tarball already in place:"
echo "    $REPO_ROOT/vendor/roundcube-plus/plugin_xai.tar.gz"
echo ""
echo "  AI API key (set in phase 0) is in secrets.local as XAI_API_KEY."
echo "  Phase 5c will read that when it is implemented."
echo ""
echo "==================================================================="
echo ""

exit 0
