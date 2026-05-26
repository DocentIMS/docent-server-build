#!/bin/bash
#
# hetzner-api.sh - Shared helpers for talking to the Hetzner Cloud API.
#
# Assumes HETZNER_CLOUD_TOKEN is set in the environment.
# After each call, check $HCLOUD_LAST_STATUS for the HTTP status (or "000" on network error).

HCLOUD_API_BASE="${HCLOUD_API_BASE:-https://api.hetzner.cloud/v1}"
HCLOUD_CURL_CONNECT_TIMEOUT="${HCLOUD_CURL_CONNECT_TIMEOUT:-10}"
HCLOUD_CURL_MAX_TIME="${HCLOUD_CURL_MAX_TIME:-30}"
HCLOUD_LAST_STATUS="000"  # init so a bare read cannot trip set -u

# ============================================================================
# hcloud_request - Core function: make an HTTP request to the Hetzner API.
# Sets HCLOUD_LAST_STATUS to the HTTP status code after each call.
# Returns 0 if status is 2xx, 1 otherwise.
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
    local resp_file status
    resp_file=$(mktemp)
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
    export HCLOUD_LAST_STATUS="$status"
    cat "$resp_file"
    rm -f "$resp_file"
    case "$status" in
        2*) return 0 ;;
        *)  return 1 ;;
    esac
}

hcloud_get()    { hcloud_request "GET"    "$1"; }
hcloud_post()   { hcloud_request "POST"   "$1" "$2"; }
hcloud_put()    { hcloud_request "PUT"    "$1" "$2"; }
hcloud_delete() { hcloud_request "DELETE" "$1"; }

# ============================================================================
# hcloud_validate_token - verify the token works
hcloud_validate_token() {
    local resp
    resp=$(hcloud_get "/locations")
    # Decide from the response body, not HCLOUD_LAST_STATUS: hcloud_request
    # runs inside the $(...) subshell, so the status it exports never reaches
    # this function. A working token returns a locations array; a bad token
    # returns an .error object.
    if echo "$resp" | jq -e '(.locations | type) == "array"' >/dev/null 2>&1; then
        return 0
    fi
    echo "  Token validation failed" >&2
    if command -v jq >/dev/null 2>&1; then
        echo "$resp" | jq -r '.error.message // empty' 2>/dev/null >&2
    fi
    return 1
}

# ============================================================================
# SSH Key Management Functions
hcloud_ssh_key_id_by_fingerprint() {
    local fingerprint="$1"
    local resp
    resp=$(hcloud_get "/ssh_keys")
    # Decide from the response body, not HCLOUD_LAST_STATUS: hcloud_request
    # runs inside the $(...) subshell above, so the status it exports never
    # reaches this function. If the body is an error object instead of a
    # key list, .ssh_keys[]? simply yields nothing.
    echo "$resp" | jq -r --arg fp "$fingerprint" \
        '.ssh_keys[]? | select(.fingerprint == $fp) | .id' 2>/dev/null | head -1
}

hcloud_ssh_key_upload() {
    local name="$1"
    local pubkey="$2"
    local body resp key_id list
    local keypart
    keypart=$(echo "$pubkey" | awk '{print $1" "$2}')

    list=$(hcloud_get "/ssh_keys")
    key_id=$(echo "$list" | jq -r --arg k "$keypart" '.ssh_keys[]? | select((.public_key | split(" ")[0:2] | join(" ")) == $k) | .id' | head -1)
    if [ -n "$key_id" ] && [ "$key_id" != "null" ]; then
        echo "$key_id"
        return 0
    fi

    body=$(jq -n --arg n "$name" --arg k "$pubkey" '{name: $n, public_key: $k}')
    resp=$(hcloud_post "/ssh_keys" "$body")

    # Decide from the response body, not HCLOUD_LAST_STATUS: hcloud_request
    # runs inside the $(...) subshell, so the status it exports never reaches
    # us. A successful create returns the new key under .ssh_key.id.
    key_id=$(echo "$resp" | jq -r '.ssh_key.id // empty' 2>/dev/null)
    if [ -n "$key_id" ]; then
        echo "$key_id"
        return 0
    fi

    if echo "$resp" | jq -e '.error.code == "uniqueness_error"' >/dev/null 2>&1; then
        list=$(hcloud_get "/ssh_keys")
        key_id=$(echo "$list" | jq -r --arg k "$keypart" '.ssh_keys[]? | select((.public_key | split(" ")[0:2] | join(" ")) == $k) | .id' | head -1)
        if [ -n "$key_id" ] && [ "$key_id" != "null" ]; then
            echo "$key_id"
            return 0
        fi
    fi

    return 1
}

