#!/usr/bin/env bash
#
# onboarding.sh — macOS / Linux 온보딩. Windows 는 onboarding.ps1 을 쓴다.
#
# 셸 프로필(~/.zshenv, ~/.bashrc 등)을 건드리지 않는다. 사용자가 어떤 셸을 쓰는지
# 알 수 없기 때문이다. 자격증명은 ~/.config/msp/*.conf 에 저장하고, 이 저장소의
# 스크립트가 그 파일을 직접 읽는다. support-skills install.sh 와 같은 규약이다.
#
# 사용:
#   bash scripts/onboarding.sh            대화형 (자격증명 입력 포함)
#   bash scripts/onboarding.sh --check    확인만 (입력 없음, CI·에이전트용)

set -uo pipefail

# STEPS-PARITY-START
STEP_NAMES=(
  "required-tools"
  "agents"
  "push-guard"
  "mcp"
  "customer-skill"
  "zendesk-credentials"
  "itsm-token"
  "usage-telemetry"
  "workspace-validation"
)
# STEPS-PARITY-END

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 에이전트 이름 → 스킬 설치 경로. install.sh 의 테이블과 같은 규약.
AGENT_NAMES=(claude-code opencode kiro cursor windsurf augment codex gemini hermes)
AGENT_HOMES=(
  "$HOME/.claude" "$HOME/.config/opencode" "$HOME/.kiro" "$HOME/.cursor"
  "$HOME/.codeium/windsurf" "$HOME/.augment" "$HOME/.agents" "$HOME/.gemini" "$HOME/.hermes"
)

CONF_DIR="$HOME/.config/msp"
ZENDESK_CONF="$CONF_DIR/zendesk.conf"
USAGE_CONF="$CONF_DIR/tiket-usage.conf"
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

# 결과는 셋으로 가른다 (2026-10-01). 하나만 빠져도 빨간 FAIL·exit 1 이라 동료가 유지보수자를 불렀다.
#   막힘 — 워크스페이스가 안 돌거나 경계가 깨진다. 이것만 exit 1 이다
#   제한 — 그 기능만 빠지고 나머지는 돈다. 어떤 기능이 빠지는지 이름을 붙인다
#   건너뜀 — 해당 없거나 대체 경로가 있다
# OUTCOME-START
# '제한' 이 붙이는 기능 이름. 세션 시작 알림(scripts/local_capabilities.py)과 같은 말이다.
F_TICKET="티켓 번호로 가져오기"
F_CUSTOMER="고객 AWS·비용 조회"
F_NOTES="고객 특이사항 읽기"
F_HERMES="Hermes 자동 업데이트·지표"
F_METRICS="지표에 내 이름 표시"
F_VALIDATE="저장소 규칙 검사"
blocked_count=0
limited_features=""
ok()      { printf '  \033[32mOK\033[0m    %s\n' "$1"; }
blocked() { printf '  \033[31m막힘\033[0m  %s\n' "$1"; blocked_count=$((blocked_count + 1)); }
limited() {  # limited <빠지는 기능> <이유와 해결>
  printf '  \033[33m제한\033[0m  [%s] %s\n' "$1" "$2"
  case "|$limited_features|" in
    *"|$1|"*) ;;
    *) limited_features="${limited_features:+$limited_features|}$1" ;;
  esac
}
skip()    { printf '  \033[33m건너뜀\033[0m %s\n' "$1"; }
step()    { printf '\n[%s] %s\n' "$1" "$2"; }
finish() {
  local limits=""
  [ -n "$limited_features" ] && limits="이 PC 에서 아직 안 되는 것: ${limited_features//|/, } (위 '제한' 줄). 나머지는 지금 쓸 수 있다."
  echo
  if [ "$blocked_count" -gt 0 ]; then
    printf "\033[31m막힌 항목 %d개\033[0m — 이것부터 풀어야 워크스페이스가 돈다. 위 '막힘' 줄의 해결 방법을 따른 뒤 다시 실행한다.\n" "$blocked_count"
    [ -n "$limits" ] && printf '%s\n' "$limits"
    exit 1
  fi
  printf '\033[32m온보딩 완료.\033[0m 다음: ONBOARDING.md 의 "연습해보기"\n'
  printf 'AI 도구는 항상 이 폴더(%s)를 열어서 시작한다 — 상위 폴더를 열면 규칙·훅이 조용히 빠진다.\n' "$ROOT"
  [ -n "$limits" ] && printf '%s\n' "$limits"
  exit 0
}
# OUTCOME-END

