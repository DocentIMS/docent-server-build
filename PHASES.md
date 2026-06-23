# Build phases — what each one does

Phases run in this order. `phase-pre-hetzner` and `phase8` run on the **build/
control box (Template)**; everything else runs **on the new target server**
(via `bootstrap.sh` → `phase0` → `run-phases.sh`).

> Safety: `run-phases.sh` and `bootstrap.sh` refuse to run where
> `/etc/docent-control-host` exists, and `run-phases.sh` also refuses if the
> machine's IP doesn't match `SERVER_IP` in `tenant.local` — so the build can
> never convert the Template box by accident.

## On the Template / control box (build server)

- **`phase-pre-hetzner`** — Create the Hetzner Cloud server + DNS for the tenant.
  - Pre-flight checks (curl / jq / openssl); validate the Hetzner API token.
  - Prompt for tenant identity (domain), server config (location, type), SSH key.
  - Upload the SSH key to Hetzner Cloud.
  - Create the Hetzner Cloud server.
  - Create the DNS zone (and check existing records before overwriting).
  - Write DNS records: A for `@`, `www`, `mail`, `team`, `help`; MX; SPF & DMARC TXT; CAA (×3).
  - Write `SERVER_IP` into `tenant.local`; wait for the server to accept SSH.

## On the new server (`bootstrap.sh` → `run-phases.sh`)

- **`phase0` — bootstrap / config** — Interactive tenant configuration.
  - Prompt for tenant identity; collect Roundcube Plus + (optional) AI-assistant keys.
  - Auto-derive conventional values; generate strong random passwords.
  - Write `tenant.local`, `secrets.local`, and the credentials file.
- **`phase1` — OS hardening.**
  - OS sanity check + package updates; set hostname; set timezone.
  - Install base admin tools (vim, htop, curl, wget, git, dnsutils…).
  - Create users: personal admin (`wayne`), shared admin, Plone-dev (`espen`); install root's SSH keys for them.
  - Harden SSH and move it to **port 2222**.
  - Configure **ufw**; configure **fail2ban**; verify unattended-upgrades; restart SSH.
- **`phase2` — web server (Apache) + TLS.**
  - Install Apache; enable required modules; install certbot + Apache plugin.
  - Create the base directory structure + a placeholder index page.
  - Configure the catch-all and primary-domain vhosts.
  - Acquire the Let's Encrypt cert (webroot); install it into Apache; configure the 443 fallback vhost.
  - Verify certificate auto-renewal.
- **`phase3` — database (MariaDB).**
  - Install MariaDB; secure the root account; harden (secure-installation equivalent).
  - Verify localhost-only binding; set up daily backups; test-run the backup script.
- **`phase4` — mail server.** (Postfix + Dovecot + OpenDKIM + OpenDMARC + SpamAssassin)
  - Extend the TLS cert to include `mail.<domain>`; install the mail packages.
  - Create the `vmail` user/directory; create the mail database and schema.
  - Configure Postfix, Dovecot, OpenDKIM, OpenDMARC, SpamAssassin (+ spamass-milter + Sieve).
  - Open mail ports in ufw; generate a BIND zone reference file; restart services.
- **`phase4b` — outbound SMTP relay (SMTP2GO).**
  - Write the SASL password file (+ an auto-recompile watcher).
  - Configure Postfix to relay outbound mail through SMTP2GO on port 587.
  - Reload Postfix; flush the queue; register the domain in SMTP2GO + publish CNAMEs; deliverability test guidance.
- **`post-dkim`** — Extract the DKIM key generated in phase 4 and publish it as a TXT record in Hetzner DNS.
- **`phase5` — Roundcube webmail at `mail.<domain>`.**
  - Install Roundcube (+ PHP 8.5 compatibility patch); create its DB and user; configure it.
  - Configure the managesieve plugin; grant www-data read access to the cert.
  - Serve Roundcube at `https://mail.<domain>/`; set directory permissions.
- **`phase5a` — Roundcube Plus plugins & skins (commercial).**
  - Install xframework, the Plus plugins, and skins (+ docent skin overrides).
  - Apply branding assets, custom fonts/CSS, folder ordering; create discovery symlinks; reload Apache.
- **`phase5b` — shared address book ("Project Contacts").**
  - Install the `globaladdressbook` plugin; write its config; register and symlink it.
  - Seed the backing user; reload Apache; verify.
- **`phase5c` — email AI assistant (xai plugin).**
  - Install and activate the `xai` plugin (OpenAI `gpt-4o-mini`); register it; set permissions; reload Apache.
- **`phase6` — WordPress core on `<domain>`.**
  - Install PHP + WordPress prerequisites; create the DB and DB user; install WordPress core.
  - Set ownership/permissions; generate `wp-config.php`; configure the Apache vhost; run the install wizard via wp-cli.
- **`help` — Docent help site at `help.<domain>`.**
  - Clone `DocentIMS/HelpFiles` to `/srv/www/help` and serve its generated `WebHelp/` folder.
  - Obtain a Let's Encrypt cert for `help.<domain>`; write and enable the Apache vhost; verify HTTP 200.
- **`phase7a` — Plone 6.2 OS prerequisites.**
  - Verify the system Python version; install the Plone system packages.
  - Verify the `plone` user; create the instance working directory.
- **`phase7b` — install Plone 6.2 via buildout.**
  - Verify phase 7a; establish the Plone admin password.
  - Create a Python venv + buildout prerequisites; write `buildout.cfg`; **run buildout** (5–15 min).
- **`phase7c` — Plone public frontend + create the site.**
  - Verify prerequisites; lock Plone to `127.0.0.1:8080`; re-run buildout; install the systemd unit.
  - Obtain a cert for `team.<domain>`; install the Apache vhost; verify port 8080 isn't public.
  - **Create the Plone site** (classic distribution) + admin user; import **example content**.
- **`phase7d` — build the Docent Plone add-ons.**
  - Verify 7a/7b/7c; copy `products.cfg` into the instance; **run the add-on buildout**; restart Plone.
  - Add-ons: `collective.collectionfilter`, `collective.sidebar`, `medialog.notifications`,
    `onlyoffice.plone`, `DocentIMS.ActionItems`, `medialog.docenttheme`, `medialog.meadows`,
    `medialog.docxtransform`, `plone.app.changeownership`.
- **`phase7e` — activate the Plone add-ons + theme.**
  - Verify 7a–7d; write the activation script.
  - Install the add-on profiles **in dependency order** and activate the Diazo theme (`docent-ims-theme`).
  - Remove seeded test/dev accounts that add-ons create on install (default: `vbauser@docentims.com`, `docent-tester`, `dummyuser@docentims.com`; override via `PLONE_REMOVE_USERS`); restart Plone.

## Back on the Template / control box

- **`phase8` — monitoring** — Create **UptimeRobot** monitors for the tenant (run from the build box so the API key never touches client servers).

## Net result per server

A hardened Ubuntu host serving:
- **WordPress** on the main domain (`https://<domain>/`)
- **Plone 6.2** on `team.<domain>` (themed, with starter content)
- **Roundcube webmail** on `mail.<domain>` (Plus plugins + AI + shared address book)
- **Help site** on `help.<domain>` (static Docent WebHelp)

…backed by a full **mail stack** (Postfix / Dovecot / DKIM / DMARC / SpamAssassin +
SMTP2GO relay), **MariaDB**, **TLS** on every vhost, and external **UptimeRobot**
monitoring.

## Operator output conventions
- 🟩 **`👉 YOUR TURN — run this`** (green) = a command you type.
- 🟨 **`❓ ANSWER`** (yellow) = the script is waiting on your yes/no.