# ============================================================================
# Server Functions
hcloud_server_id_by_name() {
    local name="$1"
    local resp
    resp=$(hcloud_get "/servers")
    echo "$resp" | jq -r ".servers[] | select(.name == \"$name\") | .id" 2>/dev/null | head -1
}

hcloud_server_ipv4() {
    local server_id="$1"
    local resp
    resp=$(hcloud_get "/servers/$server_id")
    echo "$resp" | jq -r '.server.public_net.ipv4.ip // empty' 2>/dev/null
}

hcloud_wait_for_action() {
    local action_id="$1"
    local max_wait="${2:-300}"
    local elapsed=0
    local resp status
    while [ $elapsed -lt "$max_wait" ]; do
        resp=$(hcloud_get "/actions/$action_id")
        status=$(echo "$resp" | jq -r '.action.status' 2>/dev/null)
        if [ "$status" = "success" ]; then
            return 0
        fi
        if [ "$status" = "error" ]; then
            return 1
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    return 1
}

# ============================================================================
# DNS Zone Functions
hcloud_zone_id_by_name() {
    local domain="$1"
    local resp
    resp=$(hcloud_get "/zones")
    echo "$resp" | jq -r ".zones[] | select(.name == \"$domain\") | .id" 2>/dev/null | head -1
}

hcloud_zone_create() {
    local domain="$1"
    local body resp zid
    body=$(jq -n --arg n "$domain" '{name: $n, mode: "primary"}')
    resp=$(hcloud_post "/zones" "$body")
    zid=$(echo "$resp" | jq -r '.zone.id // empty' 2>/dev/null)
    if [ -n "$zid" ]; then echo "$zid"; return 0; fi
    echo "$resp" | jq -r '.error.message // empty' >&2
    return 1
}

hcloud_zone_nameservers() {
    local zone_id="$1"
    local resp
    resp=$(hcloud_get "/zones/$zone_id")
    # Current API nests them under authoritative_nameservers.assigned;
    # fall back to the older .zone.ns for safety.
    echo "$resp" | jq -r '
        (.zone.authoritative_nameservers.assigned // .zone.ns // [])[]
        | rtrimstr(".")' 2>/dev/null
}

hcloud_rrset_upsert() {
    local zone_id="$1"
    local name="$2"
    local type="$3"
    local value="$4"
    local ttl="${5:-3600}"
    local body resp

    body=$(jq -n \
        --arg n "$name" \
        --arg t "$type" \
        --arg v "$value" \
        --argjson ttl "$ttl" \
        '{name: $n, type: $t, ttl: $ttl, records: [{value: $v}]}')

    local existing
    existing=$(hcloud_request GET "/zones/${zone_id}/rrsets/${name}/${type}")
    if echo "$existing" | jq -e '.rrset.id' >/dev/null 2>&1; then
        hcloud_request DELETE "/zones/${zone_id}/rrsets/${name}/${type}" >/dev/null 2>&1
    fi

    resp=$(hcloud_post "/zones/${zone_id}/rrsets" "$body")
    if echo "$resp" | jq -e '.rrset.id' >/dev/null 2>&1; then
        return 0
    fi
    echo "$resp" | jq -r '.error.message // empty' >&2
    return 1
}

# ============================================================================
# hcloud_print_server_types - List server types actually available at a
# given location, with specs. Used to build a live menu instead of a
# hardcoded one. Prints "  name  N vCPU / N GB RAM / N GB disk  ~EURn/mo"
# per line (the monthly price is for the given location).
# Returns 1 (and prints nothing) if the API can't be reached.
hcloud_print_server_types() {
    local location="$1"
    local dc_resp st_resp ids id
    dc_resp=$(hcloud_get "/datacenters")
    ids=$(echo "$dc_resp" | jq -r --arg loc "$location" \
        '.datacenters[]? | select(.location.name == $loc) | .server_types.available[]' 2>/dev/null)
    [ -n "$ids" ] || return 1
    st_resp=$(hcloud_get "/server_types")
    echo "$st_resp" | jq -e '.server_types' >/dev/null 2>&1 || return 1
    for id in $ids; do
        echo "$st_resp" | jq -r --argjson id "$id" --arg loc "$location" \
            '.server_types[]? | select(.id == $id and .deprecation == null) | . as $st
             | ([ $st.prices[]? | select(.location == $loc) | .price_monthly.gross ] | .[0] // "") as $g
             | (if $g == "" then ""
                else ($g | split(".")) as $p
                     | "  ~EUR " + $p[0] + "." + (($p[1] // "") + "00")[0:2] + "/mo"
                end) as $price
             | "  \($st.name)  \($st.cores) vCPU / \($st.memory) GB RAM / \($st.disk) GB disk\($price)"' 2>/dev/null
    done | sort
}
