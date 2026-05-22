#!/bin/bash
#
# lib/common.sh - Shared helpers and configuration sourcing for all phase scripts
#
# This file should be sourced by each phase script after defining SCRIPT_DIR
# and REPO_ROOT. It provides:
#   - Configuration sourcing (tenant.local, secrets.local)
#   - Logging helpers (log_done, log_skip, log_warn, log_fail, step)
#   - Verification helpers (verify, verify_contains, verify_not_contains, verify_cmd)
#   - ANSI color definitions
#
# Usage in a phase script:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   REPO_ROOT="$(dirname "$SCRIPT_DIR")"
#   source "$SCRIPT_DIR/lib/common.sh"
#

# ============================================================================
# ERROR HANDLING
# ============================================================================
# Ensure SCRIPT_DIR and REPO_ROOT are defined before we proceed
if [ -z "${SCRIPT_DIR:-}" ] || [ -z "${REPO_ROOT:-}" ]; then
    echo "ERROR: lib/common.sh requires SCRIPT_DIR and REPO_ROOT to be defined by the calling script."
    exit 1
fi

# ============================================================================
# SOURCE CONFIGURATION
# ============================================================================
# Source per-tenant config and secrets if they exist. These files are created
# by phase0-bootstrap.sh. If they are not present, the hardcoded defaults
# in each phase script remain in effect (preserving original standalone behavior).

if [ -f "$REPO_ROOT/tenant.local" ]; then
    # shellcheck disable=SC1091
    source "$REPO_ROOT/tenant.local"
fi

if [ -f "$REPO_ROOT/secrets.local" ]; then
    # shellcheck disable=SC1091
    source "$REPO_ROOT/secrets.local"
fi

# ============================================================================
# COLORS (ANSI terminal codes)
# ============================================================================
if [ -t 1 ]; then
    RESET=$'\e[0m'
    BOLD=$'\e[1m'
    DIM=$'\e[2m'
    RED=$'\e[31m'
    GREEN=$'\e[32m'
    YELLOW=$'\e[33m'
    CYAN=$'\e[36m'
else
    RESET=""
    BOLD=""
    DIM=""
    RED=""
    GREEN=""
    YELLOW=""
    CYAN=""
fi

# ============================================================================
# LOGGING HELPERS
# ============================================================================

log_done() {
    REPORT+=("[DONE]    $1")
    echo "  ${GREEN}✓${RESET} $1"
}

log_skip() {
    REPORT+=("[SKIPPED] $1 (already done)")
    echo "  - $1 (already done)"
}

log_warn() {
    REPORT+=("[WARN]    $1")
    echo "  ${YELLOW}!${RESET} $1"
}

log_fail() {
    REPORT+=("[FAIL]    $1")
    echo "  ${RED}✗${RESET} $1"
}

step() {
    echo ""
    echo "${BOLD}=== $1 ===${RESET}"
}

# ============================================================================
# VERIFICATION HELPERS
# ============================================================================

# verify - compare expected vs actual values
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

# verify_contains - check if needle is in haystack
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

# verify_not_contains - check if needle is NOT in haystack
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

# verify_cmd - run a command and report pass/fail
verify_cmd() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "  [PASS] $description"
        VERIFY_PASS=$((VERIFY_PASS + 1))
    else
        echo "  [FAIL] $description"
        VERIFY_FAIL=$((VERIFY_FAIL + 1))
    fi
}