# ── 1. required-tools ────────────────────────────────────────────────────────
step 1/9 "필수 도구"
for bin in git python3 curl jq; do
  if command -v "$bin" >/dev/null 2>&1; then
    ok "$bin"
  elif [ "$bin" = git ] || [ "$bin" = python3 ]; then
    blocked "$bin 없음 — macOS: brew install $bin"
  else
    # curl·jq 는 fetch-ticket.sh 만 쓴다
    limited "$F_TICKET" "$bin 없음 — macOS: brew install $bin"
  fi
done
# ── 2. agents ────────────────────────────────────────────────────────────────
step 2/9 "설치된 에이전트"
detected_agents=()
for i in "${!AGENT_NAMES[@]}"; do
  if [ -d "${AGENT_HOMES[$i]}" ]; then
    detected_agents+=("${AGENT_NAMES[$i]}")
    skill_dir="${AGENT_HOMES[$i]}/skills/aws-customer-account-ops"
    if [ -f "$skill_dir/SKILL.md" ]; then
      ok "${AGENT_NAMES[$i]}  (고객 조회 스킬 있음)"
    else
      ok "${AGENT_NAMES[$i]}"
    fi
  fi
done
if [ "${#detected_agents[@]}" -eq 0 ]; then
  blocked "감지된 에이전트 없음 — Claude Code·Codex·Kiro·Hermes 중 하나는 설치돼 있어야 한다"
fi

# ── 2. push-guard ────────────────────────────────────────────────────────────
# 고객 자료가 공용 저장소로 나가는 걸 막는 hook. 활성화는 로컬에서 한 번 해야 한다.
step 3/9 "push guard"
current_hooks=$(git -C "$ROOT" config --get core.hooksPath 2>/dev/null || true)
if [ "$current_hooks" = ".githooks" ]; then
  ok "core.hooksPath = .githooks"
elif [ "$CHECK_ONLY" -eq 1 ]; then
  blocked "core.hooksPath 미설정 — 해결: git config core.hooksPath .githooks"
else
  if git -C "$ROOT" config core.hooksPath .githooks; then
    ok "core.hooksPath 를 .githooks 로 설정했다"
  else
    blocked "core.hooksPath 를 설정하지 못했다 — 해결: git config core.hooksPath .githooks"
  fi
fi
if [ -x "$ROOT/.githooks/pre-push" ]; then
  ok "pre-push hook 실행 가능"
else
  blocked "pre-push hook 이 없거나 실행 권한 없음 — chmod +x .githooks/pre-push"
fi

# ── 4. mcp ───────────────────────────────────────────────────────────────────
# MCP 설정 파일은 clone 으로 따라온다. 확인할 것은 "실제로 붙는가" 뿐이다.
step 4/9 "MCP 연결"
for host in .mcp.json .claude/settings.json .codex/config.toml .kiro/settings/mcp.json; do
  [ -f "$ROOT/$host" ] || blocked "MCP 설정 누락: $host — python3 scripts/render_agent_configs.py 로 생성"
done
if command -v python3 >/dev/null 2>&1; then
  mcp_out=$(cd "$ROOT" && python3 scripts/verify_mcp_servers.py 2>&1)
  mcp_rc=$?
  mcp_last=$(printf '%s' "$mcp_out" | tail -1)
  case "$mcp_rc" in
    0) ok "$mcp_last" ;;
    2) skip "$mcp_last" ;;   # 전제 조건 미비·네트워크 — 경계 위반이 아니다
    *) blocked "$mcp_last" ;;
  esac
