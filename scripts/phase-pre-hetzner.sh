#!/bin/bash
#
# phase-pre-hetzner.sh - Provision a Hetzner Cloud server and create the
#                       DNS zone + records that the rest of the build needs.
#
# Runs BEFORE bootstrap.sh / phase0-bootstrap.sh. End state:
#   - A new Hetzner Cloud server exists and is booted, with your SSH key
#     attached so you can log in as root on the default port 22. cloud-init
#     only patches the box and installs jq/curl - it does NOT create users
#     or change the SSH port; phase 1 does that hardening later.
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

# ============================================================================
# DEFAULTS
# ============================================================================
# The Docent build requires Ubuntu 26.04 LTS (Dovecot 2.4 and other
# version-specific pieces), so the OS image is fixed here, not prompted for.
# To build on a different image, change this one line.
SERVER_IMAGE="ubuntu-26.04"

# Load helpers.
# shellcheck source=lib/hetzner-api.sh
source "$LIB_DIR/hetzner-api.sh"
HCLOUD_LAST_STATUS=""

# Load shared helpers and per-tenant config (colors, logging, verify helpers).
# SCRIPT_DIR/REPO_ROOT are defined above; lib/common.sh also sources
# tenant.local/secrets.local if they exist.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

# ============================================================================
# REPORT TRACKING
# ============================================================================
REPORT=()


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
    # Requires the user to type the full word "yes" or "no".
    # Single letters y/n and a blank Enter are NOT accepted.
    local prompt="$1" response
    while true; do
        read -r -p "${YELLOW}${prompt}${RESET} ${CYAN}(type yes or no)${RESET}: " response
        case "$response" in
            [Yy][Ee][Ss]) return 0 ;;
            [Nn][Oo])     return 1 ;;
            *) echo "Please type the full word: yes or no." >&2 ;;
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
  HETZNER SERVER CREATION
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

# Each server creation must start from a clean slate. tenant.local and
# secrets.local are PER-TENANT files - if a previous build left them in the
# repo, their stale domain / IP / secrets must not leak into this new build.
# Any that exist are archived (timestamped, into previous-tenants/) and this
# run continues clean. hetzner.local / org-secrets.local are account-wide,
# not per-tenant, so they are intentionally left in place.
PRE_ARCHIVE_DIR="$REPO_ROOT/previous-tenants"
PRE_ARCHIVE_STAMP="$(date '+%Y%m%d-%H%M%S')"
PRE_ARCHIVED=()
for stale in tenant.local secrets.local; do
    if [ -f "$REPO_ROOT/$stale" ]; then
        mkdir -p "$PRE_ARCHIVE_DIR"
        # Keep the archive folder out of git regardless of the main .gitignore.
        [ -f "$PRE_ARCHIVE_DIR/.gitignore" ] || echo "*" > "$PRE_ARCHIVE_DIR/.gitignore"
        mv "$REPO_ROOT/$stale" "$PRE_ARCHIVE_DIR/${stale}.${PRE_ARCHIVE_STAMP}"
        PRE_ARCHIVED+=("$stale")
    fi
done
if [ "${#PRE_ARCHIVED[@]}" -gt 0 ]; then
    # A previous build left per-tenant file(s) in the repo; they were just
    # moved (timestamped) into previous-tenants/ so this run starts clean.
    # Deliberately a single line of output - nothing is lost, the copies
    # are kept in previous-tenants/ if ever needed.
    log_done "Cleared ${#PRE_ARCHIVED[@]} leftover per-tenant file(s) (archived to previous-tenants/)"
fi

# ============================================================================
# TOKEN
# ============================================================================
step "Hetzner API Token"

# Read from hetzner.local if it exists (set on prior run).
if [ -f "$HETZNER_FILE" ]; then
    # shellcheck disable=SC1090
    source "$HETZNER_FILE"
fi

if [ -z "${HETZNER_CLOUD_TOKEN:-}" ]; then
    echo "Get a token from: Hetzner Console -> Security -> API tokens"
    echo "Permission: Read & Write"
    echo ""
    HETZNER_CLOUD_TOKEN=$(ask_secret "Hetzner API Token")
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

