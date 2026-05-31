#!/bin/bash
#
# lib/smtp2go-api.sh - Minimal helpers for the SMTP2GO v3 REST API.
#
# Sourced by phase scripts that need to register a sender domain in SMTP2GO
# and read back the per-account CNAME records (return-path, DKIM selector,
# linktrack) so we can publish them automatically in Hetzner DNS instead of
# prompting the operator to look them up by hand.
#
# Required env (typically from org-secrets.local):
#   SMTP2GO_API_KEY  - account API key (Settings -> API Keys in SMTP2GO).
#
# Conventions (mirror lib/hetzner-api.sh):
#   - All helpers print the response JSON to stdout. Callers parse with jq.
#   - The last HTTP status and last body are exported as SMTP2GO_LAST_STATUS /
#     SMTP2GO_LAST_BODY for debugging from the caller.
#   - On a non-2xx response the helper writes a one-line error to stderr and
#     returns 1.
#
# Endpoints exercised:
#   POST /v3/domain/add      register a sender domain
#   POST /v3/domain/view     fetch a sender domain's record (DNS records, etc.)
#   POST /v3/domain/verify   ask SMTP2GO to re-check the DNS records
#
# Note: SMTP2GO's published reference (developers.smtp2go.com) is gated to
# unauthenticated fetches at the time of writing, so the EXACT response field
# names are confirmed by phase4b on its first live run (it dumps the raw JSON
# to a debug file). Adjust the jq paths in phase4b if SMTP2GO's response shape
# differs from what we assume there.

set -u

SMTP2GO_API_BASE="${SMTP2GO_API_BASE:-https://api.smtp2go.com/v3}"

# ----------------------------------------------------------------------------
# Low-level: POST to the API. $1=endpoint path (no leading slash), $2=JSON body.
# ----------------------------------------------------------------------------
smtp2go_request() {
    local path="$1" body="$2"
    if [ -z "${SMTP2GO_API_KEY:-}" ]; then
        echo "smtp2go-api: SMTP2GO_API_KEY is not set" >&2
        return 1
    fi

    local raw http_code resp_body
    raw=$(curl -sS -w "\n__SMTP2GO_HTTP_STATUS__%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -H "X-Smtp2go-Api-Key: $SMTP2GO_API_KEY" \
        -d "$body" \
        "${SMTP2GO_API_BASE}/${path}")
    http_code=${raw##*__SMTP2GO_HTTP_STATUS__}
    resp_body=${raw%__SMTP2GO_HTTP_STATUS__*}

    SMTP2GO_LAST_STATUS="$http_code"
    SMTP2GO_LAST_BODY="$resp_body"
    echo "$resp_body"

    case "$http_code" in
        2*) return 0 ;;
        *)
            echo "smtp2go-api: HTTP $http_code from /${path}" >&2
            return 1
            ;;
    esac
}

# ----------------------------------------------------------------------------
# Domain helpers
# ----------------------------------------------------------------------------

# Register a sender domain. $1 = domain (e.g. chelseamallproject.com)
smtp2go_domain_add() {
    local domain="$1"
    smtp2go_request "domain/add" "$(jq -n --arg d "$domain" '{domain: $d}')"
}

# Fetch the current record for a sender domain (DNS records, verified status).
# $1 = domain.
smtp2go_domain_view() {
    local domain="$1"
    smtp2go_request "domain/view" "$(jq -n --arg d "$domain" '{domain: $d}')"
}

# Ask SMTP2GO to re-check DNS for the domain (after we've published the
# CNAMEs). $1 = domain.
smtp2go_domain_verify() {
    local domain="$1"
    smtp2go_request "domain/verify" "$(jq -n --arg d "$domain" '{domain: $d}')"
}

# Returns 0 if a domain is reported as verified by /domain/view, 1 otherwise.
# Tries a few common field-name spellings since the live response shape is
# being confirmed empirically.
smtp2go_domain_is_verified() {
    local domain="$1" resp
    resp=$(smtp2go_domain_view "$domain") || return 1
    echo "$resp" | jq -e '
        .data
        | (.verified // .is_verified // .dns_verified // .domain_verified // false)
        | if type == "boolean" then . else . == "true" end
    ' >/dev/null 2>&1
}
