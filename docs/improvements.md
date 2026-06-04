# Improvements

Single project-wide list of open work, accepted-risks, and finished items
for `docent-server-build`. Combines what used to be `code-review-findings.md`
(security/correctness review tracker) and `future-improvements.docx` (polish
backlog).

## Priority legend

- **HIGH** — do before deploying the first real client server
- **MED** — do as part of pre-launch hardening for real client work
- **LOW** — quality / UX improvements, can wait
- **POLISH** — cosmetic / non-functional, do when convenient

---

## Open

### Consider moving registrar/DNS from IONOS to GoDaddy — LOW
GoDaddy exposes an API for this and also has a
domain-availability API ("connector") to check/suggest available domain
names — could be wired into the provisioning flow. Likely not worth it for
<5 domains; revisit when we approach automated multi-tenant onboarding.

### Auto-fill Plone mail settings from tenant config — LOW
The Plone Site Setup → Mail panel is filled in by hand after every build.
Outbound host is always 127.0.0.1 (the local Postfix from phase 4); only
`From name` and `From address` differ per tenant. Add a small step in
phase 7d (or a follow-on phase) that writes the registry records:
`plone.email_from_name`, `plone.email_from_address`,
`plone.smtp_host=127.0.0.1`, `plone.smtp_port=25`, no SASL. Defaults:
From name = `Project Manager`, From address = `test@${DOMAIN}` (the real
PM isn't known at initial setup; PM updates these in Site Setup → Mail
once they take over). Saves a manual checklist step per tenant.

---

## Won't fix (investigated, accepted as-is)

- **`run-phases.sh:292`** — "FAIL detection is partial" was incorrect on
  closer inspection. `log_fail` appends `[FAIL]  msg` to the `REPORT` array,
  which each phase prints in its summary; that line is tee'd to the log and
  matches the `^\s*\[FAIL\]` heuristic just like `verify`-style failures.
  Hard failures additionally `exit 1` and are caught by `rc=${PIPESTATUS[0]}`.
- **`lib/common.sh:119,135`** — `verify_contains`/`verify_not_contains` use
  `grep -q` (regex). Callers in `phase1.sh`/`phase2.sh` intentionally pass
  anchored regex patterns (`^port …$`, `^22/tcp`), so switching to `grep -F`
  would break them.
- **`phase7b-plone-buildout.sh:274,289`** — group-readable Plone admin
  password in `buildout.cfg`. Operator accepts the risk: only sudo-capable
  accounts are in the `plone` group.
- **`phase7b-plone-buildout.sh:237`** — pip installs Plone's requirements
  from `dist.plone.org` with no hash pinning. Plone doesn't publish hashes,
  so `--require-hashes` would mean generating/maintaining our own hash list
  every Plone release; TLS already protects the transport and
  `dist.plone.org` is the trusted source. Accepted risk.

---

## Done

### Code review — security & correctness (`8a34cca` + follow-ups)
- `audit-monitors.sh` — escaped `|` in `grep` so orphan/missing reports match
  the correct monitor id; later switched the friendly-name lookup to `awk`
  on the exact id field so names containing `|` no longer corrupt output.
- `lib/hetzner-api.sh` — server/zone name lookups use `jq --arg` instead of
  string interpolation.
- `phase2/3/4/5/6` + `phase5b` — abort on failed `apt-get install` /
  `git clone` instead of reporting success and cascading; abort on failed
  `certbot certonly` and `apache2ctl configtest` before continuing.
- `phase5/phase6` — DB password passed via `MYSQL_PWD` instead of `-p` on
  the command line; later added `--no-defaults` so `/root/.my.cnf` can't
  override the connect-verify password.
- `phase5a-rc-plus.sh` — check `mktemp` success, single-quote the EXIT trap,
  and guard the `cd $INTER_SRC_DIR` font-download block.
- `phase7c-plone-frontend.sh` — fixed the ufw port-8080 ALLOW check (`\|`
  was a literal under `grep -E`).
- Password generation (`phase0/1/3/4/5/6/7b`) — feed extra entropy and keep
  alphanumerics so output is reliably the requested length; later
  centralized into a shared `gen_pw` helper.
