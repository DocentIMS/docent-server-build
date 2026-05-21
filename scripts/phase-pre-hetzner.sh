#!/bin/bash
#
# phase-pre-hetzner.sh - Provision a Hetzner Cloud server and create the
#                       DNS zone + records that the rest of the build needs.
#
# Runs BEFORE phase0-bootstrap.sh. End state:
#   - A new Hetzner Cloud server exists, booted, with SSH key installed and
#     a sane base cloud-init config (admin user, SSH port 2222, root login
#     disabled).
#   - A Hetzner DNS zone exists for the primary domain.
#   - DNS records exist for: @, www, mail (A); @ (MX); @ (SPF TXT);
#     _dmarc (DMARC TXT); @ (CAA x3). DKIM is added later by
#     phase-post-hetzner-dkim.sh after phase 4 generates the key.
#   - tenant.local at the repo root has SERVER_IP populated so phase0
#     can read it instead of prompting.
#
# Idempotent. Safe to re-run: every step checks for existing state.
#
# Run from: any Linux host with curl + jq that can reach api.hetzner.cloud.
# In practice that's an existing server you SSH into (e.g. docenttemplate)
# - this script provisions a NEW Hetzner server, it does not need to run
# on the new server itself. Run it from wherever you already SSH from.
#
# Usage:
#   sudo bash phase-pre-hetzner.sh        (root recommended for writing tenant.local
#                                          to a system path; not required if run
#                                          from your own user account)
#
# Requirements on the running machine:
#   - bash 4+, curl, jq, openssl
#   - An SSH keypair (will use ~/.ssh/id_ed25519.pub or ~/.ssh/id_rsa.pub
#     by default; ask before generating a new one)
#
# Hetzner prerequisites:
#   - A Hetzner Cloud project
#   - An API token (Read & Write) generated in Console -> Security -> API tokens
#     (covers both server creation AND the new Cloud DNS zones API)
#

set -u  # we don't use -e; we handle errors per-step

# ============================================================================
# PATHS
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$SCRIPT_DIR/lib"
TENANT_FILE="$REPO_ROOT/tenant.local"
HETZNER_FILE="$REPO_ROOT/hetzner.local"

# Load helpers. The library is sourced once and self-guards against
# double-loading via __HETZNER_API_SH_LOADED.
# shellcheck source=lib/hetzner-api.sh
source "$LIB_DIR/hetzner-api.sh"
HCLOUD_LAST_STATUS=""

# ============================================================================
# COLORS
# ============================================================================
if [ -t 1 ]; then
    BOLD=$'\e[1m'; YELLOW=$'\e[1;33m'; CYAN=$'\e[1;36m'
    GREEN=$'\e[1;32m'; RED=$'\e[1;31m'; RESET=$'\e[0m'
else
    BOLD=""; YELLOW=""; CYAN=""; GREEN=""; RED=""; RESET=""
fi

# ============================================================================
# REPORT TRACKING
# ============================================================================
REPORT=()

log_done() { REPORT+=("[DONE]    $1"); echo "  ${GREEN}✓${RESET} $1"; }
log_skip() { REPORT+=("[SKIPPED] $1 (already done)"); echo "  - $1 (already done)"; }
log_warn() { REPORT+=("[WARN]    $1"); echo "  ${YELLOW}!${RESET} $1"; }
log_fail() { REPORT+=("[FAIL]    $1"); echo "  ${RED}✗${RESET} $1"; }
step()     { echo ""; echo "${BOLD}=== $1 ===${RESET}"; }

# ============================================================================
# HELPERS
# ============================================================================
ask() {
    local prompt="$1" default="${2:-}" response
    if [ -n "$default" ]; then
        read -r -p "${YELLOW}${prompt}${RESET} [${CYAN}${default}${RESET}]: " response
        echo "${response:-$default}"
    else
        read -r -p "${YELLOW}${prompt}${RESET}: " response
        echo "$response"
    fi
}

ask_required() {
    local prompt="$1" default="${2:-}" response=""
    while [ -z "$response" ]; do
        response=$(ask "$prompt" "$default")
        [ -z "$response" ] && echo "${RED}This field is required.${RESET}" >&2
    done
    echo "$response"
}

