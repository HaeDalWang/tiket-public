#!/usr/bin/env bash
set -euo pipefail

# billing-api.sh -- thin BILLING API wrapper.
#
# Resolves the BILLING API key with precedence:
#   1. BILLING_API_KEY environment variable (if non-empty)
#   2. BILLING_API_KEY line in ~/.config/msp/credential-broker.conf
#   3. fail closed (clear remediation message to stderr + non-zero exit)
#
# The resolved key is ONLY ever placed in the Authorization: Bearer header.
# It is never echoed to stdout/stderr or interpolated into any message.
#
# Usage: billing-api.sh METHOD PATH-or-URL [JSON_BODY]
#   METHOD       one of GET POST PUT HEAD (case-sensitive uppercase)
#   PATH-or-URL  /api/... OR an https://billing.example.com URL
#   JSON_BODY    optional; only used for POST/PUT (adds Content-Type + --data)

CONFIG_FILE="${HOME}/.config/msp/credential-broker.conf"
BASE_URL="https://billing.example.com"

usage() {
    cat >&2 <<'EOF'
사용법: billing-api.sh METHOD PATH-or-URL [JSON_BODY]

BILLING API를 호출하고 응답 본문(raw JSON)을 stdout으로 출력합니다.
API 키는 BILLING_API_KEY 환경변수 또는
~/.config/msp/credential-broker.conf 의 BILLING_API_KEY 라인에서 읽습니다.

인자:
  METHOD        GET | POST | PUT | HEAD (대문자)
  PATH-or-URL   /api/... 또는 https://billing.example.com 의 전체 URL
  JSON_BODY     선택. POST/PUT 시 요청 본문 (JSON)

예시:
  billing-api.sh GET "/api/admin/v1/companies"
  billing-api.sh POST "/api/v1/costs/ondemand/corp/monthly" '{"corpId":"..."}'
EOF
}

# trim -- strip leading/trailing whitespace via parameter expansion only.
# (copied verbatim from get-sts-token.sh to keep parsing behavior identical)
trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

# read_config_key -- parse CONFIG_FILE for the BILLING_API_KEY value.
# Mirrors the read loop in get-sts-token.sh but the case dispatch matches ONLY
# BILLING_API_KEY. Prints the value to stdout (empty string if not found).
read_config_key() {
    local found=""
    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        local line
        local key
        local value

        line="$(trim "$raw_line")"
        [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
        [[ "$line" != *=* ]] && continue

        key="$(trim "${line%%=*}")"
        value="$(trim "${line#*=}")"

        case "$key" in
            BILLING_API_KEY) found="$value" ;;
        esac
    done < "$CONFIG_FILE"

    printf '%s' "$found"
}

# resolve_key -- apply env -> conf -> fail-closed precedence.
# Prints the resolved key to stdout. On total failure, prints a remediation
# message to stderr and exits 1. NEVER prints the key value to stderr.
resolve_key() {
    # (1) environment variable wins.
    if [[ -n "${BILLING_API_KEY:-}" ]]; then
        printf '%s' "$BILLING_API_KEY"
        return 0
    fi

    # (2) fall back to the conf file.
    if [[ -f "$CONFIG_FILE" ]]; then
        local conf_value
        conf_value="$(read_config_key)"
        if [[ -n "$conf_value" ]]; then
            printf '%s' "$conf_value"
            return 0
        fi
    fi

    # (3) fail closed -- never echo the (absent) key, only remediation guidance.
    {
        echo "오류: BILLING_API_KEY를 환경변수에서도 설정 파일에서도 찾을 수 없습니다."
        echo "다음 중 하나로 키를 설정하세요:"
        echo "  - 환경변수: export BILLING_API_KEY=<발급받은 키>"
        echo "  - 설정 파일: ~/.config/msp/credential-broker.conf 에 아래 라인 추가"
        echo "      BILLING_API_KEY=<발급받은 키>"
        echo "설정 파일에는 비밀값이 저장되므로 반드시 'chmod 600 ~/.config/msp/credential-broker.conf' 로 권한을 제한하세요."
    } >&2
    exit 1
}

# Validate the destination before loading the bearer credential. Keep the
# accepted syntax identical to the PowerShell wrapper; no userinfo or ports.
resolve_url() {
    local target="$1"
    if [[ "$target" == *[[:space:][:cntrl:]]* || "$target" == *\\* || "$target" == //* ]]; then
        echo "오류: 허용되지 않은 BILLING URL 형식입니다." >&2
        return 1
    fi
    case "$target" in
        "$BASE_URL"|"$BASE_URL/"*|"$BASE_URL?"*)
            printf '%s' "$target"
            ;;
        /*)
            printf '%s' "${BASE_URL}${target}"
            ;;
        *)
            echo "오류: '/'로 시작하는 경로 또는 https://billing.example.com URL만 허용됩니다." >&2
            exit 1
            ;;
    esac
}

# do_request -- single curl call site. `curl` is resolved via PATH (not an
# absolute path) so tests can shim a fake curl. Mirrors get-sts-token.sh's
# error handling: capture stderr to a temp file, capture curl's real exit code
# in the `|| {}` branch, and surface the detail on failure.
do_request() {
    local method="$1"
    local url="$2"
    local bearer="$3"
    local body="$4"

    local curl_err
    curl_err="$(mktemp)"

    local -a curl_args
    # -q must be first: local curlrc options cannot add redirects/destinations.
    curl_args=(-q --globoff --proto '=https' -sS --max-time 30 -X "$method" -H "Authorization: Bearer ${bearer}")

    if [[ "$method" == "POST" || "$method" == "PUT" ]] && [[ -n "$body" ]]; then
        curl_args+=(-H "Content-Type: application/json" --data "$body")
    fi

    curl_args+=("$url")

    local response
    response="$(curl "${curl_args[@]}" 2>"$curl_err")" || {
        # Capture curl's real exit code via the || branch -- `if ! cmd; then $?`
        # would return the exit of `!` (always 1) and mask the curl error.
        local curl_exit=$?
        local err_detail
        err_detail="$(cat "$curl_err" 2>/dev/null || true)"
        rm -f "$curl_err"
        if [[ -n "$err_detail" ]]; then
            echo "오류: BILLING API 요청에 실패했습니다. (curl exit code: $curl_exit) $err_detail" >&2
        else
            echo "오류: BILLING API 요청에 실패했습니다. (curl exit code: $curl_exit)" >&2
        fi
        exit 1
    }

    rm -f "$curl_err"
    printf '%s\n' "$response"
}

main() {
    # --help / -h before anything else.
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        usage
        exit 0
    fi

    # Require METHOD + PATH.
    if [[ $# -lt 2 ]]; then
        usage
        exit 1
    fi

    local method="$1"
    local target="$2"
    local body="${3:-}"

    # Validate METHOD against the allowlist BEFORE resolving the key or curling.
    case "$method" in
        GET|POST|PUT|HEAD) ;;
        *)
            echo "오류: 허용되지 않은 METHOD 입니다: $method (허용: GET POST PUT HEAD)" >&2
            exit 1
            ;;
    esac

    local url
    url="$(resolve_url "$target")"

    local key
    key="$(resolve_key)"

    do_request "$method" "$url" "$key" "$body"
}

main "$@"
