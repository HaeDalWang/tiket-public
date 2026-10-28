#!/usr/bin/env bash
# get-sts-token.sh -- LOGIN-ONLY Slack token acquisition (CLI-03).
# Performs Slack OAuth + POST /v1/credentials to obtain the Slack Bearer, then
# persists AND emits ONLY the identity/cadence fields
# (Version, Expiration, BrokerVersion, SlackAccessToken, SlackUserId).
# The AWS-credential fields in the login response (AccessKeyId / SecretAccessKey
# / SessionToken) are a privileged crossaccount residue and are NEVER written to
# disk NOR printed to stdout (ROADMAP SC3: "distributes no AWS credential").
set -euo pipefail

CONFIG_FILE="${HOME}/.config/msp/credential-broker.conf"
CACHE_FILE="${HOME}/.cache/msp/sts-token.json"
CALLBACK_PORT="9876"
REDIRECT_URI="http://localhost:${CALLBACK_PORT}/callback"
AUTH_TIMEOUT_SECONDS="120"
CACHE_SKEW_SECONDS="300"

NO_BROWSER="false"
CLEAR_CACHE="false"
CHECK_ONLY="false"
API_URL=""
CLIENT_ID=""
PYTHON_SERVER_PID=""
TMP_DIR=""

_has_tty=""
if (exec 3>/dev/tty) 2>/dev/null; then
    _has_tty="true"
fi

user_msg() {
    if [[ "$_has_tty" == "true" ]]; then
        printf '%s\n' "$*" > /dev/tty
    else
        printf '%s\n' "$*" >&2
    fi
}

usage() {
    cat >&2 <<'EOF'
사용법: get-sts-token.sh [OPTIONS]

Slack OAuth 로그인을 수행하고 Slack 토큰만 캐시합니다.
(AWS 자격 증명은 디스크에 저장하지 않으며 stdout으로도 출력하지 않습니다.)

OPTIONS:
  --clear-cache      캐시된 토큰 삭제 후 다시 인증
  --no-browser       브라우저를 자동으로 열지 않고 URL만 출력
  --check-only       캐시 유효성만 확인 (유효: exit 0 + JSON, 만료/없음: exit 2, 브라우저 열지 않음)
  --help             도움말 출력

설정 파일:
  ~/.config/msp/credential-broker.conf

예시:
  # MSP 회사 Credential Broker 설정
  API_URL=https://xxx.execute-api.ap-northeast-2.amazonaws.com/Prod/v1/credentials
  CLIENT_ID=your-slack-app-client-id
  # (선택) BILLING_API_KEY 라인을 같은 파일에 둘 수 있습니다. 이 키는
  # billing-api.sh 가 읽으며 이 스크립트는 파싱하지 않습니다.
  #   BILLING_API_KEY=your-billing-api-key
  # 이 파일은 비밀값을 포함하므로 반드시 chmod 600 으로 권한을 제한하세요.
EOF
}

