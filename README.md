# docent-server-build

Complete scripts to build a server to host Docent Tools.  From a brand new machine to the finished server ready to server clients.# docent-server-build



Idempotent bash scripts for building a multi-tenant Plone hosting server on Ubuntu 26.04. Designed to be cloned for each new client deployment.



\## Status



This is a \*\*template under construction\*\*. The scripts currently work for the reference deployment at `docenttemplate.com`. They are \*\*not yet generalized\*\* — to deploy for a new client domain, hardcoded values must be edited (see `docs/future-improvements.docx` for the list). A future Phase 8 will automate this with a parameter-driven deploy script.



\## Architecture



A single Ubuntu 26.04 VPS hosting:



\- Apache web server with Let's Encrypt TLS

\- MariaDB

\- Postfix + Dovecot 2.4 mail server (virtual users in MariaDB)

\- OpenDKIM signing, OpenDMARC processing

\- SpamAssassin + spamass-milter spam filtering with Sieve auto-filing

\- WordPress (the template's "real-looking" site for PTR ticket purposes)

\- Plone (eventual goal — Phase 7)



\## Build order



| Phase | Script | Purpose |

|-------|--------|---------|

| 1 | `scripts/phase1.sh` | Base OS hardening (SSH, firewall, fail2ban, unattended-upgrades) |

| 2 | `scripts/phase2.sh` | Apache + Let's Encrypt TLS |

| 3 | `scripts/phase3.sh` | MariaDB + daily backup cron |

| 4 | `scripts/phase4.sh` | Postfix + Dovecot + DKIM + DMARC + SpamAssassin + Sieve |

| 5 | (TBD) | Roundcube webmail |

| 6 | `scripts/phase6.sh` | WordPress |

| 7 | (TBD) | Plone template instance with refuse-as-root protections |

| 8 | (TBD) | Deploy script to clone the template for new clients |

| 9 | (TBD) | Cron, off-server backups, monitoring |

| 11 | (TBD) | Documentation README at `/root/docs/` |



Phases run \*\*in order\*\*. Phase 4 depends on phases 1-3. Phase 6 depends on phases 1-3 (mail integration optional). Phase 7 will depend on phases 1-3 (mail/web optional but typical). Some phases have manual steps between them (DNS records, Kamatera PTR ticket, etc.).



Each script is \*\*idempotent\*\* — safe to re-run. Scripts check current state before acting and skip steps that are already done.



Each script ends with an automated verification block (e.g. Phase 4 produces "52 of 52 passed"). A non-zero failed count means review the output before proceeding to the next phase.



\## Usage on a fresh server



```bash

\# As root or with sudo:

git clone https://github.com/DocentIMS/docent-server-build.git /root/server\_setup

cd /root/server\_setup/scripts



sudo bash phase1.sh

\# Read output, save credentials. Reboot if recommended.



sudo bash phase2.sh

\# DNS A records for @, www, mail must be live before this runs

\# (cert issuance via Let's Encrypt requires public DNS)



sudo bash phase3.sh

\# Save MariaDB root password and mail DB password to your password manager



sudo bash phase4.sh

\# Generates BIND zone file at /root/server\_setup/dns/<domain>.zone

\# Add DNS records (MX, SPF, DKIM, DMARC, CAA) at your DNS provider

```



\## Known issues / future work



See `docs/future-improvements.docx` for the running list of known polish items, prioritized HIGH / MED / LOW / POLISH. As of initial commit, 27 items are tracked.



\## What's in this repo



```

docent-server-build/

├── README.md                            (this file)

├── scripts/

│   ├── phase1.sh                        (OS hardening)

│   ├── phase2.sh                        (web + TLS)

│   ├── phase3.sh                        (database)

│   ├── phase4.sh                        (mail server, full stack)

│   └── phase6.sh                        (WordPress)

├── dns/

│   └── docenttemplate.com.zone          (live BIND zone for reference deployment)

└── docs/

&#x20;   ├── dns-reference.docx               (DNS records walkthrough,

&#x20;   │                                     Cloudflare migration plan)

&#x20;   └── future-improvements.docx         (deferred polish items, prioritized)

```



\## Reference deployment



The current scripts are tuned for and tested against:



\- Domain: `docenttemplate.com` (registered IONOS, DNS at IONOS)

\- IP: `66.55.78.148` (Kamatera VPS)

\- Admin email for Let's Encrypt + DMARC reports: `wglover@docentims.com`

\- SSH port: 2222 (root login disabled, password auth)

\- Sudo users: `wayne`, `espen`



Verification status as of last commit:



| Phase | Checks passed |

|-------|---------------|

| 1 | 22 of 22 |

| 2 | 27 of 27 |

| 3 | 13 of 13 |

| 4 | 52 of 52 |

| 6 | 23 of 23 |



\## License



Internal use. Not licensed for redistribution.

