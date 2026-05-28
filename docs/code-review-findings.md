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
- `phase7d-plone-products.sh` — the live `docent-plone-addons` `products.cfg`
  references its private add-on repos as `git@github.com:` (SSH), and
  mr.developer clones them as the `plone` user, so they failed with no key.
  Phase7d now installs the SSH key that `bootstrap.sh` created for root (and
  that the operator registered on GitHub) into the plone user's `~/.ssh`
  (key 600, dir 700, plone-owned) and pre-accepts github.com's host key, so the
  SSH clones authenticate. Public `https://` sources are unaffected. If the root
  key is absent, it warns and continues (public sources still build).
  - Prerequisite: the SSH key's GitHub account must have read access to the
    private source repos (note some are under `espenmn/`, some under
    `DocentIMS/`).
  - Still required outside this repo: the private entries in the
    `docent-plone-addons` `products.cfg` are currently **commented out** — they
    must be uncommented there for the add-ons to actually build.
  - Context: the main `docent-server-build` repo is already cloned over SSH in
    `bootstrap.sh`; the public `docent-plone-addons` `products.cfg` fetch needs
    no auth.

---

## Resolved during chelsea build (2026-05-27)

### phase5/phase6 DB-connect verify failed: MYSQL_PWD overridden by /root/.my.cnf
- Root cause: the earlier hardening that switched the verify from `-p"$PW"` to
  `MYSQL_PWD="$PW" mysql ...` broke when run as root. `mysql` reads
  `/root/.my.cnf` (written by phase3 with the *root* DB password), and an
  option-file password takes precedence over `MYSQL_PWD`, so the verify tried
  the roundcube/wp user with root's password -> "Access denied" -> false FAIL.
  The old `-p` form worked only because a command-line password outranks the
  option file. (The "intermittent" appearance was a red herring: a manual test
  with empty `-u` had silently connected as root via `/root/.my.cnf`.)
- Fix: add `--no-defaults` to the `MYSQL_PWD` verify in `phase5.sh` and
  `phase6.sh` so `/root/.my.cnf` is ignored and `MYSQL_PWD` is used. Keeps the
  password off the command line.

---

## To do (build improvements)

### Wire the Plone egg-cache into the repo so it's used automatically
- `phase-pre-hetzner.sh` already scp's `docent-egg-cache.tar.gz` (~90 MB) to the
  new server's `/root/`, but the `phase7b` code that extracts/uses it exists only
  as an unpushed local commit (`20db3af`, on docenttemplate). So the GitHub copy
  of `phase7b` ignores the cache and rebuilds Plone from dist.plone.org every
  time (slow). Push the egg-cache-extraction logic into `phase7b-plone-buildout.sh`
  so it auto-detects `/root/docent-egg-cache.tar.gz`, extracts it into buildout's
  eggs/download cache before running buildout, and falls back cleanly when the
  file is absent. Also document how the cache tarball is built/refreshed on the
  template server.

### Reword the post-build monitoring "NEXT ACTION" instruction
- `run-phases.sh:601` and `:625-629` — the end-of-build message reads "From your
  own computer (not this server), paste this one line: ssh -p 2222 wayne@<tmpl>
  ... phase8-monitoring.sh <domain>". Confusing. Drop the ssh wrapper and reword
  to exactly:
      On the template server, run:
        cd ~/server-build/scripts && ./phase8-monitoring.sh <domain>
  Fix both the checklist line (601) and the NEXT ACTION block (629).

### Credentials list omits the Plone admin password
- `PLONE_ADMIN_PW` is appended to `CREDENTIALS.txt` by phase7b, which runs long
  after phase0/phase1 already told the operator to "save these credentials" - so
  the copy the operator saved lacks the Plone password.
  - Preferred fix: print the full credentials summary again at the very END of
    the build (after phase 7) so it includes Plone, prompting the operator to
    save the final copy.
  - Minimum fix: in the early credentials output, add a note: "The Plone admin
    password is added later; retrieve it with:
    grep -i plone /root/server-build/CREDENTIALS.txt".