cleanup() {
    if [[ -n "${PYTHON_SERVER_PID}" ]] && kill -0 "${PYTHON_SERVER_PID}" 2>/dev/null; then
        kill "${PYTHON_SERVER_PID}" 2>/dev/null || true
        wait "${PYTHON_SERVER_PID}" 2>/dev/null || true
    fi

    if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
        rm -rf "${TMP_DIR}"
    fi
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

require_cmds() {
    for cmd in python3 curl; do
        if ! command -v "$cmd" &>/dev/null; then
            echo "오류: '$cmd'이(가) 설치되어 있지 않습니다." >&2
            exit 1
        fi
    done
}

emit_json_file() {
    local file_path="$1"

    python3 - "$file_path" <<'PY'
import json
import sys

with open(sys.argv[1], 'r', encoding='utf-8') as fp:
    data = json.load(fp)

json.dump(data, sys.stdout, separators=(',', ':'))
sys.stdout.write('\n')
PY
}

is_cache_valid() {
    [[ -f "$CACHE_FILE" ]] || return 1
    [[ ! -L "$CACHE_FILE" ]] || return 1

    python3 - "$CACHE_FILE" "$CACHE_SKEW_SECONDS" <<'PY'
import json
import sys
from datetime import datetime, timedelta, timezone

cache_file = sys.argv[1]
skew_seconds = int(sys.argv[2])

try:
    with open(cache_file, 'r', encoding='utf-8') as fp:
        data = json.load(fp)

    expiration = data.get('Expiration')
    if not expiration:
        raise ValueError('missing Expiration')

    expiration = expiration.strip()
    if expiration.endswith('Z'):
        expiration = expiration[:-1] + '+00:00'

    expires_at = datetime.fromisoformat(expiration)
    if expires_at.tzinfo is None:
        expires_at = expires_at.replace(tzinfo=timezone.utc)

    threshold = datetime.now(timezone.utc) + timedelta(seconds=skew_seconds)
    sys.exit(0 if expires_at > threshold else 1)
except Exception:
    sys.exit(1)
PY
}

read_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "오류: 설정 파일을 찾을 수 없습니다: $CONFIG_FILE" >&2
        echo "아래 내용으로 파일을 생성해주세요:" >&2
        cat >&2 <<'EOF'
# MSP 회사 Credential Broker 설정
API_URL=https://xxx.execute-api.ap-northeast-2.amazonaws.com/Prod/v1/credentials
CLIENT_ID=your-slack-app-client-id
# (선택) BILLING_API_KEY 는 billing-api.sh 가 읽는 키입니다 (이 스크립트는 파싱하지 않음).
# BILLING_API_KEY=your-billing-api-key
EOF
        echo "주의: 이 설정 파일은 비밀값을 포함하므로 chmod 600 으로 권한을 제한하세요." >&2
        exit 1
    fi

    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        local line
        local key
        local value

        line="$(trim "$raw_line")"
        [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
        [[ "$line" != *=* ]] && continue

        key="$(trim "${line%%=*}")"
        value="$(trim "${line#*=}")"

        # Only API_URL / CLIENT_ID are consumed here. A BILLING_API_KEY line may
        # also live in this conf file -- it is read by billing-api.sh, NOT here,
        # so it is intentionally ignored by this dispatch.
        case "$key" in
            API_URL) API_URL="$value" ;;
            CLIENT_ID) CLIENT_ID="$value" ;;
        esac
    done < "$CONFIG_FILE"

    if [[ -z "$API_URL" || -z "$CLIENT_ID" ]]; then
        echo "오류: 설정 파일에 API_URL과 CLIENT_ID를 모두 설정해야 합니다." >&2
        exit 1
    fi

    if [[ "$API_URL" != https://* ]]; then
        echo "오류: API_URL은 https://로 시작해야 합니다." >&2
        exit 1
    fi
}

generate_state() {
    python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(32))
PY
}

build_auth_url() {
    python3 - "$CLIENT_ID" "$REDIRECT_URI" "$1" <<'PY'
import sys
from urllib.parse import urlencode

client_id = sys.argv[1]
redirect_uri = sys.argv[2]
state = sys.argv[3]

params = urlencode({
    'client_id': client_id,
    'user_scope': 'identity.basic,identity.email',
    'redirect_uri': redirect_uri,
    'state': state,
})

print(f'https://slack.com/oauth/v2/authorize?{params}')
PY
}

start_callback_server() {
    local callback_file="$1"
    local ready_file="$2"

    python3 - "$callback_file" "$CALLBACK_PORT" "$ready_file" >/dev/null 2>&1 <<'PY' &
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

callback_file = sys.argv[1]
port = int(sys.argv[2])
ready_file = sys.argv[3]

class CallbackHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)

        if parsed.path != '/callback':
            self.send_response(404)
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.end_headers()
            self.wfile.write('Not Found'.encode('utf-8'))
            return

        params = parse_qs(parsed.query)
        payload = {
            'code': params.get('code', [''])[0],
            'state': params.get('state', [''])[0],
            'error': params.get('error', [''])[0],
        }

        with open(callback_file, 'w', encoding='utf-8') as fp:
            json.dump(payload, fp)

        body = '''<!doctype html>
<html lang="ko">
  <head>
    <meta charset="utf-8">
    <title>MSP 회사 인증 완료</title>
  </head>
  <body>
    <p>✅ 인증 완료! 이 창을 닫아도 됩니다.</p>
  </body>
</html>
'''

        encoded = body.encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)
        self.wfile.flush()
        self.server.should_stop = True

    def log_message(self, format, *args):
        return

server = HTTPServer(('127.0.0.1', port), CallbackHandler)
server.should_stop = False

# Signal readiness only after bind+listen succeeded. The main script polls
# this file instead of opening a probe TCP connection, which would otherwise
# consume one of this single-threaded server's handle_request() slots and
# race the real Slack callback (issue #4, Fix 2).
with open(ready_file, 'w', encoding='utf-8') as fp:
    fp.write('ready')

while not server.should_stop:
    server.handle_request()
PY

    PYTHON_SERVER_PID="$!"
}

