# 0020. 주기 갱신을 세 호스트로 넓히고, 훅이 꺼진 사람을 위해 2층을 둔다

- **언제**: 2026-09-20
- **정한 것**: [[0016-freshness-check-notifies-instead-of-pulling]] 이 Claude Code 하나만
  덮던 것을 **Codex·Kiro 까지** 넓힌다. 그리고 훅이 신뢰 설정에 막히는 경우를 위해
  `fetch-ticket.sh` 에서도 한 번 확인하는 **2층**을 둔다.

- **왜 이 논의가 나왔나**: Kiro·Codex 를 쓰는 사람도 저장소 최신본을 주기적으로 받게 하고
  싶다는 요청. 0016 이 "현재 자동 실행되는 에이전트는 Claude Code 하나" 라고 한계로 적어둔
  바로 그 항목이다.

- **확인한 사실** (2026-09-20 공식 문서 조회):

  | 호스트 | 이벤트 | 설정 위치 | 저장소 안 |
  |---|---|---|---|
  | Claude Code | `SessionStart` | `.claude/settings.json` | 예 |
  | Codex | `SessionStart` 외 11종 | `<repo>/.codex/config.toml` 또는 `hooks.json` | 예 |
  | Kiro | `SessionStart`(IDE) · `AgentSpawn`(CLI) · `PromptSubmit` | `<repo>/.kiro/hooks/*.json` | 예 |
  | Hermes | 있음 | 프로필이 저장소 밖 | **아니오** |

  - `agents/shared-agent-environment.md` 는 "Codex and Kiro expose comparable lifecycle
    events" 라고 적어두었으나 구체 이벤트를 확인한 적은 없었다. 이번에 확인했다.
  - **Kiro 는 `SessionStart` 가 IDE 전용, `AgentSpawn` 이 CLI 전용이다.** 하나만 걸면 반만
    덮는다. 둘 다 등록한다.
  - Codex TOML 은 `[[hooks.SessionStart]]` + `[[hooks.SessionStart.hooks]]` 중첩 배열이다.
    `tomllib` 로 파싱해 문서 예시와 같은 구조가 나오는 것을 확인했다.

- **왜 2층인가**: Codex 문서가 명시한다 — *"Project-local hooks load only when the project
  `.codex/` layer is **trusted**."* 우리 `shared-agent-environment.md` 도 같은 원칙을 이미
  적어두었다("clone 한 저장소가 스스로 실행 권한을 부여해서는 안 된다"). 즉 **갓 clone 한
  신규 엔지니어에게는 훅이 꺼져 있다** — 주기 갱신이 가장 필요한 사람에게 가장 늦게 켜진다.
  `fetch-ticket.sh` 는 호스트·신뢰 설정과 무관하게 반드시 지나가는 지점이라 거기에도 둔다.

  **2층은 보조지 대체가 아니다.** EVAL-004 가 보였듯 티켓 번호 없이 오는 건에는
  `fetch-ticket.sh` 를 쓰지 않는다. 그 경우는 1층만 덮는다.

- **같이 고친 버그**: 호출 지점이 여럿이 되면서 스탬프 설계에 구멍이 생겼다. 기존 스크립트는
  fetch **앞에** 스탬프를 찍었다. 한 호출 지점이 알림을 사용자에게 보여주지 못하면
  (Kiro 의 `command` 액션이 stdout 을 어떻게 다루는지는 문서에 없다) **스탬프만 소모되고
  그날의 알림이 통째로 사라진다.**

  그래서 **최신이거나 확인 불가일 때만** 스탬프를 찍는다. 뒤처진 동안은 찍지 않으므로
  pull 할 때까지 모든 지점에서 알린다. 오프라인에서 매 세션 느린 fetch 를 반복하지 않는
  원래 목적은 유지된다 — fetch 실패에도 스탬프를 찍기 때문이다.

- **구조**: 선언은 `render_agent_configs.py` 한 곳이고 호스트 파일은 얇은 어댑터다.
  `agents/shared-agent-environment.md` 의 "Hook portability" 가 정한 그대로다 —
  업무 정책을 네 개의 훅 설정에 따로 적지 않는다. 판단 로직은 전부
  `scripts/check-freshness.sh` 안에 있다.