fi
if [ -d "$HOME/.hermes" ]; then
  skip "Hermes 는 MCP 설정을 저장소 밖 프로필에 둔다. agents/environment/mcp-manifest.json 에 맞춰 직접 정렬한다"
  # Hermes 는 저장소 훅을 읽지 않는다. 세션 시작 훅(업데이트·지표)을 사용자 설정에 등록한다.
  # --check 는 상태만 본다. 등록은 ~/.hermes/config.yaml 을 백업한 뒤에 하고 되돌리는 명령을 알린다.
  if [ "$CHECK_ONLY" -eq 1 ]; then
    hermes_state=$(python3 "$ROOT/scripts/hermes_hook.py" --status 2>/dev/null) && ok "Hermes 세션 훅: $hermes_state" \
      || skip "Hermes 세션 훅: ${hermes_state:-확인하지 못했다}"
  else
    hermes_out=$(python3 "$ROOT/scripts/hermes_hook.py" --install 2>&1); hermes_rc=$?
    if [ "$hermes_rc" -eq 0 ]; then
      ok "Hermes 세션 훅: $(printf '%s' "$hermes_out" | head -1)"
      printf '%s\n' "$hermes_out" | tail -n +2 | sed 's/^/        /'
    else
      limited "$F_HERMES" "Hermes 세션 훅: $hermes_out"
    fi
  fi
fi

# Kiro CLI 의 기본 v2 엔진은 저장소 훅(.kiro/hooks)을 읽지 않는다 — v3 에서만 돈다. 동료 대부분이
# v3 를 받아 놓고 --v3 없이 v2 로 쓰고 있었다(chat.agentEngine 이 비어 있다). --check 는 알리기만 하고,
# 그 밖에는 **비어 있을 때만** `kiro-cli settings chat.agentEngine v3` 로 바꾸고 되돌리는 명령을 알린다.
# 판단은 scripts/kiro_engine.py 한 곳에 있다(fetch-ticket 도 같은 것을 부른다).
if command -v kiro-cli >/dev/null 2>&1; then
  if [ "$CHECK_ONLY" -eq 0 ]; then
    kiro_changed=$(python3 "$ROOT/scripts/kiro_engine.py" --ensure-v3 2>/dev/null)
    [ -n "$kiro_changed" ] && ok "$kiro_changed"
  fi
  if kiro_state=$(python3 "$ROOT/scripts/kiro_engine.py" --status 2>/dev/null); then
    ok "$kiro_state"
  else
    skip "$kiro_state"
  fi
fi

# Kiro(IDE·CLI v3)의 권한 규칙은 저장소에 둘 수 없고 각자 PC 의 ~/.kiro 에만 있다. 명령을 따로 돌리라고 하면
# 아무도 안 돌려서 여기서 바로 넣는다 — 있던 규칙은 두고 백업하며 되돌리는 명령을 알린다. --check 는 알리기만 한다 (0030).
if [ -d "$HOME/.kiro" ]; then
  kiro_rules_arg=""
  [ "$CHECK_ONLY" -eq 0 ] && kiro_rules_arg="--install"
  if kiro_rules=$(python3 "$ROOT/scripts/kiro_permissions.py" $kiro_rules_arg 2>/dev/null); then
    ok "$kiro_rules"
  else
    skip "$kiro_rules"
  fi
fi

# ── 5. customer-skill ────────────────────────────────────────────────────────
# 스킬은 이 저장소의 skills/aws-customer-account-ops 에 있다 (0040). 옛 설치기 대신 scripts/skill_setup.py 가
# credential-broker.conf·csg-login 마커를 맞추고, 빌링 플랫폼 키가 없으면 터미널에서 한 번 묻는다(입력은 안 보인다).
# --check 는 아무것도 바꾸지 않는다.
step 5/9 "고객 AWS 조회 스킬"
skill_setup_arg=""
[ "$CHECK_ONLY" -eq 0 ] && skill_setup_arg="--install"
if skill_state=$(python3 "$ROOT/scripts/skill_setup.py" $skill_setup_arg); then
  ok "$skill_state"