wait_for_callback() {
    local callback_file="$1"
    local elapsed=0

    while (( elapsed < AUTH_TIMEOUT_SECONDS )); do
        if [[ -f "$callback_file" ]]; then
            return 0
        fi

        if [[ -n "$PYTHON_SERVER_PID" ]] && ! kill -0 "$PYTHON_SERVER_PID" 2>/dev/null; then
            break
        fi

        sleep 1
        elapsed=$((elapsed + 1))
    done

    if [[ -n "$PYTHON_SERVER_PID" ]] && kill -0 "$PYTHON_SERVER_PID" 2>/dev/null; then
        kill "$PYTHON_SERVER_PID" 2>/dev/null || true
        wait "$PYTHON_SERVER_PID" 2>/dev/null || true
        PYTHON_SERVER_PID=""
    fi

    echo "오류: 인증 시간 초과" >&2
    exit 1
}

read_callback_value() {
    local callback_file="$1"
    local key="$2"

    python3 - "$callback_file" "$key" <<'PY'
import json
import sys

with open(sys.argv[1], 'r', encoding='utf-8') as fp:
    data = json.load(fp)

value = data.get(sys.argv[2], '')
if not isinstance(value, str):
    value = '' if value is None else str(value)

sys.stdout.write(value)
PY
}

build_api_payload() {
    python3 - "$1" <<'PY'
import json
import sys

print(json.dumps({'code': sys.argv[1]}))
PY
}

validate_api_response() {
    local raw_response="$1"

    python3 - "$raw_response" <<'PY'
import json
import sys

raw = sys.argv[1]

try:
    data = json.loads(raw)
except json.JSONDecodeError as exc:
    print(f'오류: API 응답이 올바른 JSON이 아닙니다. ({exc})', file=sys.stderr)
    sys.exit(1)

error = data.get('error')
if error:
    if isinstance(error, str):
        print(f'오류: {error}', file=sys.stderr)
    else:
        print('오류: API가 오류를 반환했습니다.', file=sys.stderr)
        print(json.dumps(error, ensure_ascii=False), file=sys.stderr)
    sys.exit(1)

if data.get('Version') != 1:
    print('오류: API 응답에 Version=1 필드가 없습니다.', file=sys.stderr)
    sys.exit(1)

json.dump(data, sys.stdout, separators=(',', ':'))
sys.stdout.write('\n')
PY
}

open_browser() {
    local auth_url="$1"
    local opener=""

    # In --no-browser mode the caller is typically a headless agent/CI wrapper
    # that reliably captures stdout but may buffer or separately capture stderr.
    # Emit the URL on stdout with a stable, greppable marker so it is always
    # relayable. Gated on --no-browser ONLY: the AWS credential_process
    # invocation never passes --no-browser (and its cache-hit fast path never
    # reaches here), so its stdout stays pure JSON (issue #4, Fix 1).
    if [[ "$NO_BROWSER" == "true" ]]; then
        printf '\n[CSG-AUTH-URL] 아래 URL을 브라우저에서 열어 Slack 인증을 완료하세요:\n%s\n\n' "$auth_url"
    fi

    user_msg ""
    user_msg "브라우저가 열리지 않으면 아래 URL을 직접 열어주세요:"
    user_msg "$auth_url"
    user_msg ""

    if [[ "$NO_BROWSER" == "true" ]]; then
        return 0
    fi

    if command -v xdg-open &>/dev/null; then
        opener="xdg-open"
    elif command -v open &>/dev/null; then
        opener="open"
    fi

    if [[ -z "$opener" ]]; then
        user_msg "안내: 브라우저를 자동으로 열 수 없어 URL만 출력했습니다."
        return 0
    fi

    if ! "$opener" "$auth_url" >/dev/null 2>&1; then
        user_msg "안내: 브라우저 자동 실행에 실패했습니다. 위 URL을 직접 열어주세요."
    fi
}

trap cleanup EXIT

while [[ $# -gt 0 ]]; do
    case "$1" in
        --clear-cache) CLEAR_CACHE="true"; shift ;;
        --no-browser)  NO_BROWSER="true"; shift ;;
        --check-only)  CHECK_ONLY="true"; shift ;;
        --no-update)   shift ;;  # accepted for old callers; auto-update is gone
        --help)
            usage
            exit 0
            ;;
        *)
            echo "알 수 없는 옵션: $1" >&2
            usage
            exit 1
            ;;
    esac
done

# In --no-browser mode the user must copy the OAuth URL out-of-band and
# authenticate by hand, which takes longer than an auto-opened browser. Extend
# the callback wait so a human has time to complete it (issue #4). The AWS
# credential_process invocation never passes --no-browser, so its timeout is
# unchanged.
if [[ "$NO_BROWSER" == "true" ]]; then
    AUTH_TIMEOUT_SECONDS="300"
