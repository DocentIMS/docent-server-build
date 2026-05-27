# Code Review Findings

Tracking list from the full review of the provisioning scripts. Items that
have been fixed are removed from the active list and recorded under
"Resolved" at the bottom for reference.

Last refreshed against commit `8a34cca`.

---

## Open — High

### 1. DB password / API key interpolated unescaped into SQL, PHP, sed
- `phase3.sh` — `ROOT_DB_PW` placed into `ALTER USER … IDENTIFIED BY '$ROOT_DB_PW';`
  and into the `.my.cnf` heredoc.
- `phase4.sh` — `MAIL_DB_PW`/`HASHED_PW`/`DOMAIN` in SQL inserts.
- `phase6.sh:262` — `WP_DB_PW` substituted into `wp-config.php` via `sed` (no `\` escaping).
- `phase5c-email-ai.sh:201` — `XAI_API_KEY` escaped into single-quoted PHP (backslash not escaped).

Generated passwords are now alphanumeric (length fix already applied), so the
generated-value path is safe. The remaining risk is a `secrets.local`-supplied
value containing `'`, `\`, `#`, `|`, or `&`. Fix: validate/escape values, or
restrict the accepted charset for operator-supplied secrets.

### 2. `secrets.local` sourced as root with no permission/ownership check
- `lib/common.sh:36-42` sources `tenant.local` and `secrets.local` as shell.
  If `secrets.local` is group/world-writable this is arbitrary code execution.
  Fix: refuse to source unless mode 600 and root-owned (apply only to
  `secrets.local`; `tenant.local` is intentionally 644). **Design decision —
  confirm desired behavior before changing.**

### 3. phase8 partial failure leaves orphaned UptimeRobot monitors
- `phase8-monitoring.sh:307-335` — the audit file is only written at the end,
  so a mid-sequence failure creates monitors with no audit record; a re-run
  then creates duplicates. Fix: write the audit incrementally, or roll back
  created monitors on the EXIT trap. **Design decision.**

### 4. Plone admin password in group-readable buildout.cfg
- `phase7b-plone-buildout.sh:274,289` — `PLONE_ADMIN_PW` written cleartext into
  `buildout.cfg` (mode 640, group `plone`); members of the `plone` group can
  read it. Also `CREDENTIALS.txt` perms are not re-asserted to 600 on the
  plain-append path. **Design decision — credential file layout.**

---

## Open — Medium

### 5. Silent live-password rotation on re-run
- `phase4.sh:369-379`, `phase5.sh:271-281` — if the DB user exists but the
  password can't be recovered from config, it is reset to a freshly generated
  value not in `CREDENTIALS.txt`, desyncing Postfix/Dovecot/Roundcube. The
  `[ -z "$VAR" ]` gates (no `:-`) can also be a fatal unbound-var under `set -u`.

### 6. phase7c systemd PIDFile hardcoded
- `phase7c-plone-frontend.sh:223` — `PIDFile=…/Z4.pid` with `Type=forking` is
  version-fragile; systemd may mis-track Plone. Consider `Type=simple`.

### 7. run-phases FAIL detection is partial
- `run-phases.sh:292` (and the equivalent later) — the `[FAIL]` log heuristic
  only catches `verify`-style failures, not `log_fail`-style ones, so some real
  failures can pass silently.

### 8. phase5b plugin-array sed insertion not verified
- `phase5b-globaladdressbook.sh:217-220` — the `sed` insert is not re-checked
  afterward (unlike `phase5c`, which re-greps). Fragile against formatting drift.

### 9. audit-monitors `|` in monitor names corrupts parsing
- `audit-monitors.sh:92-104` — names containing `|` break the `cut -d'|'`
  field splitting used for orphan/missing reporting.

### 10. add-source-block uses GNU-only `chmod --reference`, unchecked
- `add-source-block.sh:105` — fails on non-GNU; failure is silent and can leave
  injected scripts at mktemp's restrictive 0600.

### 11. refactor-to-common.py corrupts multi-line helper defs
- `refactor-to-common.py:57-59` — single-line removal of `log_*`/`step`
  definitions leaves orphaned function bodies if a script defines them across
  multiple lines. Dev tool only.

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

## Won't fix (by design)

- `lib/common.sh:119,135` — `verify_contains`/`verify_not_contains` use
  `grep -q` (regex). Callers in `phase1.sh`/`phase2.sh` intentionally pass
  anchored regex patterns (`^port …$`, `^22/tcp`), so switching to `grep -F`
  would break them.

---

## Resolved (commit `8a34cca`)

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
