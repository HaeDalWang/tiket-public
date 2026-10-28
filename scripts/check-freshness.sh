#!/usr/bin/env bash
#
# check-freshness.sh — 새 정식 버전(vX.Y.Z 태그)이 나왔으면 워크스페이스를 올린다.
#
# 올리는 건 **태그뿐**이다. 태그 없는 main 은 아직 릴리스가 아니다. 그리고 안전할 때만
# 올린다 — main 브랜치이고, 고친 추적 파일이 없고, fast-forward 로 갈 수 있을 때.
# 하나라도 아니면 올리지 않고 이유와 명령을 알린다. 사람이 고친 것을 덮지 않는다.
# 알리기만 하던 0016 을 뒤집은 이유는 development/decisions/0025 참조.
#
# 사용:
#   bash scripts/check-freshness.sh                 6시간에 1회. 세션 시작 훅이 부른다
#   bash scripts/check-freshness.sh --force         스로틀 무시
#   bash scripts/check-freshness.sh --notify-only   올리지 않고 알리기만. 세션 도중에 부르는
#                                                   fetch-ticket 이 쓴다 — 세션 도중 계약을
#                                                   바꾸지 않는다 (0016)
#
# 어떤 실패도 세션을 막지 않는다. 확인이 안 되면 조용히 끝낸다.

set -uo pipefail

# TIKET_* 재정의는 테스트용이다 (test_check_freshness.py).
EXPECTED_REMOTE="${TIKET_EXPECTED_REMOTE:-https://github.com/example-org/tiket.git}"
STAMP="${TIKET_FRESHNESS_STAMP:-$HOME/.config/msp/tiket-freshness}"
# 6시간. 사용 지표와 같다 — 새 릴리스가 하루 늦게 닿지 않게 (2026-09-29).
INTERVAL_SECONDS=21600
UPDATE_BRANCH=main
# 세션이 시작될 때 이미 읽혔을 수 있는 진입 규칙. 바뀌면 다시 읽으라고 알린다.
ENTRY_FILES="CLAUDE.md AGENTS.md .kiro/steering"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || exit 0
cd "$ROOT" 2>/dev/null || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

FORCE=0
NOTIFY_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --notify-only) NOTIFY_ONLY=1 ;;
  esac
done

# 이 PC 에서 아직 안 되는 기능(Zendesk·고객 조회 스킬)을 매 세션 알린다 — 스로틀보다 먼저다.
# 모든 호스트의 세션 시작이 이 스크립트를 지나서 여기 둔다(Codex 명령은 승인 해시 때문에 고정).
# 세션 도중 부르는 fetch-ticket(--notify-only)에서는 되풀이하지 않는다. 판단은 local_capabilities.py.
# `python3` 를 이름으로 부르면 `python` 만 있는 PC 는 아래에서 태그를 못 읽고 영영 안 올라간다 (2026-10-07).
PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || printf 'python3')
[ "$NOTIFY_ONLY" -eq 1 ] || "$PYTHON" "$ROOT/scripts/local_capabilities.py" --if-missing 2>/dev/null || true

# "소유자/저장소" 만 비교한다. SSH 별칭(git@별칭:example-org/tiket), 사용자명이 붙은 https, ssh://
# 를 모두 같은 저장소로 본다 — 주소 전체를 비교했더니 다르게 clone 한 사람은 영영 안 올라갔다
# (2026-09-29). 옛 저장소는 소유자나 이름이 달라서 여전히 걸린다.
normalize_remote() {
  printf '%s' "$1" | tr '\\' '/' | sed -e 's|/*$||' -e 's|\.git$||' -e 's|:|/|g' \
    | awk -F/ '{ print tolower($(NF-1) "/" $NF) }'
}

