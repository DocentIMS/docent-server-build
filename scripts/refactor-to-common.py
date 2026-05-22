#!/usr/bin/env python3
"""
refactor-to-common.py - Wire a phase script to lib/common.sh and remove the
duplicated boilerplate (inline tenant.local/secrets.local source block,
logging helpers, verify helpers).

Usage:  python3 scripts/refactor-to-common.py scripts/phase1.sh

Dev-time maintenance helper - NOT run on tenant servers. Idempotent:
re-running on an already-refactored file does nothing. Writes a .bak backup.
"""
import re
import shutil
import sys

# lib/common.sh sources tenant.local/secrets.local itself, so this must sit
# AFTER the hardcoded CONFIGURATION defaults - exactly where the old block was.
REPLACEMENT = """# Load shared helpers and per-tenant config. lib/common.sh sources
# tenant.local/secrets.local (overriding the hardcoded defaults above) and
# provides colors, logging helpers, and verification helpers.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh\""""

LOG_FN_PREFIXES = ("log_done(", "log_skip(", "log_warn(", "log_fail(", "step(")
VERIFY_FNS = ("verify_not_contains", "verify_contains", "verify_cmd", "verify")


def refactor(path):
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().split("\n")

    if any("lib/common.sh" in ln for ln in lines):
        print(f"  - {path}: already wired to lib/common.sh - skipped")
        return

    out, changes = [], []
    i, n = 0, len(lines)
    while i < n:
        line = lines[i]
        stripped = line.lstrip()

        # 1. Replace the inline tenant.local/secrets.local source block.
        if stripped.startswith("# === BEGIN tenant.local/secrets.local source block"):
            j = i
            while j < n and not lines[j].lstrip().startswith(
                "# === END tenant.local/secrets.local source block"
            ):
                j += 1
            out.append(REPLACEMENT)
            changes.append("replaced inline source block -> source lib/common.sh")
            i = j + 1
            continue

        # 2. Drop single-line logging-helper definitions.
        if any(stripped.startswith(p) for p in LOG_FN_PREFIXES):
            changes.append(f"removed {stripped.split('(')[0]}() definition")
            i += 1
            continue

        # 3. Drop multi-line verify-helper definitions (closing brace col 0).
        m = re.match(r"(" + "|".join(VERIFY_FNS) + r")\(\)\s*\{", stripped)
        if m:
            j = i
            while j < n and lines[j].strip() != "}":
                j += 1
            changes.append(f"removed {m.group(1)}() definition")
            i = j + 1
            continue

        out.append(line)
        i += 1

    if not changes:
        print(f"  ! {path}: nothing matched - left unchanged")
        return

    shutil.copy(path, path + ".bak")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(out))

    print(f"  OK {path}: {len(changes)} change(s), backup at {path}.bak")
    for c in changes:
        print(f"      - {c}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: python3 refactor-to-common.py <phase-script.sh>")
    refactor(sys.argv[1])