else
  limited "$F_CUSTOMER" "${skill_state:-scripts/skill_setup.py 를 돌리지 못했다 (1단계 python3 확인)}"
fi

# ── 3. zendesk-credentials ───────────────────────────────────────────────────
step 6/9 "Zendesk 자격증명"
conf_has() { [ -f "$ZENDESK_CONF" ] && grep -qE "^$1=" "$ZENDESK_CONF" 2>/dev/null; }

if conf_has ZENDESK_SUBDOMAIN && conf_has ZENDESK_EMAIL && conf_has ZENDESK_API_TOKEN; then
  ok "설정됨: ~/.config/msp/zendesk.conf (값은 출력하지 않는다)"
elif [ "$CHECK_ONLY" -eq 1 ]; then
  limited "$F_TICKET" "Zendesk 미설정 — 해결: bash scripts/onboarding.sh (본문을 붙여 넣는 건 지금도 된다)"
elif [ ! -t 0 ]; then
  # 토큰을 파이프나 인자로 받으면 히스토리·로그에 남는다.
  limited "$F_TICKET" "터미널에서 직접 실행해야 자격증명을 입력받을 수 있다"
else
  echo
  echo "  Zendesk 토큰을 등록한다. 티켓을 번호로 가져오려면 필요하다."
  echo "  토큰 발급: Zendesk 관리센터 → 앱 및 통합 → API → Zendesk API → 토큰 추가"
  echo

  # 빈 입력은 건너뛰기가 아니다. 건너뛰려면 skip 을 직접 입력해야 한다 —
  # 필수 단계에 쉬운 탈출구를 두면 대부분 그걸 누르고, 나중에 안 된다고 되돌아온다.
  ask_required() {  # ask_required <라벨> <힌트>; 값은 stdout, skip 이면 빈 값 + 리턴 1
    local label="$1" hint="$2" value="" attempt=0
    while [ "$attempt" -lt 3 ]; do
      attempt=$((attempt + 1))
      printf "  %s%s: " "$label" "$hint" >&2
      read -r value
      [ "$value" = "skip" ] && return 1
      [ -n "$value" ] && { printf '%s' "$value"; return 0; }
      printf "    값이 필요하다. 지금 등록할 수 없으면 skip 을 입력한다.\n" >&2
    done
    return 1
  }

  if ! zd_sub=$(ask_required "Zendesk 서브도메인" " (예: msp)"); then
    skip "토큰 등록을 건너뛰었다. 티켓 조회는 아직 안 된다."
    skip "나중에 다시 실행: bash scripts/onboarding.sh"
  else
    # 'Zendesk 로그인 이메일'로 적는다. 이 저장소에서 '에이전트'는 AI 도구를 뜻하므로
    # Zendesk 쪽 agent(상담원)와 겹쳐 읽는 사람이 자기 이메일인지 헷갈린다.
    if ! zd_email=$(ask_required "Zendesk 로그인 이메일" " (본인 계정)"); then
      skip "토큰 등록을 건너뛰었다. 나중에 다시 실행: bash scripts/onboarding.sh"
    else
      printf "  API 토큰 (화면에 안 보인다): "
      read -rs zd_token; echo

      if [ -z "$zd_token" ]; then
        limited "$F_TICKET" "토큰이 비었다. 저장하지 않았다. 다시 실행: bash scripts/onboarding.sh"
      else
        case "$zd_sub" in
          *.zendesk.com) zd_host="$zd_sub" ;;
          *)             zd_host="${zd_sub}.zendesk.com" ;;
        esac
        printf "  확인 중: https://%s ...\n" "$zd_host"
        resp=$(curl -sS -m 20 -w $'\n%{http_code}' \
          -u "${zd_email}/token:${zd_token}" \
          "https://${zd_host}/api/v2/users/me.json" 2>/dev/null)
        code="${resp##*$'\n'}"; body="${resp%$'\n'*}"

        if [ "$code" = "200" ]; then
          who=$(printf '%s' "$body" | jq -r '.user | "\(.name) (\(.role))"' 2>/dev/null || echo "?")
          mkdir -p "$CONF_DIR" && chmod 700 "$CONF_DIR" 2>/dev/null
          old_umask=$(umask); umask 077
          cat > "$ZENDESK_CONF" << EOF
