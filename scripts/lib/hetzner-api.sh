#!/bin/bash
#
# hetzner-api.sh - Shared helpers for talking to the Hetzner Cloud API.
#
# Sourced by phase-pre-hetzner.sh and phase-post-hetzner-dkim.sh.
# Not meant to be executed directly.
#
# All functions assume HETZNER_CLOUD_TOKEN is exported in the environment.
# Functions write JSON responses to stdout and progress/errors to stderr.
#
# Required tools: curl, jq. The pre-flight check in the calling script must
# verify both are installed (jq is NOT preinstalled on a fresh Ubuntu).

# Guard against double-sourcing. Bash sources are cheap but the curl
# wrapper redefinition would confuse `type -t` debugging.
if [ -n "${__HETZNER_API_SH_LOADED:-}" ]; then
    return 0
fi
__HETZNER_API_SH_LOADED=1

# ============================================================================
# CONFIGURATION
# ============================================================================
HCLOUD_API_BASE="${HCLOUD_API_BASE:-https://api.hetzner.cloud/v1}"

# Default timeouts (seconds). Servers can take 30-60s to provision; we poll.
HCLOUD_CURL_CONNECT_TIMEOUT="${HCLOUD_CURL_CONNECT_TIMEOUT:-10}"
HCLOUD_CURL_MAX_TIME="${HCLOUD_CURL_MAX_TIME:-30}"
HCLOUD_POLL_INTERVAL="${HCLOUD_POLL_INTERVAL:-3}"
HCLOUD_POLL_MAX_SECONDS="${HCLOUD_POLL_MAX_SECONDS:-300}"

# ============================================================================
# LOW-LEVEL CURL WRAPPER
# ============================================================================
# hcloud_request METHOD PATH [JSON_BODY]
#
# Performs an authenticated API call. Returns the body on stdout and writes
# the HTTP status to the variable HCLOUD_LAST_STATUS (so callers can inspect
# it without re-parsing). Returns 0 if status is 2xx, 1 otherwise.
#
# We DON'T use --fail because we want to read the error body for diagnostics.
hcloud_request() {
    local method="$1"
    local path="$2"
    local body="${3:-}"

    if [ -z "${HETZNER_CLOUD_TOKEN:-}" ]; then
        echo "hcloud_request: HETZNER_CLOUD_TOKEN is not set" >&2
        HCLOUD_LAST_STATUS="000"
        return 1
    fi

    # Use a tempfile for the body so the status line doesn't get mashed
    # into the JSON. curl's -w prints to stdout AFTER the body, so we
    # split with a marker.
    local resp_file
    resp_file=$(mktemp)
    local status

    if [ -n "$body" ]; then
        status=$(curl -sS \
            -X "$method" \
            -H "Authorization: Bearer $HETZNER_CLOUD_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$body" \
            --connect-timeout "$HCLOUD_CURL_CONNECT_TIMEOUT" \
            --max-time "$HCLOUD_CURL_MAX_TIME" \
            -o "$resp_file" \
            -w "%{http_code}" \
            "${HCLOUD_API_BASE}${path}" 2>/dev/null) || status="000"
    else
        status=$(curl -sS \
            -X "$method" \
            -H "Authorization: Bearer $HETZNER_CLOUD_TOKEN" \
            --connect-timeout "$HCLOUD_CURL_CONNECT_TIMEOUT" \
            --max-time "$HCLOUD_CURL_MAX_TIME" \
            -o "$resp_file" \
            -w "%{http_code}" \
            "${HCLOUD_API_BASE}${path}" 2>/dev/null) || status="000"
    fi

    HCLOUD_LAST_STATUS="$status"
    cat "$resp_file"
    rm -f "$resp_file"

    case "$status" in
        2*) return 0 ;;
        *)  return 1 ;;
    esac
}

# Convenience wrappers. These are what the phase scripts actually call.
hcloud_get()    { hcloud_request "GET"    "$1"; }
hcloud_post()   { hcloud_request "POST"   "$1" "$2"; }
hcloud_put()    { hcloud_request "PUT"    "$1" "$2"; }
hcloud_delete() { hcloud_request "DELETE" "$1"; }

# ============================================================================
# TOKEN VALIDATION
# ============================================================================
# hcloud_validate_token - verify the token works by listing locations
# (cheap, read-only, always available). Returns 0 if valid.
hcloud_validate_token() {
    local resp
    resp=$(hcloud_get "/locations")
    if [ "$HCLOUD_LAST_STATUS" = "200" ]; then
        return 0
    fi
    echo "  Token validation failed (HTTP $HCLOUD_LAST_STATUS)" >&2
    # Print error message if the response is JSON with an error block
    if command -v jq >/dev/null 2>&1; then
        echo "$resp" | jq -r '.error.message // empty' 2>/dev/null >&2
    fi
    return 1
}