- **고정 방법**: `test_onboarding_parity.py::FreshnessHostCoverageTests` 4개.
  세 호스트가 같은 스크립트를 부르는지, Kiro 가 IDE·CLI 트리거를 둘 다 거는지,
  `fetch-ticket` 이 훅 없이도 확인하는지, 뒤처진 상태에서 스탬프를 소모하지 않는지.

- **아직 안 한 것**:
  - **실제 Kiro·Codex 세션에서 훅이 발동하는지 확인하지 않았다.** 스키마는 문서 예시와
    대조했고 TOML 은 파싱까지 확인했으나, 발동은 **가설**이다. 각 호스트로 새 세션을 열어
    뒤처진 상태를 만들어 보면 확정된다.
  - Kiro 의 `command` 액션 stdout 이 사용자에게 보이는지 문서에 없다. 안 보이면 1층은
    Kiro 에서 "조용히 fetch 만" 하는 셈이 되고, 알림은 2층이 맡는다. 위 스탬프 수정이
    그 경우를 이미 방어한다.
  - Hermes 는 여전히 수동이다.

- **2026-09-29 덧붙임 — 세션 시작 훅은 한 명령이다.** 업데이트와 사용 지표를 훅 둘로 두었더니 순서가
  보장되지 않았다. Claude Code 는 "All matching hooks run in parallel"(code.claude.com/docs/en/hooks),
  Codex 는 "launched concurrently"(learn.chatgpt.com/docs/hooks). 전송이 먼저 끝나면 그날 행이 옛
  버전으로 찍힌다. 이제 `bash scripts/check-freshness.sh; python3 scripts/report_usage.py --if-due` 한 명령이다
  — `;` 라서 앞이 실패해도 뒤는 돈다. Kiro 도 `.kiro/hooks/session-start.json` 하나로 합쳤다.
  렌더러 `render_agent_configs.py` 의 `SESSION_HOOK_COMMAND`.

- **2026-09-29 덧붙임 — Hermes·Windows·신뢰 전 Codex 도 잡는다.** Kiro 가 가장 많고 Windows 3명, Hermes 2명이다.
  - Hermes: 저장소 훅을 읽지 않고, 파일만 넣는 `~/.hermes/hooks/` 는 게이트웨이 전용이다. CLI 에서 도는 것은
    `config.yaml` 의 shell hook 이다(Hermes 문서 "Shell Hooks", v0.20.5 `agent/shell_hooks.py` 로 확인). 온보딩이
    `scripts/hermes_hook.py` 를 `on_session_start` 로 등록한다 — 백업 먼저, 기존 `hooks:` 가 있으면 합치지 않고
    손으로 넣을 내용을 알린다(YAML 파서 없이 안전한 경우만). 첫 발동 때 Hermes 가 한 번 승인을 묻는다. 훅은
    `cwd` 가 이 저장소 안일 때만 일한다. "Hermes 는 여전히 수동이다" 는 이것으로 닫는다.
  - Windows: `bash …; python3 …` 가 도는지 모른다. Codex 는 `command_windows` 로 `scripts/session-start.ps1` 을
    부른다. Kiro 에는 Windows 전용 칸이 문서에 없다.
  - 안전망: `fetch-ticket` 이 `report_usage.py --if-due` 도 부른다. 도구·신뢰·OS 와 무관하게 티켓을 가져오는
    사람은 잡힌다. 6시간 스로틀이 있어 훅과 겹쳐도 두 번 보내지 않는다.