fi

require_cmds

# The skill ships inside the tiket workspace and updates with `git pull`; its old
# auto-update was removed on 2026-10-21 (a stale copy blocked every login).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- HOOK-A: auto-migrate to the csg- namespace (PROF-12) ---
# The clients themselves are the only delivery mechanism for this migration: an
# installer-hosted one reaches ~0 already-deployed machines.
#
# SCRIPT_DIR is the one defined above; do not recompute it.
#
# Shell out rather than source: get-customer-credentials.sh owns the migration,
# and its routing block exits long before the credential_process main flow, so a
# subprocess cannot recurse into that script's own hook.
#
# stdout ONLY is discarded. stderr stays attached because this is the ONE path
# with a real TTY -- the old->new mapping table is the single human-facing
# artifact of the whole migration, and an engineer (or agent) who never sees it
# keeps using the old profile names. `|| true` because a migration failure must
# never block a login.
#
# WR-04 -- COMPLETION-MARKER PRE-CHECK. HOOK-B guards its call the same way, and
# the comment there explains why: the steady state on an already-migrated machine
# must be ONE grep and complete silence. HOOK-A had no such guard, and
# get-sts-token.sh is csg-login's registered credential_process, so EVERY AWS call
# resolved through that profile forked a whole `bash` subprocess and printed
# "[migrate] status=already-migrated" onto the engineer's terminal -- forever. The
# marker file is the same one run_migration_once consults; matching on the id
# literal (not just the filename) means a FUTURE migration id re-arms this hook.
#
# WR-05 -- SWEEP BEFORE MIGRATE. HOOK-B's comment states this ordering is
# load-bearing: extract_cache_path keys the cache on the ACCOUNT ID (Phase 18
# collapse), so a freshly renamed `csg-X` inherits old `X`'s <account-id>.json,
# which is a 1-hour session and therefore almost always expired. Migrating first
# hands the next sweep a brand-new csg-X it classifies as expired and deletes on
# the spot -- so the mapping table printed HERE, "the single human-facing artifact
# of the whole migration", lists profile names that no longer exist by the time
# the engineer reads it. HOOK-A ran migrate with no preceding sweep at all.
# `cleanup` (no --all) IS the sweep: expired CSG profiles only, silent when it
# removes nothing (D-03). Its stdout is discarded like migrate's; stderr stays
# attached because this is the one path with a real TTY.
MIGRATION_RECORD_FILE="${HOME}/.cache/msp/customer-creds/migrations.jsonl"
if [[ -f "${SCRIPT_DIR}/get-customer-credentials.sh" ]] \
   && ! grep -Fq '"id":"v1.7-csg-namespace"' "$MIGRATION_RECORD_FILE" 2>/dev/null; then
    bash "${SCRIPT_DIR}/get-customer-credentials.sh" cleanup >/dev/null 2>&1 || true
    bash "${SCRIPT_DIR}/get-customer-credentials.sh" migrate >/dev/null || true
fi

if [[ "$CLEAR_CACHE" == "true" && -f "$CACHE_FILE" ]]; then
    rm -f "$CACHE_FILE"
fi

if is_cache_valid; then
    emit_json_file "$CACHE_FILE"
    exit 0
fi

if [[ "$CHECK_ONLY" == "true" ]]; then
    echo "오류: STS 토큰이 없거나 만료되었습니다. 터미널에서 get-sts-token.sh를 직접 실행하여 Slack 인증을 완료해주세요." >&2
    exit 2
fi

read_config

TMP_DIR="$(mktemp -d)"
CALLBACK_FILE="${TMP_DIR}/callback.json"
READY_FILE="${TMP_DIR}/server-ready"

STATE="$(generate_state)"
AUTH_URL="$(build_auth_url "$STATE")"

user_msg "로컬 인증 서버를 시작합니다."
start_callback_server "$CALLBACK_FILE" "$READY_FILE"

# Wait for the listener to actually be bound before opening the browser.
# A fixed 'sleep 1' raced cold-cache Python imports on slow systems: the
# kill -0 alive check passed before the socket was bound, the browser
# fired, Slack POSTed to the redirect, and the OS rejected with
# 'connection refused' before the listener existed.
#
# The server writes READY_FILE right after bind+listen, so we poll that file
# instead of opening a /dev/tcp probe. The old probe consumed one of the
# single-threaded server's handle_request() slots, racing the real Slack
# callback (issue #4, Fix 2).
_listener_ready=""
for _ in $(seq 1 40); do
    if [[ -f "$READY_FILE" ]]; then
        _listener_ready="true"
        break
    fi
    if ! kill -0 "$PYTHON_SERVER_PID" 2>/dev/null; then
        break
    fi
    sleep 0.25