- `phase5b-globaladdressbook.sh` — re-grep after the plugins-array `sed`
  insert and `log_fail`/`exit 1` if the plugin name isn't present.
- `add-source-block.sh` — capture the original file mode with `stat -c '%a'`
  before overwriting and re-apply it explicitly.
- `phase4/phase5` — silent live-password rotation on re-run fixed:
  `${VAR:-}` gates avoid `set -u` crashes; phase4 recovers the DB password
  from any of the three Postfix `.cf` files before considering a rotation;
  an unavoidable rotation now warns that `CREDENTIALS.txt` must be updated.
- `phase8-monitoring.sh` — write the audit file incrementally so a mid-run
  failure never leaves orphaned monitors without a record; trim default
  monitor set from 6 to 4 (drop `submission`/`imaps`); helpful error on
  existing audit file now shows the `rm` command.
- `bootstrap.sh` — only `ssh-keyscan` GitHub's host key when not already
  known (no duplicate entries on re-run).
- `phase1.sh` — guard the `CREDENTIALS.txt` warning-strip `sed` against
  truncating the file when the closing marker is missing.
- `phase-pre-hetzner.sh` — drop the misleading unused `"n"` default arg
  from `ask_yes_no` calls; clarify the usage comment that no `sudo`/root is
  needed; move the `bash /root/bootstrap.sh` instruction into the new
  server's `/etc/motd`.
- `phase4.sh` — remove the unused `DKIM_TXT_VALUE` variable; guard the
  `cd "$DKIM_KEY_DIR"`; default `smtp_tls_security_level=encrypt`.
- `lib/common.sh` — after sourcing `secrets.local`, validate every known
  secret against `[A-Za-z0-9._-]` and exit with a clear per-variable error
  on bad characters; before sourcing, refuse if `secrets.local` is
  group/world-writable and auto-tighten to `600` if only readable.
- `phase7b-plone-buildout.sh` — re-assert `chmod 600` on `CREDENTIALS.txt`
  after the plain-append path.

### Build-flow improvements
- `phase1.sh` — admin users now get key-based SSH. New Step 7b copies root's
  `authorized_keys` (the build key attached by phase-pre-hetzner) into `wayne`
  and `admin` before root login is disabled, so `ssh -p 2222 wayne@<ip>` logs
  in with the key and no password. Password auth stays as a fallback (no
  lockout risk); de-dupes on re-run; a verification check confirms each admin
  has an `authorized_keys`. Previously script-built servers were password-only
  for the admin users because the key only ever worked for root, which phase 1
  then disabled.
- `phase7d-plone-products.sh` — finish the "overlay lives in this repo" switch.
  An earlier change swapped the `curl` download for `cp $REPO_ROOT/products.cfg`
  but left the download scaffolding, so the script still claimed to fetch from
  `docent-plone-addons`. Reworded the header/banner/errors to say it copies the
  local overlay, dropped the obsolete `curl` prerequisite check and the dead
  `PRODUCTS_CFG_URL` (now `PRODUCTS_CFG_SRC=$REPO_ROOT/products.cfg`). Deleted
  the unused duplicate `scripts/assets/products.cfg` (it referenced the thinned
  `docent-onlyoffice` repo). The active source list was verified reachable.
- `phase0-bootstrap.sh` / `phase5c-email-ai.sh` — disambiguate the two AI
  keys. The AI Assistant prompt now spells out it wants the **OpenAI** key
  (`sk-...` from platform.openai.com), explicitly *not* the RC+ `RCP-`
  license (which is collected once and shared by all RC+ plugins). Both phase
  0 and phase 5c now reject a value starting with `RCP-` so the license can't
  be pasted into the OpenAI-key field and silently break AI features.
- `phase-pre-hetzner.sh` — DMARC policy published at `p=quarantine` (was
  `p=none`): recipients now junk forged mail-from-`<domain>` instead of just
  logging it. Safe from the first build because phase 4 sets up aligned
  SPF + DKIM. `phase4.sh`'s printed zone reference updated to match. Bump to
  `p=reject` per tenant once outbound history is proven clean.
- `phase-pre-hetzner.sh` — new servers are created IPv4-only
  (`public_net: { enable_ipv4: true, enable_ipv6: false }`); the unused IPv6
  address (and its small monthly charge) is no longer provisioned.
