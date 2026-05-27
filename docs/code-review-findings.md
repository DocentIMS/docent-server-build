# Code Review Findings

Status tracker for the full review of the provisioning scripts. Every item
carries a status:

- **FIXED** — change applied on the `docent-code-updates` branch.
- **DEFERRED** — real but intentionally held back (needs live testing).
- **OPEN** — not yet addressed; awaiting a decision or scheduling.
- **WON'T FIX** — investigated and judged not-a-bug or correct by design.

Status counts: 19 fixed, 1 deferred, 2 open, 2 won't-fix.

Commits: `8a34cca` (first batch), `cd59ad3` (phase5b/audit/add-source-block),
the password-rotation follow-up, and the phase8 + low-items follow-up that also
carries this update.

---

## Open — High

### 1. Plone admin password in group-readable buildout.cfg — OPEN (design)
- `phase7b-plone-buildout.sh:274,289` — `PLONE_ADMIN_PW` written cleartext into
  `buildout.cfg` (mode 640, group `plone`); group members can read it. Low real
  risk today (the only `plone`-group member, `espen`, already has `sudo`).
  Left open until a less-privileged account is introduced. The related
  `CREDENTIALS.txt` perm gap has been fixed (see Fixed below).

---

## Deferred

### 2. phase7c systemd PIDFile hardcoded — DEFERRED (needs live testing)
- `phase7c-plone-frontend.sh:223` — `PIDFile=…/Z4.pid` with `Type=forking` is
  version-fragile; systemd may mis-track Plone. Recommended fix is `Type=simple`
  + `ExecStart=…/bin/instance console`, dropping `PIDFile`/`ExecStop`/`ExecReload`.
  Changes service semantics (restart, journald logging) and must be verified
  against a running Plone instance before merging.

---

## Open — Low