- **2026-09-29 덧붙임 — Kiro 검토.** 사용자가 가장 많은 곳이라 설치된 Kiro IDE 1.1.14·CLI 2.25.0 을 직접 봤다.
  - Kiro CLI 기본 v2 엔진은 `.kiro/hooks` 를 읽지 않는다(바이너리에 경로 없음, 문서 "CLI 3.0", v3 는 `--v3`/
    `chat.agentEngine`). 유지보수자 확인: v3 는 돈다. 전역 설정이라 온보딩이 엔진을 알리고 명령을 준다 — 바꾸지 않는다.
  - Kiro IDE 는 명령을 Node `spawn(shell: true)` 로 돌린다 — Windows 는 cmd.exe 라 `;` 가 깨진다. Kiro 훅만
    `python3 scripts/session_start.py || python scripts/session_start.py` 로 바꿨다. 순서는 스크립트 안에서 지킨다.
  - IDE 는 신뢰하지 않은 폴더에서 훅을 끈다(`executionSuppressedUntrusted`). 문서로 안내한다.
  - 한 파일의 `AgentSpawn` 항목은 IDE 가 그 항목만 건너뛴다(`nxo`). `SessionStart` 를 막지 않는다.
  - Kiro 는 명령 전체를 제한 시간에 끊는다 — 훅 `timeout: 120`, `git fetch` 에 저속 연결 끊기.
  - 훅 모드 `report_usage` 가 전송 실패를 stderr 로 냈다. Kiro IDE 는 stdout 이 비면 stderr 를 맥락에 넣는다 — 막았다.
  - 같은 날 고침: "알리기만" 으로는 부족했다 — 동료 대부분이 v3 를 받아 놓고 `--v3` 없이 v2 로 쓰고 있었다(값이 비어 있다).
    `scripts/kiro_engine.py` 가 **비어 있을 때만** v3 로 바꾸고 되돌리는 명령을 알린다(유지보수자 결정). v2 사용자에게
    닿는 길은 `fetch-ticket` 뿐이라 거기서도 부른다. 일부러 정한 값은 덮지 않는다. 읽은 값이 `v3 (global)` 로
    나와서 `v0.1.6` 온보딩이 v3 사용자를 v2 로 알리던 버그도 여기서 고쳤다(kiro-cli 2.25.0 에서 확인).

- **2026-09-29 덧붙임 — Claude Code·Codex 검토.**
  - **Codex 는 훅을 내용 해시로 승인받는다.** 정규화한 훅(이벤트·matcher·command·timeout·statusMessage)의 해시를
    `~/.codex/config.toml [hooks.state] trusted_hash` 와 비교하고, 다르면 `Modified` 로 돌리지 않는다. 시작할 때
    "Hooks need review" 를 띄우고 건너뛰면 꺼진다(openai/codex `hooks/src/engine/discovery.rs`, codex-cli 0.158.0).
    해시를 소스대로 재현해 유지보수자 개인 훅의 기록값과 일치하는 것을 확인한 뒤 계산했다 — 유지보수자 장비의 tiket 훅
    승인은 09-21 판(업데이트 훅만)이고, `v0.1.4` 에서 명령을 합친 뒤로 꺼져 있었다. 지표 훅은 승인된 적이 없다.
  - 그래서 **Codex 명령을 고정했다** — `v0.1.4` 명령(`bash scripts/check-freshness.sh; python3 …`)을 그대로 둬서
    그때 Trust 한 사람을 다시 묻지 않는다. 해시는 `test_onboarding_parity.py` 의 `PINNED_CODEX_HOOK_HASH`
    (macOS·Linux)와 `PINNED_CODEX_WINDOWS_HOOK_HASH`(Windows 는 `command_windows` 가 해시된다)가 붙잡는다 —
    바꾸면 Codex 사용자 전원이 다시 승인해야 한다. 앞으로 바꿀 것은 스크립트 안에서 바꾼다.
  - 포기한 것: Codex 를 하위 폴더에서 열면 상대 경로가 깨진다(문서가 하위 폴더 시작을 명시). 재승인보다 싸다.
  - Claude Code 는 해시 승인이 없어 `python3 "$(git rev-parse --show-toplevel)/scripts/session_start.py" || python …`
    로 바꿨다 — git 루트 기준, Windows Git Bash 에 `python3` 가 없으면 `python`.
  - **origin 검사가 업데이트를 막고 있었다.** 주소 전체를 비교해서 SSH 별칭·사용자명이 붙은 https·`ssh://` 로
    clone 한 사람은 매번 "공용 저장소가 아니다" 만 받고 영영 안 올라갔다(유지보수자 장비가 그랬다). 이제 "소유자/저장소"
    만 비교한다. 확인 간격도 24시간 → 6시간.