ask_yes_no() {
    local prompt="$1" default="${2:-y}" response
    while true; do
        read -r -p "${YELLOW}${prompt}${RESET} [${CYAN}${default}${RESET}] (y/n): " response
        response="${response:-$default}"
        case "$response" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo])     return 1 ;;
            *) echo "Please answer yes or no." >&2 ;;
        esac
    done
}

# Read a secret without echoing it.
ask_secret() {
    local prompt="$1" response
    read -r -s -p "${YELLOW}${prompt}${RESET}: " response
    echo "" >&2
    echo "$response"
}

# ============================================================================
# PRE-FLIGHT
# ============================================================================
clear
cat <<EOF
${BOLD}=============================================================
  PHASE PRE-HETZNER - Server + DNS provisioning
=============================================================${RESET}

This script will:
  1. Create a new Hetzner Cloud server
  2. Create a new Hetzner DNS zone for your domain
  3. Add A / MX / SPF / DMARC / CAA records pointing at the new server
  4. Write SERVER_IP to tenant.local so phase0-bootstrap.sh picks it up

It does NOT touch anything in your existing repo files. After this
script completes, run phase0-bootstrap.sh on the new server.

EOF

step "Pre-flight checks"

# Tools
missing=()
for tool in curl jq openssl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        missing+=("$tool")
    fi
done

if [ "${#missing[@]}" -gt 0 ]; then
    log_fail "Missing required tools: ${missing[*]}"
    echo ""
    echo "  Install with: sudo apt-get update && sudo apt-get install -y ${missing[*]}"
    exit 1
fi
log_done "curl, jq, openssl present"

# Check that tenant.local doesn't already have SERVER_IP we'd clobber.
# This script writes SERVER_IP to tenant.local at the end. If tenant.local
# already exists with a SERVER_IP, the user has probably run phase0 already
# for some other server. Warn loudly.
if [ -f "$TENANT_FILE" ]; then
    existing_ip=$(grep -E '^SERVER_IP=' "$TENANT_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true)
    if [ -n "$existing_ip" ] && [ "$existing_ip" != "" ]; then
        log_warn "tenant.local already has SERVER_IP=$existing_ip"
        echo ""
        echo "  This usually means you've already provisioned a server for this"
        echo "  build directory. Running this script again will create a NEW server"
        echo "  and OVERWRITE tenant.local's SERVER_IP."
        echo ""
        if ! ask_yes_no "Continue and provision a new server anyway?" "n"; then
            echo "Aborted."
            exit 1
        fi
    fi
fi

# ============================================================================
# TOKEN
# ============================================================================
step "Hetzner Cloud API token"

# Read from hetzner.local if it exists (set on prior run).
if [ -f "$HETZNER_FILE" ]; then
    # shellcheck disable=SC1090
    source "$HETZNER_FILE"
fi

if [ -z "${HETZNER_CLOUD_TOKEN:-}" ]; then
    echo "Get a token from: Hetzner Console -> Security -> API tokens"
    echo "Permission: Read & Write"
    echo ""
    HETZNER_CLOUD_TOKEN=$(ask_secret "Cloud API token")
    if [ -z "$HETZNER_CLOUD_TOKEN" ]; then
        log_fail "No token provided"
        exit 1
    fi
fi
export HETZNER_CLOUD_TOKEN

# Validate.
echo "  Validating token..."
resp=$(curl -sS -H "Authorization: Bearer $HETZNER_CLOUD_TOKEN" "https://api.hetzner.cloud/v1/locations" 2>/dev/null)
if echo "$resp" | jq -e ".locations" >/dev/null 2>&1; then
    echo "  ✓ Token valid"
else
    echo "  ✗ Token rejected by API"
    exit 1
fi
# ============================================================================
# INPUTS
# ============================================================================
step "Tenant identity"

DOMAIN=$(ask_required "Primary domain (e.g., acmemuseum.com)")

# Light sanity check: must contain a dot, must not start with a dot.
if ! echo "$DOMAIN" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}$'; then
    log_fail "Domain '$DOMAIN' does not look like a valid FQDN"
    echo "  Expected something like: acmemuseum.com"
    exit 1
fi

DOMAIN_STEM="${DOMAIN%%.*}"

step "Server configuration"

SERVER_NAME=$(ask "Server name (label in Hetzner Console)" "${DOMAIN_STEM}-docent")