- Remote buildout/requirements fetched and executed with no checksum pinning
  (`phase7b-plone-buildout.sh:237` pip `--pre -r <remote requirements.txt>`;
  `phase7d-plone-products.sh:49` `products.cfg` from the `main` branch). Not
  auto-fixed: a safe fix needs maintained known-good hashes (upstream Plone's
  requirements.txt isn't hash-pinned) or pinning to a specific reviewed commit/
  tag. TLS already protects the transport; this is defense against a compromised
  upstream. Decide whether to pin and supply the reference.

---

## Won't fix (not a bug / by design)

- `run-phases.sh:292` — "FAIL detection is partial" was incorrect on closer
  inspection. `log_fail` appends `[FAIL]  msg` to the `REPORT` array, which each
  phase prints in its summary (e.g. `phase2.sh:482`); that line is tee'd to the
  log and matches the `^\s*\[FAIL\]` heuristic just like `verify`-style failures.
  Hard failures additionally `exit 1` and are caught by `rc=${PIPESTATUS[0]}`.
  No silent-pass path exists.
- `lib/common.sh:119,135` — `verify_contains`/`verify_not_contains` use
  `grep -q` (regex). Callers in `phase1.sh`/`phase2.sh` intentionally pass
  anchored regex patterns (`^port …$`, `^22/tcp`), so switching to `grep -F`
  would break them.

(Former item: `refactor-to-common.py` multi-line-def corruption — removed. The
migration has already run and no phase script defines `log_*`/`step` across
multiple lines, so the corruption path does not exist.)

---

## Fixed

### Commit `8a34cca`
- `audit-monitors.sh` — escaped `|` in `grep` so orphan/missing reports match
  the correct monitor id instead of the first line.
- `lib/hetzner-api.sh` — server/zone name lookups use `jq --arg` instead of
  string interpolation.
- `phase2/3/4/5/6` + `phase5b` — abort on failed `apt-get install` / `git clone`
  instead of reporting success and cascading; abort on failed `certbot certonly`
  and `apache2ctl configtest` before continuing.
- `phase5.sh`/`phase6.sh` — DB password passed via `MYSQL_PWD` instead of `-p`
  on the command line (keeps it out of the process table).
- `phase5a-rc-plus.sh` — check `mktemp` success and single-quote the EXIT trap.
- `phase7c-plone-frontend.sh` — fixed the ufw port-8080 ALLOW check (`\|` was a
  literal under `grep -E`).
- Password generation (`phase0/1/3/4/5/6/7b`) — feed extra entropy and keep
  alphanumerics so the output is reliably the requested length.

### Commit `cd59ad3`
- `phase5b-globaladdressbook.sh` — re-grep after the plugins-array `sed` insert
  and `log_fail`/`exit 1` if the plugin name isn't present (mirrors `phase5c`).
- `audit-monitors.sh` — look up the friendly name with `awk` keyed on the exact
  id field, preserving everything after the first delimiter, so names containing
  `|` no longer corrupt the orphan report.
- `add-source-block.sh` — capture the original file mode with `stat -c '%a'`
  before overwriting and re-apply it explicitly, warning on failure instead of
  silently leaving mktemp's 0600.

### Password-rotation follow-up
- `phase4.sh` / `phase5.sh` — fixed the silent live-password rotation on re-run:
  the `[ -z "$VAR" ]` gates now use `${VAR:-}` (no more unbound-variable crash
  under `set -u`); phase4 recovers the DB password from any of the three Postfix
  `.cf` lookup files before considering a rotation; and when a rotation is
  genuinely unavoidable it warns explicitly that `CREDENTIALS.txt` must be
  updated by hand.

### phase8 + low-items follow-up (this commit)
- `phase8-monitoring.sh` — write the audit file incrementally (header up front,
  each monitor id appended as it's created) instead of only at the end. A
  mid-run failure now always leaves a complete record, so no monitors are
  orphaned without an audit entry and a naive re-run is refused by the existing
  file check rather than silently duplicating the partial set.
- `bootstrap.sh` — only `ssh-keyscan` GitHub's host key if it isn't already in
  `known_hosts`, so re-runs don't accumulate duplicate entries.
- `phase1.sh` — guard the `CREDENTIALS.txt` warning-strip `sed`: only run the
  range delete when the closing `^  ---` marker exists, so a missing marker
  can't truncate the file to EOF.
- `phase-pre-hetzner.sh` — drop the misleading `"n"` argument from the two
  `ask_yes_no` calls (the function ignores a default).
- `phase4.sh` — remove the unused `DKIM_TXT_VALUE` variable, and guard the
  `cd "$DKIM_KEY_DIR"` so a failure aborts instead of generating keys in the
  wrong directory.
- `phase5a-rc-plus.sh` — guard the `cd "$INTER_SRC_DIR"` font-download block so
  a cd failure warns and skips instead of downloading into the repo root.

### Secret validation follow-up (this commit) — resolves former High #1
- `lib/common.sh` — after sourcing `secrets.local`, validate every known secret
  (`ROOT_DB_PW`, `MAIL_DB_PW`, `ROUNDCUBE_DB_PW`, `WP_DB_PW`, `PLONE_ADMIN_PW`,
  `ADMIN_PW`, `SHARED_ADMIN_PW`, `ESPEN_PW`, `TEST_MAILBOX_PW`,
  `ROUNDCUBE_DES_KEY`, `XAI_API_KEY`, `LICENSE_KEY`) against the allowlist
  `[A-Za-z0-9._-]` and exit with a clear per-variable error if a set value
  contains anything else. This closes the SQL/PHP/sed interpolation risk at the
  boundary: dangerous characters can never reach those contexts. Auto-generated
  secrets are alphanumeric, so the constraint affects only hand-set values;
  unset/empty values are skipped (generated later by the phase scripts).

### Permission-hardening follow-up (this commit)
- `lib/common.sh` — before sourcing `secrets.local`, check its mode: refuse to
  run if it is writable by group/others (it executes as root, so that's a
  code-injection path and the contents may already be tampered), and tighten it
  to `600` with a warning if it is merely readable by group/others. Resolves the
  former High "`secrets.local` sourced without a permission check".
- `phase7b-plone-buildout.sh` — re-assert `chmod 600` on `CREDENTIALS.txt` after
  the plain-append path (previously only the awk-rewrite branch re-applied it),
  so an append never leaves the file looser than 600.

---

## Enhancements (not from the review)

### Private GitHub repo support for Plone add-ons
- `phase7d-plone-products.sh` — the add-on buildout (run by mr.developer as the
  `plone` user) cloned each `products.cfg` source over `https://github.com/...`
  with no authentication, so any **private** source repo failed. If
  `GITHUB_TOKEN` is set in `secrets.local`, phase7d now sets up a token-based git
  credential for `github.com`, scoped to the buildout run via throwaway
  config/credential files owned by `plone` (mode 600, removed after the run). The
  token never reaches argv, the cloned repos' `.git/config`, or plone's
  persistent gitconfig. Public sources keep working with or without a token.
  - Operator step: add `GITHUB_TOKEN=<token>` to `secrets.local`, using a GitHub
    token (classic or fine-grained) with read access to the private source repos.
  - Note: the main `docent-server-build` repo is cloned over SSH in
    `bootstrap.sh` and already supports private access via the key the operator
    registers on GitHub; the public `docent-plone-addons` `products.cfg` fetch
    needs no token.