- `lib/hetzner-api.sh` — new `hcloud_get_paginated` helper; the live
  server-type menu (`hcloud_print_server_types`) now follows
  `meta.pagination` across all pages of `/datacenters` and `/server_types`,
  so newer / region-specific types past the first 25-item page are listed
  instead of silently dropped.
- `phase4b-smtp-relay.sh` — new phase: outbound mail relay via SMTP2GO on
  587 (Hetzner blocks 25). Automatic when `SMTP2GO_API_KEY` is set —
  registers the sender domain, fetches the per-account CNAMEs, publishes
  them into Hetzner DNS, updates the SPF TXT record, and triggers
  verification. Manual fallback prompt when the API key is unset.
- `lib/smtp2go-api.sh` — minimal v3 helpers (`domain/add`, `domain/view`,
  `domain/verify`).
- `phase7d-plone-products.sh` — pin default `PRODUCTS_CFG_URL` to a fixed
  commit SHA of `docent-plone-addons` instead of the mutable `main`.
- `phase7b-plone-buildout.sh` — pre-seed the egg cache before buildout: if
  `/root/docent-egg-cache.tar.gz` exists it extracts into the instance dir
  and buildout reuses the pre-built eggs.
- `phase7c-plone-frontend.sh` — switched the Plone systemd unit from
  `Type=forking` (with the brittle hardcoded `Z4.pid` PIDFile +
  `ExecStop`/`ExecReload`) to `Type=simple` with `bin/instance console`.
- `phase7d-plone-products.sh` — install the SSH key `bootstrap.sh` created
  for root into the `plone` user's `~/.ssh` so private `git@github.com:`
  add-on repos clone cleanly.
- `run-phases.sh` — print full `CREDENTIALS.txt` (incl. Plone admin
  password, appended by phase 7b) as the final post-build block; phase 0
  no longer dumps an incomplete list earlier; manual verification checklist
  consolidated at the end; phase 8 banner placed *above* that checklist so
  the next concrete action stands out.
- Per-phase "MANUAL VERIFICATION" / "PASSWORDS" / "DNS RECORDS" / "MANUAL
  NEXT STEPS" tail blocks removed across phases 1–7d + post-dkim; the
  consolidated single block now lives at the end of `run-phases.sh`.

### Plone add-ons (`docent-plone-addons` repo, handled externally)
- `products.cfg` trimmed: `medialog.newsletter` removed; the three private
  add-ons (`DocentIMS.ActionItems`, `DocentIMS.dashboard`,
  `medialog.docenttheme`) referenced as `git@github.com:` (SSH) so the
  plone-user deploy key authenticates them.
- `products-dashboard.cfg` created as a dashboard-only overlay (installs
  only `DocentIMS.dashboard`); selected per-tenant by setting
  `PRODUCTS_CFG_URL=…/products-dashboard.cfg` in `tenant.local`.
- `DocentIMS.ActionItems` — `setuphandlers_meadows.py` `_create_content`
  AttributeError on Plone 6.2 fixed by guarding the `Members` folder lookup
  (`if folder:` before assignment). Committed to `master` of the
  `DocentIMS.ActionItems` repo; `docent-plone-addons/products.cfg`
  references the add-on with no rev pin (`mr.developer` clones the default
  branch), so every new tenant build picks the fix up automatically.

### CREDENTIALS.txt format
- Numbered: `5. BACKEND PASSWORDS`, `6. PURCHASED LICENSE KEYS`.
- Plone block now lives **above** the SAVE FILE banner (between
  `PURCHASED LICENSE KEYS` and the footer) — phase 7b fills the
  placeholders in-place via `sed` instead of appending at the bottom.
- Dropped the `SERVER_PURPOSE` block (auto-derived label that nothing
  downstream read).

---

## Adding new items

Append open items at the end of the **Open** section above with a short
title line carrying its priority (`HIGH` / `MED` / `LOW` / `POLISH`), then
a paragraph capturing context: what to do, why it matters, and the touch
point in the code or config.

When an item is finished, move it under **Done** in the section that
matches its area (security/correctness, build-flow, add-ons, format, etc.)
and trim the description down to the change that landed.