# origin 이 옛 주소면 스로틀과 무관하게 매번 알린다.
# 옛 저장소는 살아 있어서 fetch 가 성공하고 "새 버전 없음" 이 나온다 — 최신이라는
# 거짓 초록불이 뜨는 자리다. 그래서 이 검사가 버전 검사보다 먼저 온다.
origin_url=$(git remote get-url origin 2>/dev/null || true)
if [ -n "$origin_url" ] && \
   [ "$(normalize_remote "$origin_url")" != "$(normalize_remote "$EXPECTED_REMOTE")" ]; then
  printf 'origin 이 공용 저장소가 아니다: %s\n' "$origin_url"
  printf '  git remote set-url origin %s\n' "$EXPECTED_REMOTE"
  exit 0
fi

now=$(date +%s 2>/dev/null) || exit 0
if [ "$FORCE" -eq 0 ] && [ -f "$STAMP" ]; then
  last=$(cat "$STAMP" 2>/dev/null || printf '0')
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $((now - last)) -lt "$INTERVAL_SECONDS" ] && exit 0
fi

stamp_now() {
  mkdir -p "$(dirname "$STAMP")" 2>/dev/null || return 0
  printf '%s' "$now" > "$STAMP" 2>/dev/null || return 0
}

# 네트워크 실패에는 스탬프를 찍는다. 오프라인에서 매 세션 느린 fetch 를 반복하지 않기
# 위해서다. 대신 오프라인인 날은 확인을 한 번 건너뛴다.
# 멈춘 연결은 git 이 스스로 끊는다(15초 동안 1KB/s 미만). Kiro 는 훅 명령 전체를 제한 시간에
# 끊어서, 걸린 fetch 가 뒤의 지표 전송까지 죽였다 (2026-09-29).
#
# 한두 번은 오프라인일 수 있어 조용히 넘긴다. 세 번 연속이면 그 PC 는 fetch 가 안 되는 것이다(만료된 토큰,
# 잠긴 SSH 키) — 예전에는 그대로 영영 안 올라갔고 아무도 몰랐다 (2026-10-07). 고치라고는 하지 않는다 (0039).
FETCH_FAILURES="$STAMP-fetch-failures"
FETCH_NOTICE_AFTER=3
fetch_failed() {
  stamp_now
  count=$(cat "$FETCH_FAILURES" 2>/dev/null || printf '0')
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  count=$((count + 1))
  printf '%s' "$count" > "$FETCH_FAILURES" 2>/dev/null || true
  if [ "$count" -ge "$FETCH_NOTICE_AFTER" ]; then
    printf '[tiket] 워크스페이스 새 버전 확인이 %s번 연속 실패했다 — 자동 업데이트가 멈춰 있다. 지금 하는 작업에는 영향이 없다 — 작업을 먼저 끝낸다.\n' "$count"
    printf '답 끝에 사용자에게 한 줄로 알리고, `git fetch --tags origin` 을 직접 돌려 나온 오류를 유지보수자에게 전해 달라고 한다.\n'
    printf '직접 고치려 하지 않는다 — 원격 주소·자격 증명·git 설정을 바꾸지 않는다.\n'
  fi
  exit 0
}
git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=15 fetch --quiet --tags origin >/dev/null 2>&1 || fetch_failed
rm -f "$FETCH_FAILURES" 2>/dev/null || true

latest=$(git for-each-ref --format='%(objectname)%09%(refname)' refs/tags \
  | "$PYTHON" "$ROOT/scripts/release_tags.py" latest 2>/dev/null) || { stamp_now; exit 0; }

# 이미 그 태그를 품고 있으면(같거나 앞서 있으면) 할 일이 없다.
if git merge-base --is-ancestor "$latest" HEAD 2>/dev/null; then
  stamp_now; exit 0
fi

current=$(git describe --tags --abbrev=0 --match 'v[0-9]*' HEAD 2>/dev/null || printf '태그 이전')

# 올리지 못할 때는 스탬프를 찍지 않는다. 호출 지점이 여럿이라(세션 훅, fetch-ticket)
# 한 곳에서 스탬프만 소모되고 알림은 사용자에게 안 보이는 경우가 생긴다 — Kiro 의
# command 액션이 stdout 을 어떻게 다루는지는 문서에 없다. 올라갈 때까지 매번 알린다.
held_back() {
  printf '워크스페이스 새 버전 %s 이 나왔다 (지금 %s). 자동으로 올리지 않았다 — %s\n' "$latest" "$current" "$1"
  [ -n "${2:-}" ] && printf '  %s\n' "$2"
  exit 0
}