# tiket Zendesk credentials. 이 파일 내용을 채팅·이슈·PR 에 붙여넣지 않는다.
# 다시 설정하려면: bash scripts/onboarding.sh
ZENDESK_SUBDOMAIN=${zd_sub}
ZENDESK_EMAIL=${zd_email}
ZENDESK_API_TOKEN=${zd_token}
EOF
          umask "$old_umask"; chmod 600 "$ZENDESK_CONF"
          ok "인증 성공 ($who) — ~/.config/msp/zendesk.conf 에 저장 (권한 600)"
        elif [ "$code" = "401" ] || [ "$code" = "403" ]; then
          limited "$F_TICKET" "인증 거부 (HTTP $code). 이메일 또는 토큰이 맞지 않는다. 저장하지 않았다."
        else
          limited "$F_TICKET" "Zendesk 응답 HTTP ${code:-없음}. 서브도메인과 네트워크를 확인한다. 저장하지 않았다."
        fi
      fi
    fi
  fi
fi

# ── 7. itsm-token ────────────────────────────────────────────────────────
# 고객 특이사항(scripts/customer_notes.py)을 읽는 ITSM 개인 토큰. 각자 ITSM 화면에서 발급한다 (0034 개정 1).
# scripts/itsm_token.py 가 터미널에서 묻고(입력은 안 보인다) GET 한 번으로 확인한 뒤
# ~/.config/msp/itsm 의 ITSM_API_TOKEN 한 줄만 바꾼다 — 다른 키는 그대로. --check 는 아무것도 바꾸지 않는다.
step 7/9 "ITSM 토큰"
itsm_arg=""
[ "$CHECK_ONLY" -eq 0 ] && itsm_arg="--install"
if itsm_state=$(python3 "$ROOT/scripts/itsm_token.py" $itsm_arg); then
  ok "$itsm_state"
else
  limited "$F_NOTES" "${itsm_state:-scripts/itsm_token.py 를 돌리지 못했다 (1단계 python3 확인)}"
fi

# ── 8. usage-telemetry ───────────────────────────────────────────────────────
step 8/9 "사용 지표"
usage_has() { [ -f "$USAGE_CONF" ] && grep -qE "^$1=" "$USAGE_CONF" 2>/dev/null; }

# 6단계에서 이미 본인 Zendesk 자격증명을 넣었다. 거기 적힌 상담사 이름이
# git user.name 보다 사람 이름에 가깝다. 안 되면 조용히 빈 값을 돌려준다 —
# 지표 이름 때문에 온보딩이 멈추면 안 된다.
zendesk_agent_name() {
  [ -f "$ZENDESK_CONF" ] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local sub email token host name
  sub=$(grep -E '^ZENDESK_SUBDOMAIN=' "$ZENDESK_CONF" 2>/dev/null | head -1 | cut -d= -f2-)
  email=$(grep -E '^ZENDESK_EMAIL=' "$ZENDESK_CONF" 2>/dev/null | head -1 | cut -d= -f2-)
  token=$(grep -E '^ZENDESK_API_TOKEN=' "$ZENDESK_CONF" 2>/dev/null | head -1 | cut -d= -f2-)
  [ -n "$sub" ] && [ -n "$email" ] && [ -n "$token" ] || return 0
  case "$sub" in
    *.zendesk.com) host="$sub" ;;
    *)             host="${sub}.zendesk.com" ;;
  esac
  name=$(curl -sS -m 10 -u "${email}/token:${token}" \
    "https://${host}/api/v2/users/me.json" 2>/dev/null \
    | jq -r '.user.name // empty' 2>/dev/null) || return 0
  # 이름이 이메일 형태인 계정이 있다. 그대로 쓰면 수집기가 422 로 거절한다.
  case "$name" in
    *@*.*) return 0 ;;
  esac
  printf '%s' "$name"
}

