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
# Confirmed response shape (from the docs sample, used by phase4b):
#   {
#     "data": {
#       "domains": [
#         {
#           "domain": {
#             "fulldomain":      "<domain>",
#             "dkim_selector":   "s123456",
#             "dkim_value":      "dkim.smtp2go.net",
#             "dkim_verified":   bool,
#             "rpath_selector":  "em123456",
#             "rpath_value":     "return.smtp2go.net",
#             "rpath_verified":  bool
#           },
#           "trackers": [
#             { "subdomain": "link", "cname_value": "...", "enabled": bool, ... }
#           ]
#         }
#       ]
#     }
#   }
# Both POST /v3/domain/add and POST /v3/domain/view return objects with this
# shape (add returns the just-added domain wrapped in the same list form).

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

# Register a sender domain. $1 = domain (e.g. chelseamallproject.com).
# auto_verify=false: the caller is expected to publish the CNAMEs in DNS
# first, then call smtp2go_domain_verify explicitly. This avoids the
# add-then-fail-verification-then-poll-every-7-min cycle when DNS isn't ready.
smtp2go_domain_add() {
    local domain="$1"
    smtp2go_request "domain/add" \
        "$(jq -n --arg d "$domain" '{domain: $d, auto_verify: false}')"
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

# Returns 0 if a domain has both DKIM and return-path verified by SMTP2GO,
# 1 otherwise (or if the API call fails).
smtp2go_domain_is_verified() {
    local domain="$1" resp
    resp=$(smtp2go_domain_view "$domain") || return 1
    echo "$resp" | jq -e '
        .data.domains[0].domain
        | (.dkim_verified == true and .rpath_verified == true)
    ' >/dev/null 2>&1
}