# Ask for the domain, clean common mistakes, validate, and confirm.
while true; do
    DOMAIN=$(ask_required "Primary domain (e.g., acmemuseum.com)")

    DOMAIN=$(echo "$DOMAIN" | tr -d '[:space:]')
    DOMAIN="${DOMAIN#http://}"
    DOMAIN="${DOMAIN#https://}"
    DOMAIN="${DOMAIN#www.}"
    DOMAIN="${DOMAIN%/}"
    DOMAIN=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]')

    if ! echo "$DOMAIN" | grep -qE '^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$'; then
        echo "  '$DOMAIN' does not look like a valid domain. Expected: acmemuseum.com"
        continue
    fi

    echo ""
    echo "  Domain will be: ${BOLD}${DOMAIN}${RESET}"
    if ask_yes_no "Is this domain correct?"; then
        break
    fi
    echo "  Okay, let's try again."
done

DOMAIN_STEM="${DOMAIN%%.*}"

step "Server configuration"

# Server name is derived automatically from the domain - no prompt,
# so it can never be mistyped (e.g. answering a yes/no by accident).
SERVER_NAME="${DOMAIN_STEM}-docent"
echo "Server name (in Hetzner Console): ${SERVER_NAME}"

# The default 'hil' (Hillsboro, OR) is the normal choice, so offer it as a
# simple yes/no. Only ask for a data center code if the answer is no - and
# validate that code, so a stray 'yes' can never end up as the location.
VALID_LOCATIONS="nbg1 fsn1 hel1 ash hil sin"
while true; do
    echo ""
    echo "Server location - the default is '${BOLD}hil${RESET}' (Hillsboro, OR, USA)."
    if ask_yes_no "Use the default location 'hil'?"; then
        SERVER_LOCATION="hil"
        break
    fi

    # Answered no - show the data center codes and ask for one.
    echo ""
    echo "  Data center codes:"
    echo "    nbg1 - Nuremberg, Germany"
    echo "    fsn1 - Falkenstein, Germany"
    echo "    hel1 - Helsinki, Finland"
    echo "    ash  - Ashburn, VA (USA)"
    echo "    hil  - Hillsboro, OR (USA)"
    echo "    sin  - Singapore"
    echo ""
    SERVER_LOCATION=$(ask_required "Enter data center code")
    SERVER_LOCATION=$(echo "$SERVER_LOCATION" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')

    if ! echo " $VALID_LOCATIONS " | grep -q " ${SERVER_LOCATION} "; then
        echo "  '${SERVER_LOCATION}' is not a valid data center code - pick one from the list above."
        continue
    fi
    echo ""
    if ask_yes_no "Use location '${SERVER_LOCATION}'?"; then
        break
    fi
done

while true; do
    echo ""
    echo "Server types available in ${SERVER_LOCATION}:"
    if hcloud_print_server_types "$SERVER_LOCATION"; then
        echo ""
        echo "  (4 GB RAM is the minimum for this stack; 8 GB recommended.)"
    else
        echo "  (could not fetch live list - enter a type name manually)"
    fi
    echo ""
    SERVER_TYPE=$(ask_required "Server type")
    if ask_yes_no "Use server type '${SERVER_TYPE}'?"; then
        break
    fi
done

# SSH key
step "SSH key"

DEFAULT_PUBKEY=""
for candidate in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub; do
    if [ -f "$candidate" ]; then
        DEFAULT_PUBKEY="$candidate"
        break
    fi
done

SSH_PUBKEY_PATH=""

# If a key was found, offer it directly with a simple yes/no. The user does
# not have to type or confirm a file path they don't care about.
if [ -n "$DEFAULT_PUBKEY" ]; then
    echo "Found existing public key: $DEFAULT_PUBKEY"
    if ask_yes_no "Use this public key?"; then
        SSH_PUBKEY_PATH="$DEFAULT_PUBKEY"
    fi
fi

# Runs only if no key was found, or the user declined the one we found.
# This loop repeats just the path question - it never re-offers a declined key.
while [ -z "$SSH_PUBKEY_PATH" ]; do
    echo ""
    echo "Enter the full path to the public key (.pub) file to install on the server."
    echo "(No key yet? Generate one with:  ssh-keygen -t ed25519 -C \"docent-build\")"
    echo ""
    keypath=$(ask_required "Path to public key file")
    if [ ! -f "$keypath" ]; then
        echo "  Public key not found: $keypath - try again."
        continue
    fi
    if ask_yes_no "Use public key '${keypath}'?"; then
        SSH_PUBKEY_PATH="$keypath"
    fi
done

SSH_PUBKEY_CONTENT=$(cat "$SSH_PUBKEY_PATH")
# Fingerprint matches what Hetzner stores: MD5 of the key, colon-separated.
SSH_PUBKEY_FINGERPRINT=$(ssh-keygen -lf "$SSH_PUBKEY_PATH" -E md5 | awk '{print $2}' | sed 's/^MD5://')

# Confirm
echo ""
echo "${BOLD}=====================================================${RESET}"
echo "${BOLD}About to create - please review your choices:${RESET}"
echo "${BOLD}=====================================================${RESET}"
echo "  Domain:       $DOMAIN"
echo "  Server name:  $SERVER_NAME"
echo "  Location:     $SERVER_LOCATION"
echo "  Server type:  $SERVER_TYPE"
echo "  OS image:     $SERVER_IMAGE"
echo "  SSH key:      $SSH_PUBKEY_PATH"
echo "  Key fp:       $SSH_PUBKEY_FINGERPRINT"
echo "${BOLD}=====================================================${RESET}"
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
    SERVER_ID="$EXISTING_SERVER_ID"
    log_warn "A Hetzner server named '$SERVER_NAME' already exists (id $SERVER_ID)"

    # Pull details so the user can tell a harmless leftover (an earlier
    # aborted run of this script) apart from a live/production box.
    EXISTING_INFO=$(hcloud_get "/servers/${SERVER_ID}")
    EX_IP=$(echo "$EXISTING_INFO"      | jq -r '.server.public_net.ipv4.ip // "unknown"' 2>/dev/null)
    EX_STATUS=$(echo "$EXISTING_INFO"  | jq -r '.server.status // "unknown"' 2>/dev/null)
    EX_TYPE=$(echo "$EXISTING_INFO"    | jq -r '.server.server_type.name // "unknown"' 2>/dev/null)
    EX_CREATED=$(echo "$EXISTING_INFO" | jq -r '.server.created // "unknown"' 2>/dev/null)

    echo ""
    echo "  This script would REUSE that existing server - the rest of the"
    echo "  build (phases 1-8) would then run ON it, hardening and"
    echo "  reconfiguring it and rebooting it. If that server is a live or"
    echo "  production box, that is destructive."
    echo ""
    echo "    Name:     $SERVER_NAME"
    echo "    ID:       $SERVER_ID"
    echo "    IPv4:     $EX_IP"
    echo "    Status:   $EX_STATUS"
    echo "    Type:     $EX_TYPE"
    echo "    Created:  $EX_CREATED"
    echo ""
    echo "  Only continue if this is a server you intend to (re)build - for"
    echo "  example a leftover from an earlier, aborted run of this script."
    echo ""
    if ! ask_yes_no "Reuse and build on this existing server?"; then
        echo ""
        echo "${YELLOW}  Stopped. No server was created and nothing was changed.${RESET}"
        echo "  For a brand-new server, rename or delete the existing"
        echo "  '$SERVER_NAME' in the Hetzner Console first, then re-run."
        exit 1
    fi
    log_done "User confirmed reuse of existing server $SERVER_NAME (id $SERVER_ID)"
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

# Clear any stale known_hosts entry for this IP. Hetzner recycles IP
# addresses, so a previously-destroyed server may have left an old host
# key here. The new server is a different machine; without this, the
# scp/ssh steps below would fail host-key verification.
ssh-keygen -R "$SERVER_IP" -f "$HOME/.ssh/known_hosts" >/dev/null 2>&1 || true
log_done "Cleared any stale known_hosts entry for $SERVER_IP"

# ============================================================================
# DNS ZONE
# ============================================================================
step "Step 3: DNS zone"

ZONE_ID=$(hcloud_zone_id_by_name "$DOMAIN")

if [ -n "$ZONE_ID" ]; then
    log_skip "Zone $DOMAIN already exists (id $ZONE_ID)"
    ZONE_PREEXISTING="yes"
else
    ZONE_ID=$(hcloud_zone_create "$DOMAIN" 3600)
    if [ -n "$ZONE_ID" ] && [ "$ZONE_ID" != "null" ]; then
        log_done "Created zone $DOMAIN (id $ZONE_ID)"
        ZONE_PREEXISTING="no"
    else
        log_fail "Zone create failed"
        exit 1
    fi
fi

# Capture nameservers so we can print them in the final report. The user
# MUST set these at their registrar, otherwise nothing else works.
ZONE_NS=$(hcloud_zone_nameservers "$ZONE_ID")

# ============================================================================
# DNS RECORD SAFETY CHECK (only when the zone already existed)
# ============================================================================
# A freshly created zone is empty, so there is nothing to overwrite. But if
# the zone ALREADY existed, the records this script writes (@, www, mail and
# team A records; MX; SPF; DMARC; CAA) might belong to a live site. Before
# Step 4 overwrites them, show which of them already exist - with their
# current values - and ask the user to confirm.
if [ "$ZONE_PREEXISTING" = "yes" ]; then
    step "Step 3b: Checking existing DNS records before overwrite"

    echo "  The zone $DOMAIN already existed. Step 4 will write these records,"
    echo "  and any that already exist will be DELETED and recreated:"
    echo ""

    PREEXISTING_RECORDS=()
    for pair in "@:A" "www:A" "mail:A" "team:A" "@:MX" "@:TXT" "_dmarc:TXT" "@:CAA"; do
        rname="${pair%%:*}"
        rtype="${pair##*:}"
        rbody=$(hcloud_get "/zones/${ZONE_ID}/rrsets/${rname}/${rtype}")
        if echo "$rbody" | jq -e '.rrset.id' >/dev/null 2>&1; then
            rvals=$(echo "$rbody" | jq -r '.rrset.records[]?.value' 2>/dev/null | paste -sd ' ; ' -)
            printf '    %-4s %-8s  currently: %s\n' "$rtype" "$rname" "$rvals"
            PREEXISTING_RECORDS+=("$rtype $rname")
        fi
    done

    if [ "${#PREEXISTING_RECORDS[@]}" -eq 0 ]; then
        echo "    (none of those records exist yet)"
        echo ""
        log_done "Zone $DOMAIN pre-existed but has none of the target records - safe to write"
    else
        echo ""
        echo "${BOLD}${YELLOW}  ${#PREEXISTING_RECORDS[@]} record(s) above already exist and will be"
        echo "  OVERWRITTEN to point at the new server ($SERVER_IP).${RESET}"
        echo "  If $DOMAIN is a live site, this repoints its web and/or mail traffic."
        echo ""
        if ! ask_yes_no "Overwrite these DNS records?"; then
            echo ""
            echo "${YELLOW}  Stopped before changing DNS. The server has already been"
            echo "  created, but the DNS records were left untouched.${RESET}"
            echo "  When you are ready, either re-run this script and answer yes,"
            echo "  or set the records by hand in the Hetzner Console."
            exit 1
        fi
        log_done "User confirmed overwrite of ${#PREEXISTING_RECORDS[@]} existing record(s)"
    fi
fi

# ============================================================================
# DNS RECORDS
# ============================================================================
step "Step 4: DNS records"

# Notification email is an org-wide constant - used in the DMARC rua and CAA
# iodef records below. Hardcoded here so it always matches phase0-bootstrap.sh,
# which uses the same constant for Let's Encrypt / WordPress. It is published
# in DNS anyway, so it is not a secret.
NOTIFICATION_EMAIL="wglover@docentims.com"
echo "  Notification email: $NOTIFICATION_EMAIL"

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

# If the CAA rrset exists, delete it, then recreate cleanly.
hcloud_get "/zones/${ZONE_ID}/rrsets/@/CAA" >/dev/null 2>&1
if [ "$HCLOUD_LAST_STATUS" = "200" ]; then
    hcloud_request DELETE "/zones/${ZONE_ID}/rrsets/@/CAA" >/dev/null 2>&1
fi
CAA_RESP=$(hcloud_post "/zones/${ZONE_ID}/rrsets" "$CAA_BODY")

if echo "$CAA_RESP" | jq -e '.rrset.id' >/dev/null 2>&1; then
    log_done "CAA  @ (Let's Encrypt only)"
else
    log_fail "CAA  @"
    echo "$CAA_RESP" | jq -r '.error.message // empty' >&2
fi

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
# WAIT FOR THE NEW SERVER TO ACCEPT SSH, THEN RECORD ITS HOST KEY
# ============================================================================
# A freshly-created server needs a short while to finish booting before its
# SSH service answers. Until it does, the scp/ssh handoff printed below would
# fail with a raw "Connection closed". We poll here - with a friendly message
# so the user knows to simply wait - and, once the server answers, record its
# host key in known_hosts. Pre-registering the key means the handoff ssh/scp
# below will NOT trigger the OpenSSH "Are you sure you want to continue
# connecting?" prompt.
#
# (For a reused, already-running server this just succeeds on the first try.)
step "Step 6: Waiting for the new server to accept SSH"

echo "  A brand-new server takes 1-2 minutes to finish booting before it"
echo "  will answer SSH. Please wait - no action needed..."

SSH_READY="no"
KNOWN_HOSTS="$HOME/.ssh/known_hosts"
mkdir -p "$HOME/.ssh"
printf "  Waiting"
for attempt in $(seq 1 36); do
    # ssh-keyscan does double duty here: it confirms SSH is answering AND
    # returns the host key for us to store.
    SCANNED=$(ssh-keyscan -T 5 "$SERVER_IP" 2>/dev/null)
    if [ -n "$SCANNED" ]; then
        # Drop any prior entry for this IP, then add the freshly-scanned key.
        ssh-keygen -R "$SERVER_IP" -f "$KNOWN_HOSTS" >/dev/null 2>&1 || true
        echo "$SCANNED" >> "$KNOWN_HOSTS"
        SSH_READY="yes"
        break
    fi
    printf "."
    sleep 5
done
echo ""

if [ "$SSH_READY" = "yes" ]; then
    log_done "New server is accepting SSH; host key recorded - handoff will not prompt"
else
    log_warn "Server has not answered SSH yet after waiting a few minutes"
    echo "  It may simply need a little longer. If the scp/ssh steps below"
    echo "  fail with 'Connection closed', wait a minute and run them again."
fi

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
  DKIM:     added automatically after phase 4 by run-phases.sh (post-dkim)

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
  2. Copy bootstrap.sh and the three handoff files to the new server.
     Copy-paste BOTH lines below - the first moves you to the repo root
     so the scp works no matter where you currently are:
       cd ${REPO_ROOT}
       scp scripts/bootstrap.sh tenant.local hetzner.local org-secrets.local root@${SERVER_IP}:/root/
  3. SSH to the new server:
       ssh root@${SERVER_IP}
  4. Run: bash /root/bootstrap.sh
     (bootstrap.sh registers this server's key with GitHub, clones the
      repo with that key, moves the three handoff files into the repo,
      and chains straight into phase 0 - which runs with no prompts since
      DOMAIN, SERVER_IP and the RC+ key are already supplied)
  5. When phase 0 finishes, run:
       sudo bash /root/server-build/scripts/run-phases.sh
     (runs phases 1-6 plus the DKIM DNS record automatically; it will
      prompt before the optional Plone phases)

EOF