usage_value() { [ -f "$USAGE_CONF" ] && grep -E "^$1=" "$USAGE_CONF" 2>/dev/null | head -1 | cut -d= -f2-; }

# 기본 켜짐이다 (2026-09-29). 고지는 --check 에서도, AI 가 돌려도 **항상** 나온다 —
# 예전에는 이름을 적어야 켜졌고, AI 온보딩·pull 만 한 동료가 조용히 빠졌다.
usage_notice() {
  echo
  echo "  이 저장소는 기본으로 두 가지를 사내 계정으로 보낸다 (세션 시작 때, 6시간에 한 번)."
  echo "  1) 사용 지표 — 숫자와 고정 문자열뿐이다. 티켓 번호·고객·계정·이메일은 들어가지 않는다."
  echo "     하루 한 번 내 Zendesk 계정으로 내가 해결한 티켓의 처리 시간을 읽어 주별 중앙값·건수만 싣는다."
  echo "  2) 교훈 후보 — 티켓 기록의 '교훈 후보' 칸이 채워졌을 때만. 티켓 번호·고객 corpId·"
  echo "     교훈 한 줄·질문과 확인 내용 발췌가 간다. 90일 뒤 지워지고, 승인된 것만 팀 자산이 된다."
  echo "  무엇이 나가는지 언제든 확인:  python3 scripts/report_usage.py · python3 scripts/report_lessons.py"
  echo "  끄기: ~/.config/msp/tiket-usage.conf 에 TIKET_TELEMETRY=off (둘 다) 또는 TIKET_LESSONS=off (교훈 후보만)"
  echo
}

usage_notice
if [ "$(usage_value TIKET_TELEMETRY)" = "off" ]; then
  skip "꺼짐 — 본인이 conf 에 TIKET_TELEMETRY=off 를 넣었다"
elif usage_has TIKET_ENGINEER; then
  ok "켜짐 — 이름: $(usage_value TIKET_ENGINEER). 끄기: conf 에 TIKET_TELEMETRY=off"
else
  git_name=$(git config user.name 2>/dev/null || true)
  if [ "$CHECK_ONLY" -eq 1 ] || [ ! -t 0 ]; then
    ok "켜짐 — 이름은 git user.name(${git_name:-unknown}). 이름을 정하려면 터미널에서 bash scripts/onboarding.sh"
  else
    # Zendesk 상담사 이름 → git user.name → 미설정
    default_name=$(zendesk_agent_name)
    [ -n "$default_name" ] || default_name="$git_name"
    printf '  지표에 표시될 이름 [%s]: ' "${default_name:-미설정}"
    read -r engineer_name || engineer_name=""
    engineer_name="${engineer_name:-$default_name}"

    if [ -z "$engineer_name" ]; then
      limited "$F_METRICS" "이름이 비었다 — git config user.name 도 없다. 지표가 unknown 으로 섞인다"
    else
      # 엔드포인트도 API 키도 묻지 않는다. 엔드포인트는 팀에 하나뿐이라
      # report_usage.py 가 기본값으로 알고, 키는 두지 않는다 (0021).
      mkdir -p "$CONF_DIR"
      umask 077
      printf 'TIKET_ENGINEER=%s\n' "$engineer_name" > "$USAGE_CONF"
      chmod 600 "$USAGE_CONF"
      ok "켜짐 — 이름 저장: ~/.config/msp/tiket-usage.conf"
    fi
  fi
fi

# ── 4. workspace-validation ──────────────────────────────────────────────────
step 9/9 "저장소 검증"
if command -v python3 >/dev/null 2>&1; then
  if out=$(cd "$ROOT" && python3 scripts/validate_workspace.py 2>&1); then
    ok "$(printf '%s' "$out" | head -1)"
  else
    limited "$F_VALIDATE" "$(printf '%s' "$out" | head -3) — 이 줄을 유지보수자에게 전달한다"
  fi
else
  skip "python3 이 없어 검증을 건너뛰었다 (1단계 막힘)"
fi

# ── 결과 ─────────────────────────────────────────────────────────────────────
finish