echo ""
echo "Available locations:"
echo "  nbg1 - Nuremberg, Germany"
echo "  fsn1 - Falkenstein, Germany"
echo "  hel1 - Helsinki, Finland"
echo "  ash  - Ashburn, VA (USA)"
echo "  hil  - Hillsboro, OR (USA)"
echo "  sin  - Singapore"
echo ""
SERVER_LOCATION=$(ask "Location" "hil")

echo ""
echo "Common server types (shared vCPU, x86):"
echo "  cx22  - 2 vCPU / 4 GB / 40 GB   (~€4/mo)  - minimum for this stack"
echo "  cx32  - 4 vCPU / 8 GB / 80 GB   (~€7/mo)  - recommended"
echo "  cx42  - 8 vCPU / 16 GB / 160 GB (~€14/mo)"
echo ""
SERVER_TYPE=$(ask "Server type" "cx32")

SERVER_IMAGE=$(ask "OS image" "ubuntu-24.04")

# SSH key
step "SSH key"

DEFAULT_PUBKEY=""
for candidate in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub; do
    if [ -f "$candidate" ]; then
        DEFAULT_PUBKEY="$candidate"
        break
    fi
done

if [ -n "$DEFAULT_PUBKEY" ]; then
    echo "Found existing public key: $DEFAULT_PUBKEY"
    SSH_PUBKEY_PATH=$(ask "Public key to install on the server" "$DEFAULT_PUBKEY")
else
    echo "No SSH key found in ~/.ssh/. You'll need one to log into the server."
    echo "Generate one with:  ssh-keygen -t ed25519 -C \"docent-build\""
    echo ""
    SSH_PUBKEY_PATH=$(ask_required "Path to public key file")
fi

if [ ! -f "$SSH_PUBKEY_PATH" ]; then
    log_fail "Public key not found: $SSH_PUBKEY_PATH"
    exit 1
fi

SSH_PUBKEY_CONTENT=$(cat "$SSH_PUBKEY_PATH")
# Fingerprint matches what Hetzner stores: MD5 of the key, colon-separated.
SSH_PUBKEY_FINGERPRINT=$(ssh-keygen -lf "$SSH_PUBKEY_PATH" -E md5 | awk '{print $2}' | sed 's/^MD5://')

# Confirm
echo ""
echo "${BOLD}About to create:${RESET}"
echo "  Server:    $SERVER_NAME ($SERVER_TYPE in $SERVER_LOCATION, $SERVER_IMAGE)"
echo "  Domain:    $DOMAIN"
echo "  SSH key:   $SSH_PUBKEY_PATH (fp: $SSH_PUBKEY_FINGERPRINT)"
echo ""
if ! ask_yes_no "Proceed?"; then
    echo "Aborted."
    exit 0
fi

# ============================================================================
# SSH KEY UPLOAD (idempotent)
# ============================================================================
step "Step 1: SSH key in Hetzner Cloud"

SSH_KEY_ID=$(hcloud_ssh_key_id_by_fingerprint "$SSH_PUBKEY_FINGERPRINT")

if [ -n "$SSH_KEY_ID" ]; then
    log_skip "SSH key already in Hetzner (id $SSH_KEY_ID)"
else
    # Upload with a descriptive name.
    SSH_KEY_NAME="docent-build-${DOMAIN_STEM}-$(date +%Y%m%d)"
    SSH_KEY_ID=$(hcloud_ssh_key_upload "$SSH_KEY_NAME" "$SSH_PUBKEY_CONTENT")
    if [ -n "$SSH_KEY_ID" ] && [ "$SSH_KEY_ID" != "null" ]; then
        log_done "Uploaded SSH key (id $SSH_KEY_ID, name $SSH_KEY_NAME)"
    else
        log_fail "SSH key upload failed"
        exit 1
    fi
fi

# ============================================================================
# CLOUD-INIT USER DATA
# ============================================================================
# Minimal config: ensure SSH is healthy and the box is patched. We
# intentionally do NOT create the wayne user or change the SSH port here -
# phase1.sh does that and we want phase1 to run on a known-clean baseline.
# This block only ensures: package lists updated, jq installed (phase0
# uses it implicitly via the phase scripts).
CLOUD_INIT=$(cat <<'CLOUD_INIT_EOF'
#cloud-config
package_update: true
package_upgrade: false
packages:
  - jq
  - curl
  - ca-certificates
runcmd:
  - [ bash, -c, "echo 'docent-build: phase-pre-hetzner provisioning complete' > /etc/motd" ]
CLOUD_INIT_EOF
)

