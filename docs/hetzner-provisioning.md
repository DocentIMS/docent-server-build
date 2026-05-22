# Hetzner Provisioning

Two new scripts wrap the manual "create a server + add DNS records" work
that previously had to happen outside the build pipeline. Together they
turn the existing 8-phase build into a fully-automated provisioning flow.

## What's new in this branch

```
scripts/
├── lib/
│   └── hetzner-api.sh                  (sourceable curl/jq helpers)
├── phase-pre-hetzner.sh                (run BEFORE phase0)
└── phase-post-hetzner-dkim.sh          (run AFTER phase4)
docs/
└── hetzner-provisioning.md             (this file)
```

Nothing in the existing phase 0-6 scripts changes. Both new scripts read
and write the same `tenant.local` file the existing scripts already use,
and add one new `hetzner.local` for Hetzner-specific infrastructure state
(token + IDs).

## When each script runs

| Order | Script | Where it runs | What it does |
|---|---|---|---|
| 1 | `phase-pre-hetzner.sh` | Existing server you SSH from (e.g. docenttemplate) | Provisions Hetzner Cloud server + DNS zone + base records |
| 2 | `phase0-bootstrap.sh` | The new server (SSH in) | Existing behavior - pre-filled from tenant.local |
| 3 | `phase1.sh` ... `phase4.sh` | The new server | Existing behavior, unchanged |
| 4 | `phase-post-hetzner-dkim.sh` | The new server | Reads phase4's DKIM key, publishes TXT record |
| 5 | `phase5*.sh`, `phase6.sh` | The new server | Existing behavior, unchanged |

## Prerequisites

### On the host you'll run the script from

`phase-pre-hetzner.sh` runs over the network — it talks to the Hetzner
API to create the new server. It does NOT need to run on the new server
itself (the new server doesn't exist yet). Run it from any existing
Linux box you SSH into — your current docenttemplate server is a fine
choice.

That host needs:

```bash
sudo apt-get update
sudo apt-get install -y curl jq openssl
```

(docenttemplate already has all three from earlier phases, so this is
usually a no-op.)

You also need an SSH keypair on that host. If you don't have one:

```bash
ssh-keygen -t ed25519 -C "docent-build"
# Press Enter to accept default path (~/.ssh/id_ed25519)
# Set a passphrase or leave blank
```

The public key will be installed on the new Hetzner server so you can
SSH into it directly from docenttemplate (or wherever you ran the
pre-script).

### At Hetzner

1. Sign up at <https://www.hetzner.com/cloud> if you haven't already.
2. Create a project in the Hetzner Console.
3. Go to **Security → API tokens → Generate API token**.
4. Permission: **Read & Write** (required for both server and DNS API).
5. Copy the token immediately — you can't view it again.

The same token works for both the Cloud server API and the Cloud DNS
zones API. The legacy `dns.hetzner.com` API uses a separate token, but
we're using the new Cloud DNS service which is integrated.

### At your domain registrar

You'll need to update nameservers AFTER `phase-pre-hetzner.sh` runs.
The script prints the exact NS hostnames you need to set. Common ones
are `helium.ns.hetzner.de`, `hydrogen.ns.hetzner.com`, and
`oxygen.ns.hetzner.com`, but always use what the script reports — your
zone may be assigned a different set.

## Step-by-step

### 1. Run pre-provisioning from an existing server you SSH into

SSH to docenttemplate (or whichever existing server you use as your
working host), then:

```bash
# Clone or update the repo on that host
ssh root@docenttemplate.com
cd /root/server_setup    # or wherever you keep the repo
git fetch
git checkout feature/hetzner-provisioning
git pull

# Run the script
bash scripts/phase-pre-hetzner.sh
```

The script will prompt for:
- Hetzner Cloud API token (stored in `hetzner.local`, gitignored)
- Primary domain (e.g., `acmemuseum.com`)
- Server name (default: `<domain-stem>-docent`)
- Location: `nbg1` / `fsn1` / `hel1` / `ash` / `hil` / `sin`
- Server type: `cx22` / `cx32` (recommended) / `cx42`
- OS image (default: `ubuntu-24.04`)
- Path to public SSH key
- Notification email (for DMARC and CAA)

It then:
1. Uploads your SSH key to Hetzner (or reuses if fingerprint matches)
2. Creates the server with cloud-init (basic package install)
3. Polls until the server is fully up
4. Creates the DNS zone for your domain
5. Adds records: A (@/www/mail/team), MX, SPF, DMARC, CAA
6. Writes `SERVER_IP` and `DOMAIN` to `tenant.local`
7. Writes the token and zone ID to `hetzner.local`
8. Prints the nameservers you need to set at your registrar

When it finishes, `tenant.local` and `hetzner.local` exist in the repo
root on the host you ran it from. Don't commit them - both are
gitignored.

### 2. Update nameservers at your registrar

Use whichever NS values the script printed. Propagation usually takes
a few minutes for Hetzner-managed zones, but can take longer if your
registrar caches aggressively.

### 3. Move tenant.local and hetzner.local to the new server

Still on the host where you ran the pre-script:

```bash
# Copy both files directly to the new Hetzner server.
# (Replace <NEW_IP> with the value the pre-script printed.)
scp tenant.local hetzner.local root@<NEW_IP>:/root/
```

The new server accepts your SSH key because the pre-script installed
the same key it found on the running host.

### 4. Run the existing build on the new server

```bash
# SSH from your current host to the new Hetzner server
ssh root@<NEW_IP>

# Clone the repo and check out this branch
git clone https://github.com/DocentIMS/docent-server-build.git /root/server_setup
cd /root/server_setup
git checkout feature/hetzner-provisioning

# Move the files you scp'd up into the repo root
mv /root/tenant.local /root/hetzner.local .

# Now run the existing phases - SERVER_IP and DOMAIN are pre-filled
sudo bash scripts/phase0-bootstrap.sh
sudo bash scripts/phase1.sh
sudo bash scripts/phase2.sh
sudo bash scripts/phase3.sh
sudo bash scripts/phase4.sh
```

### 5. Publish DKIM after phase 4

```bash
sudo bash scripts/phase-post-hetzner-dkim.sh
```

This reads the DKIM key OpenDKIM generated in phase 4 and creates the
`default._domainkey` TXT record in your Hetzner DNS zone. After this
runs, every DNS record the build needs is live and there is no manual
DNS step left.

### 6. Continue with the rest of the phases

```bash
sudo bash scripts/phase5.sh
sudo bash scripts/phase5b-rc-plus.sh
sudo bash scripts/phase5c-email-ai.sh
sudo bash scripts/phase6.sh
```

## hetzner.local

Generated by `phase-pre-hetzner.sh`. Sourced by `phase-post-hetzner-dkim.sh`.
Contains the API token, so it's mode 600 and gitignored:

```bash
HETZNER_CLOUD_TOKEN="<token>"
HETZNER_SERVER_ID="<numeric server id>"
HETZNER_SERVER_NAME="acmemuseum-docent"
HETZNER_ZONE_ID="<zone id string>"
HETZNER_ZONE_NAME="acmemuseum.com"
```

If you provisioned the server some other way and just want the DKIM
script to work, you can create this file manually with just the token
and zone ID.

## Idempotency

Both scripts are safe to re-run. The pre-script:
- Checks for an existing SSH key by fingerprint before uploading
- Checks for an existing server by name before creating
- Checks for an existing zone by domain before creating
- Uses PUT (replace) rather than POST (create) for RRSets when the
  RRSet already exists

If something fails partway through (e.g., bad network during DNS step),
re-run the script. It'll skip everything it already finished and pick
up where it left off.

## Server type sizing

The build's footprint (Apache + MariaDB + Postfix + Dovecot + Roundcube
+ WordPress + SpamAssassin + OpenDKIM + OpenDMARC) needs:

| Server type | vCPU | RAM | Disk | Verdict |
|---|---|---|---|---|
| `cx22` | 2 | 4 GB | 40 GB | Minimum - tight for SpamAssassin under load |
| `cx32` | 4 | 8 GB | 80 GB | **Recommended** - comfortable headroom |
| `cx42` | 8 | 16 GB | 160 GB | Overkill for typical tenant, fine for migration loads |

## Cost notes

Rough Hetzner Cloud pricing (check current rates — this changes):

- `cx32` server: ~€7/month
- DNS zone management: free
- Outbound traffic: 20 TB included on cx32, then per-TB billing
- IPv4 address: included; IPv6 included

## Reverse DNS (PTR)

Still a manual step in Hetzner Console (no API for cloud server PTR
as of writing). After provisioning:

1. Hetzner Console → Servers → your server → Networking tab
2. Under the IPv4 row, click the pencil icon next to the PTR field
3. Set to `mail.<your-domain>`

The mail server needs this for SPF alignment and to avoid greylisting.

## Troubleshooting

**"Token rejected by API"** — token was probably truncated when pasted.
Tokens are 64 chars long; check the length with `wc -c` on the file
containing it.

**"Server create failed - no available server"** — the location you
chose is out of capacity for that server type. Try a different location
or a different size.

**"Zone create failed - already exists"** — the zone exists in some
other Hetzner project. The script's idempotency check uses the API
token's project scope, so it can't see zones in other projects. Either
delete the zone in the other project or transfer it.

**DNS records don't resolve** — check the nameservers are updated at
your registrar, and that the registrar shows them as the authoritative
NS for the domain. `dig +trace <domain> NS` will show the delegation
chain.