done

if [[ -z "$_listener_ready" ]] || ! kill -0 "$PYTHON_SERVER_PID" 2>/dev/null; then
    echo "오류: 로컬 인증 서버를 시작하지 못했습니다. 포트 ${CALLBACK_PORT} 사용 여부를 확인해주세요." >&2
    exit 1
fi

open_browser "$AUTH_URL"

user_msg "Slack 인증을 기다리는 중입니다..."
wait_for_callback "$CALLBACK_FILE"

AUTH_CODE="$(read_callback_value "$CALLBACK_FILE" code)"
RETURNED_STATE="$(read_callback_value "$CALLBACK_FILE" state)"
CALLBACK_ERROR="$(read_callback_value "$CALLBACK_FILE" error)"

if [[ -n "$CALLBACK_ERROR" ]]; then
    echo "오류: Slack 인증 실패 - $CALLBACK_ERROR" >&2
    exit 1
fi

if [[ "$RETURNED_STATE" != "$STATE" ]]; then
    echo "오류: state 검증에 실패했습니다." >&2
    exit 1
fi

if [[ -z "$AUTH_CODE" ]]; then
    echo "오류: 인증 코드가 전달되지 않았습니다." >&2
    exit 1
fi

REQUEST_BODY="$(build_api_payload "$AUTH_CODE")"

user_msg "STS 자격 증명을 요청하는 중입니다."
# -sS already suppresses the progress bar while keeping errors on stderr,
# so the previous 2>/dev/null was actively harmful — it discarded the real
# DNS / TLS / HTTP-body context and left only "$?" for the user. Now: bound
# the call with --max-time (WR-08 bash half) and capture stderr to a temp
# file so the failure path can surface what curl actually saw.
CURL_ERR="${TMP_DIR}/curl.err"
API_RESPONSE="$(curl -sS --max-time 30 -X POST "$API_URL" \
        -H "Content-Type: application/json" -d "$REQUEST_BODY" 2>"$CURL_ERR")" || {
    # Capture curl's real exit code via the || branch — `if ! cmd; then $?`
    # would return the exit of `!` (always 1) and mask the curl error.
    curl_exit=$?
    err_detail="$(cat "$CURL_ERR" 2>/dev/null || true)"
    if [[ -n "$err_detail" ]]; then
        echo "오류: API 요청에 실패했습니다. (curl exit code: $curl_exit) $err_detail" >&2
    else
        echo "오류: API 요청에 실패했습니다. (curl exit code: $curl_exit)" >&2
    fi
    exit 1
}

if [[ -z "$API_RESPONSE" ]]; then
    echo "오류: API 응답이 비어있습니다." >&2
    exit 1
fi

VALIDATED_RESPONSE="$(validate_api_response "$API_RESPONSE")"

# CLI-03 (login-only): project the /v1/credentials response down to the
# identity/cadence fields BEFORE it touches disk or stdout. The AWS-credential
# fields (AccessKeyId/SecretAccessKey/SessionToken) are a privileged crossaccount
# residue that must NEITHER be persisted NOR distributed. Build the identity-only
# JSON ONCE and reuse it for both the cache write and the final stdout emission.
# Expiration is retained purely as the is_cache_valid re-login cadence marker.
IDENTITY_RESPONSE="$(printf '%s' "$VALIDATED_RESPONSE" | python3 -c '
import json, sys
d = json.load(sys.stdin)
keep = ("Version", "Expiration", "BrokerVersion", "SlackAccessToken", "SlackUserId")
json.dump({k: d[k] for k in keep if k in d}, sys.stdout, separators=(",", ":"))
')"

mkdir -p "$(dirname "$CACHE_FILE")"
# Atomic overwrite: any pre-existing file (incl. a stale pre-migration
# crossaccount session) is replaced, so no privileged residue can linger.
CACHE_TMP="$(mktemp "$(dirname "$CACHE_FILE")/.sts-token.XXXXXX")"
printf '%s\n' "$IDENTITY_RESPONSE" > "$CACHE_TMP"
chmod 600 "$CACHE_TMP"
mv -f "$CACHE_TMP" "$CACHE_FILE"

# Emit the SAME identity-only projection persisted above -- no AWS credential.
printf '%s\n' "$IDENTITY_RESPONSE"