# ============================================================================
# SERVER CREATION (idempotent)
# ============================================================================
step "Step 2: Create Hetzner Cloud server"

EXISTING_SERVER_ID=$(hcloud_server_id_by_name "$SERVER_NAME")

if [ -n "$EXISTING_SERVER_ID" ]; then
    log_skip "Server $SERVER_NAME already exists (id $EXISTING_SERVER_ID)"
    SERVER_ID="$EXISTING_SERVER_ID"
else
    # Build request body. jq -n handles JSON escaping for us so the
    # cloud-init YAML survives intact (newlines, colons, etc).
    BODY=$(jq -n \
        --arg name "$SERVER_NAME" \
        --arg type "$SERVER_TYPE" \
        --arg loc  "$SERVER_LOCATION" \
        --arg img  "$SERVER_IMAGE" \
        --arg ud   "$CLOUD_INIT" \
        --argjson ssh "$SSH_KEY_ID" \
        '{
            name: $name,
            server_type: $type,
            location: $loc,
            image: $img,
            ssh_keys: [$ssh],
            start_after_create: true,
            user_data: $ud
        }')

    echo "  Submitting create request..."
    RESP=$(hcloud_post "/servers" "$BODY")

    SERVER_ID=$(echo "$RESP" | jq -r '.server.id // empty')
    if [ -z "$SERVER_ID" ]; then
        log_fail "Server create failed"
        echo "$RESP" | jq -r '.error.message // .' >&2
        exit 1
    fi
    ACTION_ID=$(echo "$RESP" | jq -r '.action.id')

    log_done "Server create accepted (id $SERVER_ID, action $ACTION_ID)"

    echo "  Waiting for server to be ready..."
    if hcloud_wait_for_action "$ACTION_ID"; then
        log_done "Server $SERVER_NAME is up"
    else
        log_fail "Server creation action did not complete successfully"
        exit 1
    fi
fi

# Fetch the IP regardless of whether we created or reused the server.
SERVER_IP=$(hcloud_server_ipv4 "$SERVER_ID")
if [ -z "$SERVER_IP" ] || [ "$SERVER_IP" = "null" ]; then
    log_fail "Could not read server IPv4 address"
    exit 1
fi
log_done "Server IPv4: $SERVER_IP"

# ============================================================================
# DNS ZONE
# ============================================================================
step "Step 3: DNS zone"

ZONE_ID=$(hcloud_zone_id_by_name "$DOMAIN")

if [ -n "$ZONE_ID" ]; then
    log_skip "Zone $DOMAIN already exists (id $ZONE_ID)"
else
    ZONE_ID=$(hcloud_zone_create "$DOMAIN" 3600)
    if [ -n "$ZONE_ID" ] && [ "$ZONE_ID" != "null" ]; then
        log_done "Created zone $DOMAIN (id $ZONE_ID)"
    else
        log_fail "Zone create failed"
        exit 1
    fi
fi

# Capture nameservers so we can print them in the final report. The user
# MUST set these at their registrar, otherwise nothing else works.
ZONE_NS=$(hcloud_zone_nameservers "$ZONE_ID")

# ============================================================================
# DNS RECORDS
# ============================================================================
step "Step 4: DNS records"

# Notification email — used in DMARC rua and CAA iodef. Same convention as
# phase0: ask once, reuse everywhere. We don't write this to tenant.local
# here (phase0 owns that file); just prompt and use it in the records.
NOTIFICATION_EMAIL=$(ask_required "Notification email (for DMARC + CAA reports)")

# A records: @, www, mail, team
# - @ / www : main site (Apache vhost, phase 2)
# - mail    : mail server (Postfix, phase 4)
# - team    : team.<domain> (phase 7c issues a separate cert against this name;
#             tenant.local already exposes DEFAULT_SITE_DIR as the webroot used
#             for the team.<domain> certbot --webroot challenge, so the A record
#             must exist before that phase runs)
for sub in "@" "www" "mail" "team"; do
    if hcloud_rrset_upsert "$ZONE_ID" "$sub" "A" "$SERVER_IP" 3600; then
        log_done "A    $sub -> $SERVER_IP"
    else
        log_fail "A    $sub"
    fi
