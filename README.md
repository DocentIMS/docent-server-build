# docent-server-build

Complete scripts to build a server to host Docent Tools. From a brand new
machine to the finished server ready to serve clients.

Idempotent bash scripts for building a multi-tenant Plone hosting server on
Ubuntu 26.04. Designed to be cloned for each new client deployment.

## Status

This is a **template under construction**. The scripts currently work for the
reference deployment at `docenttemplate.com`. To deploy for a new client
domain, run `phase0-bootstrap.sh` first — it collects per-tenant values
interactively and writes `tenant.local` / `secrets.local`, which every phase
script then sources. Hardcoded `docenttemplate.com` values remain in each
script only as standalone fallbacks for when phase 0 has not been run.

## Architecture

A single Ubuntu 26.04 VPS hosting:

- Apache web server with Let's Encrypt TLS
- MariaDB
- Postfix + Dovecot 2.4 mail server (virtual users in MariaDB)
- OpenDKIM signing, OpenDMARC processing
- SpamAssassin + spamass-milter spam filtering with Sieve auto-filing
- Roundcube webmail (with Roundcube Plus skin/plugins)
- WordPress (the template's "real-looking" site for PTR ticket purposes)
- Plone (eventual goal — Phase 7)

## Build order

| Phase | Script | Purpose |
|-------|--------|---------|
| 0 | `scripts/phase0-bootstrap.sh` | Interactive config; writes `tenant.local`, `secrets.local`, `CREDENTIALS.txt` |
| 1 | `scripts/phase1.sh` | Base OS hardening (SSH, firewall, fail2ban, unattended-upgrades) |
| 2 | `scripts/phase2.sh` | Apache + Let's Encrypt TLS |
| 3 | `scripts/phase3.sh` | MariaDB + daily backup cron |
| 4 | `scripts/phase4.sh` | Postfix + Dovecot + DKIM + DMARC + SpamAssassin + Sieve |
| 5 | `scripts/phase5.sh` | Roundcube webmail |
| 5a | `scripts/phase5a-rc-plus.sh` | Roundcube Plus skin and plugins |
| 5b | `scripts/phase5b-globaladdressbook.sh` | "Project Contacts" shared address book |
| 5c | `scripts/phase5c-email-ai.sh` | Email AI (xai plugin) |
| 6 | `scripts/phase6.sh` | WordPress |
| 7 | (TBD) | Plone template instance with refuse-as-root protections |
| 8 | `scripts/phase8-monitoring.sh` | UptimeRobot monitors (runs on the build server) |

The chain can be run automatically with `scripts/run-phases.sh` after phase 0.

Phases run **in order**. Phase 4 depends on phases 1-3. Phase 6 depends on
phases 1-3 (mail integration optional). Phase 7 will depend on phases 1-3
(mail/web optional but typical). Some phases have manual steps between them
(DNS records, Kamatera PTR ticket, etc.).

Each script is **idempotent** — safe to re-run. Scripts check current state
before acting and skip steps that are already done.

Each script ends with an automated verification block (e.g. Phase 4 produces
"52 of 52 passed"). A non-zero failed count means review the output before
proceeding to the next phase.

## Usage on a fresh server

The normal path is to run `bootstrap.sh`, which clones this repo to
`/root/server-build` and chains into phase 0. To do it manually instead:

```bash
# As root or with sudo:
git clone https://github.com/DocentIMS/docent-server-build.git /root/server-build
cd /root/server-build/scripts

sudo bash phase0-bootstrap.sh
# Answer the prompts. Save CREDENTIALS.txt to your password manager.

sudo bash phase1.sh
# Read output, save credentials. Reboot if recommended.

sudo bash phase2.sh
# DNS A records for @, www, mail must be live before this runs
# (cert issuance via Let's Encrypt requires public DNS)

sudo bash phase3.sh
# MariaDB root password and mail DB password are in CREDENTIALS.txt

sudo bash phase4.sh
# Generates BIND zone file at /root/server-build/dns/<domain>.zone
# Add DNS records (MX, SPF, DKIM, DMARC, CAA) at your DNS provider
```

Or, after phase 0, run the whole chain:

```bash
sudo bash /root/server-build/scripts/run-phases.sh
```

## Known issues / future work

See `docs/future-improvements.docx` for the running list of known polish
items, prioritized HIGH / MED / LOW / POLISH.

## What's in this repo

```
docent-server-build/
├── README.md                            (this file)
├── scripts/
│   ├── bootstrap.sh                     (Step Zero: clone repo, chain to phase 0)
│   ├── phase0-bootstrap.sh              (interactive config)
│   ├── phase1.sh                        (OS hardening)
│   ├── phase2.sh                        (web + TLS)
│   ├── phase3.sh                        (database)
│   ├── phase4.sh                        (mail server, full stack)
│   ├── phase5.sh                        (Roundcube webmail)
│   ├── phase5a-rc-plus.sh               (Roundcube Plus skin/plugins)
│   ├── phase5b-globaladdressbook.sh     (shared address book)
│   ├── phase5c-email-ai.sh              (email AI plugin)
│   ├── phase6.sh                        (WordPress)
│   ├── phase8-monitoring.sh             (UptimeRobot monitors)
│   ├── run-phases.sh                    (phase-chain orchestrator)
│   └── add-source-block.sh              (one-time maintenance helper)
├── dns/
│   └── docenttemplate.com.zone          (live BIND zone for reference deployment)
└── docs/
    ├── dns-reference.docx               (DNS records walkthrough,
    │                                     Cloudflare migration plan)
    ├── secrets-and-config-inventory.md  (every configurable value mapped)
    └── future-improvements.docx         (deferred polish items, prioritized)
```

## Reference deployment

The current scripts are tuned for and tested against:

- Domain: `docenttemplate.com` (registered IONOS, DNS at IONOS)
- IP: `66.55.78.148` (Kamatera VPS)
- Admin email for Let's Encrypt + DMARC reports: `wglover@docentims.com`
- SSH port: 2222 (root login disabled, password auth)
- Sudo users: `wayne`, `espen`

Verification status as of last commit:

| Phase | Checks passed |
|-------|---------------|
| 1 | 22 of 22 |
| 2 | 27 of 27 |
| 3 | 13 of 13 |
| 4 | 52 of 52 |
| 6 | 23 of 23 |

## License

Internal use. Not licensed for redistribution.
