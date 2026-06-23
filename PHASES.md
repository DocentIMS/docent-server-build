# Build phases — what each one installs

Phases run in this order. `phase-pre-hetzner` and `phase8` run on the **build/
control box (Template)**; everything else runs **on the new target server**
(via `bootstrap.sh` → `phase0` → `run-phases.sh`).

> Reminder: never run the target phases on the Template box. `run-phases.sh`
> and `bootstrap.sh` refuse to run where `/etc/docent-control-host` exists, and
> also if the machine's IP doesn't match `SERVER_IP` in `tenant.local`.

## On the Template / control box
- **`phase-pre-hetzner`** — Creates the **Hetzner Cloud server** and the **DNS
  zone + records** (A for @/www/mail/team, MX, SPF, DMARC, CAA). Writes
  `SERVER_IP` into `tenant.local`. Then prints the hand-off (scp + ssh) to the
  new server.

## On the new server (`bootstrap.sh` → `run-phases.sh`)
- **`phase0` — Bootstrap / config** — Interactive tenant configuration;
  generates strong passwords; writes `tenant.local` and `secrets.local`.
  (Configuration only — no software installed.)
- **`phase1` — OS hardening** — Base tools (vim, htop, curl, wget, git,
  net-tools, dnsutils), **ufw**, **fail2ban**, **unattended-upgrades**; creates
  the admin users (`wayne`, `admin`, `espen`); moves **SSH to port 2222**;
  reboots.
- **`phase2` — Web server + TLS** — **Apache** + **Let's Encrypt** certificate
  (foundation for the main site).
- **`phase3` — Database** — **MariaDB** server.
- **`phase4` — Mail server** — **Postfix + Dovecot + OpenDKIM + OpenDMARC +
  SpamAssassin**, with virtual mail users stored in MariaDB.
- **`phase4b` — Outbound SMTP relay** — Outbound mail via **SMTP2GO** on port
  587 (Hetzner blocks 25/465).
- **`post-dkim`** — Reads the **DKIM** key generated in phase 4 and publishes it
  as a TXT record in Hetzner DNS (closes the last manual DNS step).
- **`phase5` — Webmail** — **Roundcube** served at `https://mail.<domain>/`
  (own Apache vhost + cert).
- **`phase5a` — Roundcube Plus** — Commercial Roundcube **Plus plugins & skins**
  (licensed).
- **`phase5b` — Shared address book** — `globaladdressbook` plugin ("Project
  Contacts"), per-tenant shared read/write address book.
- **`phase5c` — Email AI** — The **xai** Roundcube plugin (AI Composer /
  assistant).
- **`phase6` — WordPress** — **WordPress** core at `https://<domain>/` (finish
  setup at `/wp-admin/install.php`).
- **`phase7a` — Plone prerequisites** — OS packages + the `plone` user + working
  directory (`/home/plone/<sitename>/`). Plone itself is not installed yet.
- **`phase7b` — Plone install** — **Plone 6.2** via buildout.
- **`phase7c` — Plone frontend + site** — Locks Plone to `127.0.0.1:8080`,
  **Apache reverse proxy** at `team.<domain>`, **creates the Plone site**
  (classic distribution) + the Plone admin user, and imports **example content**
  (`plone.app.contenttypes:plone-content`; toggle with `PLONE_EXAMPLE_CONTENT`
  in `tenant.local`, default `yes`).
- **`phase7d` — Plone add-ons (build)** — Builds the Docent products listed in
  `products.cfg`:
  `collective.collectionfilter`, `collective.sidebar`, `medialog.notifications`,
  `onlyoffice.plone`, `DocentIMS.ActionItems`, `medialog.docenttheme`,
  `medialog.meadows`, `medialog.docxtransform`, `plone.app.changeownership`.
- **`phase7e` — Plone add-ons (activate)** — Installs those add-on profiles **in
  dependency order** (collectionfilter + notifications before the themes) and
  activates the Diazo theme (`docent-ims-theme`).

## Back on the Template / control box
- **`phase8` — Monitoring** — Creates **UptimeRobot** monitors for the tenant
  (runs on the build box so the UptimeRobot API key never touches client
  servers).

## Net result per server
A hardened Ubuntu host serving:
- **WordPress** on the main domain (`https://<domain>/`)
- **Plone 6.2** on `team.<domain>` (themed, with starter content)
- **Roundcube webmail** on `mail.<domain>` (Plus plugins + AI + shared
  address book)

…backed by a full **mail stack** (Postfix/Dovecot/DKIM/DMARC/SpamAssassin +
SMTP2GO relay), **MariaDB**, **TLS** on every vhost, and external **UptimeRobot**
monitoring.

## Output conventions (operator UX)
- 🟩 **`👉 YOUR TURN — run this`** (green) = a command you type.
- 🟨 **`❓ ANSWER`** (yellow) = the script is waiting on your yes/no.