if [ "$NOTIFY_ONLY" -eq 1 ]; then
  held_back "세션 도중이라 알리기만 한다" "다음 세션 시작 때 올라간다. 지금 올리려면: bash scripts/check-freshness.sh --force"
fi

branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || printf '브랜치 없음')
[ "$branch" = "$UPDATE_BRANCH" ] \
  || held_back "$UPDATE_BRANCH 가 아니라 $branch 에 있다" "git switch $UPDATE_BRANCH 후 다시 세션을 연다"

modified=$(git diff --name-only HEAD 2>/dev/null | head -5 | tr '\n' ' ' | sed 's/ $//')
[ -z "$modified" ] \
  || held_back "고친 파일이 있다: $modified" "고친 것을 커밋하거나 되돌린 뒤: git merge --ff-only $latest"

git merge-base --is-ancestor HEAD "$latest" 2>/dev/null \
  || held_back "로컬 커밋이 있어 그대로 올릴 수 없다" "git log --oneline $latest..HEAD 로 확인한 뒤: git merge $latest"

# 서명 검증 — merge 하기 전. 서명자 파일이 **지금 HEAD 에** 커밋돼 있으면, 들어오는 태그를
# 그 목록으로 검증한 뒤에만 올린다. 새 태그 안의 파일이나 작업 폴더의 파일을 믿지 않는다 —
# 푸시 권한을 얻은 쪽이 새 태그에서 목록을 바꿔도 통하지 않는다 (2026-10-04 hardening #3).
# HEAD 에 서명자 파일이 없으면(서명 도입 전) 검증 없이 올린다. 실패는 전부 held_back.
if git cat-file -e "HEAD:scripts/release-signers" 2>/dev/null; then
  signers_tmp=$(mktemp 2>/dev/null) || held_back "서명 검증용 임시 파일을 만들지 못했다" "다시 시도한다"
  if ! git show HEAD:scripts/release-signers > "$signers_tmp" 2>/dev/null; then
    rm -f "$signers_tmp"
    held_back "HEAD 의 서명자 목록을 읽지 못했다" "git show HEAD:scripts/release-signers 로 확인한다"
  fi
  verify_out=$(git -c gpg.format=ssh -c gpg.ssh.allowedSignersFile="$signers_tmp" \
    verify-tag "$latest" 2>&1)
  verify_rc=$?
  rm -f "$signers_tmp"
  [ "$verify_rc" -eq 0 ] \
    || held_back "태그 서명을 확인하지 못했다" "$latest 가 등록된 키로 서명되어 있는지 유지보수자에게 확인한다"
fi

before=$(git rev-parse HEAD)
merge_log=$(git merge --ff-only --quiet "$latest" 2>&1) \
  || held_back "git merge 가 실패했다: $(printf '%s' "$merge_log" | head -1)" "git merge --ff-only $latest"

stamp_now
printf '워크스페이스를 %s 로 올렸다 (이전 %s).\n' "$latest" "$current"
git tag -l --format='%(contents)' "$latest" 2>/dev/null \
  | sed -e '1d' -e '/^[[:space:]]*$/d' -e '/-----BEGIN/,$d' | head -8 | sed 's/^/  /'
# shellcheck disable=SC2086
if ! git diff --quiet "$before" HEAD -- $ENTRY_FILES 2>/dev/null; then
  printf '  진입 규칙이 바뀌었다 (%s). 이 세션은 옛 규칙으로 시작했을 수 있다 — 다시 읽는다.\n' \
    "$(git diff --name-only "$before" HEAD -- $ENTRY_FILES | tr '\n' ' ' | sed 's/ $//')"
fi
printf '  되돌리기: git reset --keep %s\n' "$before"
