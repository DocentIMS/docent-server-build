# Code Review Findings

Status tracker for the full review of the provisioning scripts. Every item
carries a status:

- **FIXED** — change applied on the `docent-code-updates` branch.
- **DEFERRED** — real but intentionally held back (needs testing, or dead path).
- **OPEN** — not yet addressed; awaiting a decision or scheduling.
- **WON'T FIX** — investigated and judged not-a-bug or correct by design.

Status counts: 11 fixed, 2 deferred, 10 open, 2 won't-fix.

Commits: `8a34cca` (first batch), `cd59ad3` (phase5b/audit/add-source-block),
plus the password-rotation follow-up that also carries this update.

---

## Open — High

### 1. DB password / API key interpolated unescaped into SQL, PHP, sed — OPEN
- `phase3.sh` — `ROOT_DB_PW` into `ALTER USER … IDENTIFIED BY '$ROOT_DB_PW';` and the `.my.cnf` heredoc.
- `phase4.sh` — `MAIL_DB_PW`/`HASHED_PW`/`DOMAIN` in SQL inserts.
- `phase6.sh:262` — `WP_DB_PW` into `wp-config.php` via `sed` (no `\` escaping).
- `phase5c-email-ai.sh:201` — `XAI_API_KEY` into single-quoted PHP (backslash not escaped).

Generated passwords are now alphanumeric (length fix applied), so the
generated-value path is safe. Remaining risk is a `secrets.local`-supplied
value containing `'`, `\`, `#`, `|`, or `&`. Fix: validate/escape values, or
restrict the accepted charset for operator-supplied secrets.

### 2. `secrets.local` sourced as root with no permission check — OPEN (design)
- `lib/common.sh:36-42` sources `tenant.local` and `secrets.local` as shell.
  If `secrets.local` is group/world-writable this is arbitrary code execution.
  Fix: refuse to source unless mode 600 and root-owned (apply only to
  `secrets.local`; `tenant.local` is intentionally 644). Confirm desired
  behavior before changing.

### 3. phase8 partial failure leaves orphaned UptimeRobot monitors — OPEN (design)
- `phase8-monitoring.sh:307-335` — the audit file is only written at the end,
  so a mid-sequence failure creates monitors with no audit record; a re-run
  then creates duplicates. Fix: write the audit incrementally, or roll back
  created monitors on the EXIT trap.

### 4. Plone admin password in group-readable buildout.cfg — OPEN (design)
- `phase7b-plone-buildout.sh:274,289` — `PLONE_ADMIN_PW` written cleartext into
  `buildout.cfg` (mode 640, group `plone`); group members can read it. Also
  `CREDENTIALS.txt` perms are not re-asserted to 600 on the plain-append path.

---

## Deferred — Medium

### 5. phase7c systemd PIDFile hardcoded — DEFERRED (needs live testing)
- `phase7c-plone-frontend.sh:223` — `PIDFile=…/Z4.pid` with `Type=forking` is
  version-fragile; systemd may mis-track Plone. Recommended fix is `Type=simple`
  + `ExecStart=…/bin/instance console`, dropping `PIDFile`/`ExecStop`/`ExecReload`.
  Changes service semantics (restart, journald logging) and must be verified
  against a running Plone instance before merging.

### 6. refactor-to-common.py corrupts multi-line helper defs — DEFERRED (dead path)
- `refactor-to-common.py:57-59` — single-line removal of `log_*`/`step` defs
  would leave orphaned bodies if a *target* script defined them across multiple
  lines. The migration has already run; the only scripts still defining helpers
  (`phase7b`, `phase7d`) use single-line defs, which the tool handles. The
  corruption case does not exist today.

---

## Open — Low

- `bootstrap.sh:180` — `ssh-keyscan >> known_hosts` accumulates duplicate
  entries on re-run.
- `phase1.sh:793` — unbounded `sed` range can truncate `CREDENTIALS.txt` to EOF
  if the closing marker is missing; no backup.
- `phase-pre-hetzner.sh:446,573` — `ask_yes_no "…" "n"` passes a default the
  function ignores (dead/misleading arg).
- `phase4.sh:732` — `DKIM_TXT_VALUE` computed but never used.
- Unchecked `cd` in non-subshells (`phase4.sh:703`, `phase5a-rc-plus.sh:868`)
  run subsequent commands in the wrong directory on failure.
- Remote buildout/requirements fetched and executed with no checksum pinning
  (`phase7b-plone-buildout.sh:237`, `phase7d-plone-products.sh:49`).

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

### Password-rotation follow-up (this commit)
- `phase4.sh` / `phase5.sh` — fixed the silent live-password rotation on re-run:
  the `[ -z "$VAR" ]` gates now use `${VAR:-}` (no more unbound-variable crash
  under `set -u`); phase4 recovers the DB password from any of the three Postfix
  `.cf` lookup files before considering a rotation; and when a rotation is
  genuinely unavoidable it now warns explicitly that `CREDENTIALS.txt` must be
  updated by hand.