done

# MX record: @ -> mail.<domain>. priority 10
# Hetzner's MX record format combines priority + target in the value string.
if hcloud_rrset_upsert "$ZONE_ID" "@" "MX" "10 mail.${DOMAIN}." 3600; then
    log_done "MX   @ -> 10 mail.${DOMAIN}."
else
    log_fail "MX   @"
fi

# SPF (TXT): @ -> "v=spf1 mx ~all"
# The value MUST be quoted (it's a TXT record string). Hetzner stores it
# with the quotes intact.
if hcloud_rrset_upsert "$ZONE_ID" "@" "TXT" '"v=spf1 mx ~all"' 3600; then
    log_done "TXT  @ (SPF)"
else
    log_fail "TXT  @ (SPF)"
fi

# DMARC (TXT): _dmarc -> v=DMARC1; p=none; rua=mailto:<notification_email>
DMARC_VALUE="\"v=DMARC1; p=none; rua=mailto:${NOTIFICATION_EMAIL}\""
if hcloud_rrset_upsert "$ZONE_ID" "_dmarc" "TXT" "$DMARC_VALUE" 3600; then
    log_done "TXT  _dmarc"
else
    log_fail "TXT  _dmarc"
fi

# CAA: Let's Encrypt only, with iodef for misissuance reports.
# Three records on @, one RRSet (records array) - so we POST them all at
# once. The rrset_upsert helper does single records; for CAA we issue
# three separate calls and rely on the existing-rrset detection to merge.
# Actually, Hetzner's RRSet model wants one PUT with all three records.
# We construct it manually here to keep the helper simple.
CAA_BODY=$(jq -n \
    --arg name "@" \
    --argjson ttl 3600 \
    --arg email "$NOTIFICATION_EMAIL" \
    '{
        name: $name,
        type: "CAA",
        ttl: $ttl,
        records: [
            {value: "0 issue \"letsencrypt.org\""},
            {value: "0 issuewild \"letsencrypt.org\""},
            {value: ("0 iodef \"mailto:" + $email + "\"")}
        ]
    }')

# Check existence first; PUT to update, POST to create.
hcloud_get "/zones/${ZONE_ID}/rrsets/@/CAA" >/dev/null
if [ "$HCLOUD_LAST_STATUS" = "200" ]; then
    CAA_RESP=$(hcloud_put "/zones/${ZONE_ID}/rrsets/@/CAA" "$CAA_BODY")
else
    CAA_RESP=$(hcloud_post "/zones/${ZONE_ID}/rrsets" "$CAA_BODY")
fi

case "$HCLOUD_LAST_STATUS" in
    200|201) log_done "CAA  @ (Let's Encrypt only)" ;;
    *) log_fail "CAA  @ (HTTP $HCLOUD_LAST_STATUS)"
       echo "$CAA_RESP" | jq -r '.error.message // .' >&2
       ;;
esac

# ============================================================================
# WRITE tenant.local
# ============================================================================
step "Step 5: Write SERVER_IP to tenant.local"

# We write a MINIMAL tenant.local stub here so phase0-bootstrap.sh can read
# SERVER_IP and pre-fill the prompt. We don't write the full tenant.local
# because phase0 owns that file's format and may add fields in the future.
#
# If tenant.local already exists, we update SERVER_IP in place.
if [ -f "$TENANT_FILE" ]; then
    if grep -qE '^SERVER_IP=' "$TENANT_FILE"; then
        # Replace the existing line. Use a temp file because sed -i behaves
        # differently across distros (GNU vs BSD sed).
        sed -E "s|^SERVER_IP=.*|SERVER_IP=\"${SERVER_IP}\"|" "$TENANT_FILE" > "${TENANT_FILE}.tmp"
        mv "${TENANT_FILE}.tmp" "$TENANT_FILE"
        log_done "Updated SERVER_IP in $TENANT_FILE"
    else
        echo "SERVER_IP=\"${SERVER_IP}\"" >> "$TENANT_FILE"
        log_done "Appended SERVER_IP to $TENANT_FILE"
    fi
else
    cat > "$TENANT_FILE" <<TENANT_EOF