# ============================================================================
# SSH KEYS
# ============================================================================
# hcloud_ssh_key_id_by_fingerprint FINGERPRINT
# Returns the numeric SSH key ID on stdout, or empty if not found.
hcloud_ssh_key_id_by_fingerprint() {
    local fp="$1"
    local resp
    resp=$(hcloud_get "/ssh_keys")
    [ "$HCLOUD_LAST_STATUS" = "200" ] || return 1
    echo "$resp" | jq -r --arg fp "$fp" '.ssh_keys[] | select(.fingerprint == $fp) | .id' | head -1
}

# hcloud_ssh_key_upload NAME PUBLIC_KEY
# Uploads a public key and prints the new key ID on stdout.
hcloud_ssh_key_upload() {
    local name="$1"
    local pubkey="$2"
    local body
    body=$(jq -n --arg name "$name" --arg pk "$pubkey" \
        '{name: $name, public_key: $pk}')
    local resp
    resp=$(hcloud_post "/ssh_keys" "$body")
    if [ "$HCLOUD_LAST_STATUS" != "201" ] && [ "$HCLOUD_LAST_STATUS" != "200" ]; then
        echo "  SSH key upload failed (HTTP $HCLOUD_LAST_STATUS): $(echo "$resp" | jq -r '.error.message // .')" >&2
        return 1
    fi
    echo "$resp" | jq -r '.ssh_key.id'
}

# ============================================================================
# SERVERS
# ============================================================================
# hcloud_server_id_by_name NAME
# Returns server ID or empty. Used for idempotency.
hcloud_server_id_by_name() {
    local name="$1"
    local resp
    resp=$(hcloud_get "/servers?name=${name}")
    [ "$HCLOUD_LAST_STATUS" = "200" ] || return 1
    echo "$resp" | jq -r '.servers[0].id // empty'
}

# hcloud_server_ipv4 SERVER_ID
hcloud_server_ipv4() {
    local id="$1"
    local resp
    resp=$(hcloud_get "/servers/${id}")
    [ "$HCLOUD_LAST_STATUS" = "200" ] || return 1
    echo "$resp" | jq -r '.server.public_net.ipv4.ip // empty'
}

# hcloud_server_status SERVER_ID
hcloud_server_status() {
    local id="$1"
    local resp
    resp=$(hcloud_get "/servers/${id}")
    [ "$HCLOUD_LAST_STATUS" = "200" ] || return 1
    echo "$resp" | jq -r '.server.status // empty'
}

# hcloud_wait_for_action ACTION_ID
# Polls the action endpoint until status is "success" or "error", or until
# HCLOUD_POLL_MAX_SECONDS elapses. Returns 0 on success.
hcloud_wait_for_action() {
    local action_id="$1"
    local elapsed=0
    local status resp

    while [ "$elapsed" -lt "$HCLOUD_POLL_MAX_SECONDS" ]; do
        resp=$(hcloud_get "/actions/${action_id}")
        if [ "$HCLOUD_LAST_STATUS" != "200" ]; then
            echo "  ! action poll returned HTTP $HCLOUD_LAST_STATUS" >&2
            sleep "$HCLOUD_POLL_INTERVAL"
            elapsed=$((elapsed + HCLOUD_POLL_INTERVAL))
            continue
        fi

        status=$(echo "$resp" | jq -r '.action.status')
        case "$status" in
            success)
                return 0
                ;;
            error)
                echo "  ! action $action_id failed:" >&2
                echo "$resp" | jq -r '.action.error.message // "(no message)"' >&2
                return 1
                ;;
            running|*)
                # progress is 0-100 in .action.progress
                local progress
                progress=$(echo "$resp" | jq -r '.action.progress // 0')
                echo "    ... action $action_id: ${progress}% (${elapsed}s elapsed)" >&2
                sleep "$HCLOUD_POLL_INTERVAL"
                elapsed=$((elapsed + HCLOUD_POLL_INTERVAL))
                ;;
        esac
    done

    echo "  ! timeout after ${HCLOUD_POLL_MAX_SECONDS}s waiting for action $action_id" >&2
    return 1
}

# ============================================================================
# ZONES (DNS) - new Cloud-Console DNS
# ============================================================================
# hcloud_zone_id_by_name NAME
# Returns zone ID or empty. Note: zones API uses string IDs, not numeric.
hcloud_zone_id_by_name() {
    local name="$1"
    local resp
    resp=$(hcloud_get "/zones?name=${name}")
    [ "$HCLOUD_LAST_STATUS" = "200" ] || return 1
    echo "$resp" | jq -r '.zones[0].id // empty'
}

