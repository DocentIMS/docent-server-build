#!/bin/bash
#
# add-source-block.sh - One-time helper to inject the tenant.local/secrets.local
# source block into each phase script.
#
# This adds ~14 lines near the top of each phase script. The block sources
# tenant.local and secrets.local if they exist, allowing phase0 to override
# hardcoded values. If those files don't exist, the existing hardcoded
# defaults are used (preserving original behavior).
#
# Idempotent: re-running detects existing injection and skips it.
#
# After running this, commit and push to GitHub.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Phase scripts to modify
PHASE_SCRIPTS=(
    "phase1.sh"
    "phase2.sh"
    "phase3.sh"
    "phase4.sh"
    "phase5.sh"
    "phase5b-rc-plus.sh"
    "phase6.sh"
)

# The block we will inject. Marker comment lets us detect it on re-runs.
INJECT_MARKER="# === BEGIN tenant.local/secrets.local source block (added by phase0 design) ==="

read -r -d '' INJECT_BLOCK <<'INJECT_EOF' || true
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
INJECT_EOF

# ============================================================================
# PROCESS EACH PHASE SCRIPT
# ============================================================================
for script in "${PHASE_SCRIPTS[@]}"; do
    target="$SCRIPT_DIR/$script"

    if [ ! -f "$target" ]; then
        echo "  ! Skipping $script (not found)"
        continue
    fi

    if grep -qF "$INJECT_MARKER" "$target"; then
        echo "  - Skipping $script (block already injected)"
        continue
    fi

    # Find the line number of "# REPORT TRACKING" - this is our insertion anchor.
    # We insert the block 1 line BEFORE that (so it's the last thing in the
    # CONFIGURATION section, before REPORT TRACKING).
    anchor_line=$(grep -n "^# REPORT TRACKING" "$target" | head -1 | cut -d: -f1)

    if [ -z "$anchor_line" ]; then
        echo "  ! Skipping $script (no '# REPORT TRACKING' anchor found)"
        continue
    fi

    # We want to insert BEFORE the "# ====" line that's just above "# REPORT TRACKING".
    # That separator line is at anchor_line - 1.
    insert_at=$((anchor_line - 1))

    # Backup
    cp "$target" "$target.preinject.bak"

    # Use sed to insert the block before the calculated line.
    # We escape via a temp file to avoid shell-quoting nightmares.
    tmpfile=$(mktemp)
    {
        head -n $((insert_at - 1)) "$target"
        echo "$INJECT_BLOCK"
        echo ""
        tail -n +"$insert_at" "$target"
    } > "$tmpfile"

    mv "$tmpfile" "$target"
    chmod --reference="$target.preinject.bak" "$target"

    # Verify syntax
    if bash -n "$target" 2>/dev/null; then
        rm "$target.preinject.bak"
        echo "  + Injected into $script (syntax OK)"
    else
        # Restore backup if syntax broke
        mv "$target.preinject.bak" "$target"
        echo "  ! FAILED on $script - syntax error after injection. Restored backup."
    fi
done

echo ""
echo "Done. Verify with:"
echo "  grep -l 'BEGIN tenant.local' $SCRIPT_DIR/phase*.sh"