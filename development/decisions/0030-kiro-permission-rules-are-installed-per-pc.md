# 0030. Kiro 권한 규칙은 각자 PC 에 명령 한 번으로 넣는다

- **언제**: 2026-10-01
- **정한 것**: `scripts/kiro_permissions.py --install` 이 `~/.kiro/workspace-roots/<hash>/permissions.yaml` 에 규칙을 넣는다.
  허용하는 것은 프레임워크가 에이전트에게 시키는 일뿐이다 — `fetch-ticket.sh`, 스크립트 4개(`check_ticket_record`·
  `validate_workspace`·`verify_mcp_servers`·`local_capabilities`), `tickets/**`·`customers/**` 쓰기. 온보딩은 상태만 알린다
  (→ 같은 날 개정: 온보딩이 바로 넣는다. 맨 아래).
- **왜**: Kiro IDE·CLI 를 쓰는 동료들이 승인 창을 매번 눌러야 해서 힘들어했다. Claude Code 는 `.claude/settings.json` 이
  clone 으로 따라오지만 Kiro 는 권한 규칙을 저장소에 둘 수 없다 — "A cloned repo cannot inject permission rules - trust is
  something you configure on your own machine" (kiro.dev/docs/permissions, 2026-10-01 조회). 기본값은 작업 폴더 읽기와
  읽기 전용 git 만 허용하고 나머지는 전부 묻는다.
- **버린 선택지**:
  - `.kiro/agents/*.json` 의 `permissions` 칸 — 저장소에 커밋되지만 매번 `--agent` 로 그 에이전트를 골라야 적용된다.
    기본 에이전트로 여는 사람에게는 닿지 않는다.
  - 전역 `~/.kiro/settings/permissions.yaml` — 해시를 몰라도 되지만 다른 프로젝트에서도 `tickets/**` 쓰기가 허용된다.
  - `python3 scripts/*` 처럼 폴더째 허용 — `python3 scripts/../tickets/x.py` 도 통과한다. `tickets/` 쓰기가 허용이라
    아무 코드나 묻지 않고 돌게 된다. 스크립트 이름까지 적는다.
  - `aws *` 허용 — 고객 계정 호출 전 잠금 확인(`agents/customer-access-locks.md`)을 사람이 볼 마지막 자리다. 브로커가 아닌
    본인 프로필의 쓰기 호출도 같은 패턴에 걸린다. 넣을지는 유지보수자가 정한다.
  - `cat`·`head`·`grep` 같은 일반 명령 허용 — 작업 폴더 밖 읽기는 기본값이 묻는데, 이 패턴은 그 확인을 없앤다.
    티켓 본문은 믿을 수 없는 입력이고 Exa 검색은 자동 승인이라, `~/.config/msp/*.conf` 를 조용히 읽으면 밖으로 나갈 길이 생긴다.
  - 온보딩이 자동으로 넣기 — 신뢰 경계를 낮추는 일은 본인이 명령을 돌려서 한다. Kiro 가 저장소 주입을 막은 뜻과 같다.
- **근거**: `scripts/kiro_permissions.py`, `scripts/test_kiro_permissions.py`.
  폴더 이름이 `sha256(NFC 경로)` 앞 16자라는 것은 유지보수자 PC(macOS, kiro-cli 2.26.1)에서 Kiro 가 만든 폴더 2개로 확인했다.
  **모르는 것**: Windows 의 해시 규칙(그래서 추측하지 않는다), 이 규칙 파일을 Kiro 가 실제로 받아들이는지(한 번도 Kiro 로
  돌려 보지 않았다), `permissions.yaml` 이전 방식인 IDE 0.x 의 동작, 동료들이 실제로 무엇에서 가장 많이 묻히는지.

## 2026-10-01 개정 — 온보딩이 바로 넣는다

- **바꾼 것**: 온보딩이 `~/.kiro` 가 있으면 `--install` 을 부른다. `--check`(`-Check`) 는 지금처럼 알리기만 한다.
  위 "버린 선택지" 의 마지막 줄(온보딩이 자동으로 넣기)을 뒤집었다.
- **왜**: 유지보수자 판단 — 명령을 따로 돌리라고 하면 동료들이 안 돌린다. 그러면 만든 것이 닿지 않는다.
  넣는 범위가 프레임워크 스크립트와 기록 폴더뿐이고, 있던 규칙을 백업하고 되돌리는 명령을 알리므로 받아들일 만하다.
  `kiro_engine.py --ensure-v3` 가 이미 같은 방식이다(바꾸고, 알리고, 되돌리는 명령을 준다).
- **남은 것**: 온보딩을 이미 끝낸 동료에게는 닿지 않는다 — 다시 돌리거나 명령을 직접 돌려야 한다 (→ 개정 2).
  **범위를 넓히면(`aws *`, `cat`·`grep` 류) 이 개정을 다시 본다** — 묻지 않고 넣어도 되는 것은 범위가 좁아서다.

## 2026-10-01 개정 2 — 세션 시작은 알리기만 한다