# hcloud_zone_create NAME [TTL]
# Creates a primary zone. Prints zone ID on stdout.
hcloud_zone_create() {
    local name="$1"
    local ttl="${2:-3600}"
    local body
    body=$(jq -n \
        --arg name "$name" \
        --argjson ttl "$ttl" \
        '{name: $name, mode: "primary", ttl: $ttl}')
    local resp
    resp=$(hcloud_post "/zones" "$body")
    if [ "$HCLOUD_LAST_STATUS" != "201" ] && [ "$HCLOUD_LAST_STATUS" != "200" ]; then
        echo "  Zone create failed (HTTP $HCLOUD_LAST_STATUS): $(echo "$resp" | jq -r '.error.message // .')" >&2
        return 1
    fi
    echo "$resp" | jq -r '.zone.id'
}

# hcloud_zone_nameservers ZONE_ID
# Prints the authoritative NS hostnames the zone is delegated to (one per line).
hcloud_zone_nameservers() {
    local id="$1"
    local resp
    resp=$(hcloud_get "/zones/${id}")
    [ "$HCLOUD_LAST_STATUS" = "200" ] || return 1
    # The field name has shifted across API versions; try both.
    echo "$resp" | jq -r '
        (.zone.assigned_name_servers // .zone.name_servers // [])[]
        | (if type == "object" then .name else . end)
    '
}

# ============================================================================
# RRSETS (DNS records)
# ============================================================================
# In the new Cloud DNS, records are grouped into RRSets keyed by (name, type).
# An RRSet for "www" type "A" can have multiple records (round-robin).
# For our use case we always create RRSets with one record each, except SPF
# where we set a single TXT.
#
# hcloud_rrset_upsert ZONE_ID NAME TYPE VALUE [TTL] [PRIORITY]
#
# - NAME is the record name relative to the zone ("@", "www", "mail",
#   "_dmarc", "default._domainkey").
# - VALUE for TXT records must be a quoted string ("v=spf1 ..."). The
#   caller is responsible for the quoting; we pass it through verbatim.
# - PRIORITY is only used for MX records; pass empty otherwise.
hcloud_rrset_upsert() {
    local zone_id="$1"
    local name="$2"
    local type="$3"
    local value="$4"
    local ttl="${5:-3600}"
    local priority="${6:-}"

    # Check if an RRSet for this (name, type) already exists. If so, PUT
    # to update; otherwise POST to create.
    local rrset_id="${name}/${type}"
    local existing
    existing=$(hcloud_get "/zones/${zone_id}/rrsets/${rrset_id}")
    local exists=0
    if [ "$HCLOUD_LAST_STATUS" = "200" ]; then
        exists=1
    fi

    # Build the record entry.
    local record_json
    if [ -n "$priority" ]; then
        # MX records: value is "10 mail.example.com." - Hetzner accepts it
        # as a single string; preserve any leading priority the caller
        # included, OR build it from the priority arg if value doesn't
        # already start with a number.
        if echo "$value" | grep -qE '^[0-9]+ '; then
            record_json=$(jq -n --arg v "$value" '{value: $v}')
        else
            record_json=$(jq -n --arg v "${priority} ${value}" '{value: $v}')
        fi
    else
        record_json=$(jq -n --arg v "$value" '{value: $v}')
    fi

    local body
    body=$(jq -n \
        --arg name "$name" \
        --arg type "$type" \
        --argjson ttl "$ttl" \
        --argjson rec "$record_json" \
        '{name: $name, type: $type, ttl: $ttl, records: [$rec]}')

    local resp
    if [ "$exists" = "1" ]; then
        # Update existing RRSet. PUT replaces the record list, which is
        # what we want for our single-record-per-RRSet model.
        resp=$(hcloud_put "/zones/${zone_id}/rrsets/${rrset_id}" "$body")
    else
        resp=$(hcloud_post "/zones/${zone_id}/rrsets" "$body")
    fi

    case "$HCLOUD_LAST_STATUS" in
        200|201)
            return 0
            ;;
        *)
            echo "  RRSet $name $type failed (HTTP $HCLOUD_LAST_STATUS): $(echo "$resp" | jq -r '.error.message // .')" >&2
            return 1
            ;;
    esac
}

# ============================================================================
# UTILITY
# ============================================================================
# hcloud_require_jq - error out if jq isn't installed. Callers should run
# this before using any of the functions above (all of which require jq).
hcloud_require_jq() {
    if ! command -v jq >/dev/null 2>&1; then
        echo "ERROR: jq is required but not installed." >&2
        echo "  Install with: sudo apt-get update && sudo apt-get install -y jq" >&2
        return 1
    fi
    return 0
}