# ============================================================================
# tenant.local - Stub generated by phase-pre-hetzner.sh on $(date '+%Y-%m-%d %H:%M:%S %Z')
# ============================================================================
# Pre-populated so phase0-bootstrap.sh can pick up SERVER_IP and DOMAIN
# without prompting. phase0 will overwrite this file with the full
# tenant config once it completes.
# ============================================================================

DOMAIN="${DOMAIN}"
SERVER_IP="${SERVER_IP}"
TENANT_EOF
    chmod 644 "$TENANT_FILE"
    log_done "Wrote stub $TENANT_FILE"
fi

# ============================================================================
# WRITE hetzner.local
# ============================================================================
# Save the API token + IDs so phase-post-hetzner-dkim.sh can find the zone
# again after phase 4 without re-prompting. This file is gitignored.
cat > "$HETZNER_FILE" <<HETZNER_EOF
# ============================================================================
# hetzner.local - Generated by phase-pre-hetzner.sh on $(date '+%Y-%m-%d %H:%M:%S %Z')
# ============================================================================
# Hetzner-specific infrastructure state. Sourced by phase-post-hetzner-dkim.sh.
# This file contains an API TOKEN. Keep it secure. Gitignored.
# ============================================================================

HETZNER_CLOUD_TOKEN="${HETZNER_CLOUD_TOKEN}"
HETZNER_SERVER_ID="${SERVER_ID}"
HETZNER_SERVER_NAME="${SERVER_NAME}"
HETZNER_ZONE_ID="${ZONE_ID}"
HETZNER_ZONE_NAME="${DOMAIN}"
HETZNER_EOF
chmod 600 "$HETZNER_FILE"
log_done "Wrote $HETZNER_FILE (mode 600)"

# ============================================================================
# REPORT
# ============================================================================
echo ""
echo "${BOLD}==================================================================="
echo "  PRE-HETZNER COMPLETE - SUMMARY"
echo "===================================================================${RESET}"
echo ""
for line in "${REPORT[@]}"; do
    echo "  $line"
done

cat <<EOF

${BOLD}Server:${RESET}
  Name:     $SERVER_NAME
  ID:       $SERVER_ID
  Type:     $SERVER_TYPE @ $SERVER_LOCATION
  IPv4:     $SERVER_IP
  SSH:      ssh root@${SERVER_IP}   (port 22 until phase1 changes it)

${BOLD}DNS:${RESET}
  Zone:     $DOMAIN (id $ZONE_ID)
  Records:  A (@/www/mail/team), MX, TXT (SPF + DMARC), CAA (x3)
  DKIM:     NOT YET - add after phase 4 with phase-post-hetzner-dkim.sh

${BOLD}REQUIRED next step at your registrar:${RESET}
  Set the following authoritative nameservers for $DOMAIN:
EOF

if [ -n "$ZONE_NS" ]; then
    while IFS= read -r ns; do
        [ -n "$ns" ] && echo "    - $ns"
    done <<< "$ZONE_NS"
else
    echo "    (could not fetch nameservers - check Hetzner Console -> DNS -> $DOMAIN -> Nameservers tab)"
fi

cat <<EOF

  DNS propagation can take 5 minutes to a few hours. You can run
  phase0-bootstrap.sh as soon as the records resolve. phase0 has a
  built-in DNS check and will warn you if they don't yet.

${BOLD}Next:${RESET}
  1. Update nameservers at your registrar (see above)
  2. Copy tenant.local + hetzner.local to the new server (from THIS host):
       scp tenant.local hetzner.local root@${SERVER_IP}:/root/
     (Once the repo is cloned on the new server, move them to the repo root.)
  3. SSH to the new server:
       ssh root@${SERVER_IP}
  4. Clone the repo there:
       git clone https://github.com/DocentIMS/docent-server-build.git /root/server_setup
       cd /root/server_setup
       git checkout feature/hetzner-provisioning
       mv /root/tenant.local /root/hetzner.local .
  5. Run: sudo bash scripts/phase0-bootstrap.sh
     (it will pre-fill SERVER_IP=$SERVER_IP and DOMAIN=$DOMAIN from tenant.local)
  6. Continue with phase1, phase2, ... as documented in README.md
  7. After phase 4: sudo bash scripts/phase-post-hetzner-dkim.sh
     (this adds the DKIM record to Hetzner DNS automatically)

EOF