- **정한 것**: `~/.kiro` 가 있는데 규칙이 없으면 세션 시작 알림(`local_capabilities.py --if-missing`)이
  "Kiro 승인 창 줄이기(권한 규칙 미설치)" 를 말하고 온보딩을 가리킨다. 세션 시작은 규칙을 **쓰지 않는다.**
- **왜**: 세션 훅은 저장소가 싣고 온 명령을 호스트가 돌리는 것이다. 거기서 권한 파일을 쓰면 Kiro 가 막아 둔
  "clone 한 저장소가 권한을 주입한다" 가 그대로 된다. 온보딩은 본인이 직접 돌리는 것이라 다르다.
  다른 PC 쪽 설정(엔진, Hermes 훅)은 세션 시작이 맞추는 쪽으로 간다 — 백로그 "세션 시작이 PC 쪽 상태를 맞추게 한다".
- **버린 선택지**: 넣을 폴더를 모르는 PC(Windows, Kiro 가 폴더를 아직 안 만든 경우)에도 알리기 — 온보딩으로도 못 고치는 것을
  매 세션 말하게 된다. 그런 PC 는 조용히 둔다.
- **근거**: `scripts/local_capabilities.py` `kiro_rules_missing`, `scripts/test_local_capabilities.py` 의 Kiro 묶음.

## 2026-10-01 확인 — Kiro 가 규칙 파일을 받아들인다

온보딩이 넣은 규칙으로 유지보수자 PC(macOS)의 Kiro 가 묻지 않고 돌았다(유지보수자 확인). 위 "모르는 것" 중
"Kiro 가 실제로 받아들이는지" 는 풀렸다. 폴더 해시 규칙(`sha256` 앞 16자)도 세 번째 사례로 맞았다.
허용하지 않은 명령이 여전히 묻히는지, Windows, 동료 PC 는 아직 모른다.

## 2026-10-01 개정 3 — `aws` 읽기와 읽기 명령도 넣는다

- **바꾼 것**: `aws` 읽기 호출(`describe-`·`list-`·`get-`·`s3 ls` …)과 `cat`·`head`·`tail`·`grep`·`rg`·`ls`·`wc`·`sort`·`uniq`·`jq`·`find`
  를 허용에 넣었다. 위 "버린 선택지" 의 `aws *` 와 일반 명령 두 줄을 뒤집었다.
- **왜**: 유지보수자 결정 — 동료들이 가장 많이 눌러 온 것이 이 둘이다. 빼면 "여전히 묻는다" 가 되고, 릴리스한 뜻이 없다.
- **그 대신 `exclude` 로 도로 묻게 한 것** (걸리면 허용에서 빠질 뿐, 막는 것은 아니다):
  - `aws` 쓰기 동사(`create-`·`delete-`·`put-`·`terminate-` … 43개)와 `s3 rm`·`cp`·`mv`·`sync`·`rb`·`mb` — `CLAUDE.md` "고객 계정
    쓰기 API 는 부르지 않는다". 브로커가 아닌 본인 프로필에도 같은 규칙이 걸린다.
  - 비밀을 돌려주는 읽기 — `get-secret-value`·`get-parameter`·`get-session-token`·`get-login-password` 등.
  - 자격증명 자리 읽기 — `.aws/`, `msp`, `.ssh/`, `.env`, `.pem`, `.key`, `credential`, `.kiro/settings`.
  - `>` 가 든 명령, `find -delete`·`-exec`, `sort -o` — 읽기 명령으로 허용된 스크립트를 바꿔 치지 못하게.
- **버린 선택지**: `aws *` 통째 허용 — 쓰기 호출까지 묻지 않게 된다. 읽기 동사만 받는다.
- **받아들인 위험**:
  - **고객 계정 잠금을 이 규칙은 보지 못한다.** 잠긴 계정에 대한 `describe-` 도 묻지 않고 돈다. 막는 것은 에이전트 규칙
    (`CLAUDE.md`, `agents/customer-access-locks.md`)뿐이다 — 사람이 승인 창에서 볼 마지막 자리는 없어졌다.
  - glob 은 동사 자리를 못 고정한다. 목록에 없는 쓰기 동사에 ` --query get-x` 를 붙이면 통과한다. 고객 계정은 브로커가
    서버에서 읽기 전용으로 막지만, 본인 프로필은 그렇지 않다.
  - `get-`·`describe-` 중에도 민감한 값을 돌려주는 것이 더 있다(`lambda get-function-configuration` 의 환경변수 등).
  - 자격증명 경로 목록에 없는 자리의 비밀은 `cat` 으로 묻지 않고 읽힌다.
- **근거**: `scripts/test_kiro_permissions.py` `RuleSetTests` — 명령 예시 60여 개를 문서의 매칭 규칙대로 본다.
  **모르는 것**: Kiro 의 실제 매칭이 그 모델과 같은지(대소문자, `exclude` 가 합쳐진 명령의 조각마다 걸리는지) — Kiro 로 확인한다.
