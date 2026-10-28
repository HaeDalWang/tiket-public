# 0037. Claude Code 전용 티켓 흐름 mod 를 저장소에 넣고 기본으로 켠다. 관찰만 한다

- **언제**: 2026-10-06
- **정한 것** (유지보수자 — "시제품이라고 말만 써 놓고 못 쓰는 거잖아, 그냥 넣자. 어차피 Claude Code 전용"):
  - mod 는 `mods/tiket-flow/` 에 둔다. `mods/` 가 마켓플레이스(`tiket-mods`)다.
  - `.claude/settings.json` 이 그 마켓플레이스를 **상대 경로** `./mods` 로 등록하고 `tiket-flow@tiket-mods` 를 켠다.
    설정은 `scripts/render_agent_configs.py` 가 만든다. 동료는 아무것도 설치하지 않는다 — 폴더를 신뢰한 Claude Code 세션이 그 자리에서 읽는다.
  - mod 는 **관찰만 한다.** 도구 호출을 막지도, 바꾸지도, 승인하지도 않는다. 고객 계정 쓰기를 mod 로 막는 가드는 넣지 않는다 —
    경계가 하네스마다 달라지고, 지금 권한 규칙과 겹친다.
  - mod 가 부를 수 있는 mods API 호출과 듣는 이벤트는 `scripts/test_mod_tiket_flow.py` 의 목록으로 고정한다. 목록을 늘리는 사람은
    그 호출이 왜 필요한지 여기에 덧붙인다.
- **왜**: 동료가 Claude Code 를 쓰고 싶게 만드는 편의 기능이다. 저장소 밖에 두면 README 에 그림만 있고 아무도 못 쓴다.
  티켓을 처리하는 **중에** 어느 단계인지, 근거 딱지가 몇 개인지, 발송 전 점검에서 뭐가 남았는지가 옆 창에 보인다.
- **지금 허용한 호출과 이유**:
  - `fs.read`·`fs.list`·`fs.exists` — 방금 쓴 `tickets/<id>.md`(등급·딱지 개수·초안), 읽은 정책 카드의 `status`, `tickets/` 의 날짜(최근 4주).
  - `process.run` — `scripts/check_ticket_record.py` 하나만. 에이전트가 검사기에 `| tail` 을 붙이면 종료 코드가 가려져서, mod 가 직접 돌려 판정한다.
    `python3` 가 없으면 `python` 으로 한 번 더 시도한다(세션 시작 훅과 같은 순서).
  - `ui.copy` — 답변 초안을 클립보드에. 사람이 버튼이나 `/tiket-copy` 를 눌렀을 때만.
  - `ui.open`·`ui.panes`·`ui.resolve`·`ui.invalidate`·`ui.toast`·`ui.log`, `command.register` — 그리기와 명령 둘(`/tiket`, `/tiket-copy`).
- **확인한 것** (2026-10-06, Claude Code 2.1.290):
  - 상대 경로 설정만 커밋된 복제본과 `~/tiket` 에서, `--plugin-dir` 없이 켠 세션이 mod 의 명령에 답했다(`tiket-flow: 복사할 답변 초안이 없다`).
    등록 명령(`claude plugin marketplace add --scope project`)은 절대 경로를 적는다 — 그 출력을 그대로 커밋하면 다른 위치의 clone 에서 깨진다.
  - `claude plugin test mods/tiket-flow` 21건. 고친 곳마다 변이를 넣어 잡히는 것을 봤다.
  - `test_mod_tiket_flow.py` 는 네트워크 호출 추가, 도구 호출을 막는 반환, 권한 결정 이벤트 추가, 절대 경로를 각각 잡는다.
  - 유지보수자가 실제 티켓 한 건과 연습 기록으로 써 봤다 — 넓은 터미널에서 옆 창이 저절로 열렸다.
- **한계**:
  - **mod 는 샌드박스 밖에서 사용자 권한으로 돈다.** 이 저장소에 푸시할 수 있는 사람은 Claude Code 를 쓰는 동료 PC 에서 그 권한으로 코드를 돌릴 수 있다.
    세션 시작 훅(0016·0025)과 같은 종류의 신뢰이고, 같은 장치로 막는다 — 릴리스 태그 서명(0036)과 CI.
    위 목록 테스트는 실수로 넓어지는 것을 잡는 것이지, 작정한 사람을 막는 것이 아니다.
  - CI 에는 Claude Code 가 없어 `claude plugin test` 가 돌지 않는다. mod 를 고친 사람이 자기 PC 에서 돌린다.
  - Claude Code 전용이다. Kiro·Codex·Hermes 에는 아무것도 달라지지 않는다.
  - **unknown**: 2.1.287 미만의 Claude Code 가 `hooks/hooks.json` 의 `modules` 키를 어떻게 다루는지. 문서는 그 버전부터 mod 가 기본으로 켜진다고만 한다.
  - **unknown**: Windows 에서의 동작. macOS 에서만 봤다. 검사기 호출은 `python` 으로 떨어지게 해 두었다.
  - 옆 창이 저절로 열리는 것은 144열 이상에서다. 좁으면 프롬프트 위 한 줄이 대신하고, `/tiket` 으로 직접 열 수 있다.
  - 답변 복사는 `## 답변 초안` 절 전체를 넣는다. 회신 템플릿이 정해지면 고객용 블록만 자르게 고친다.
- **끄는 법**: `/plugin` 의 Installed 탭에서 `tiket-flow` 를 끈다. 한 세션만이면 `claude --safe-mode`.

---

**2026-10-24 — 폐기: mod 를 걷어냈다.** 동료는 전부 Kiro 이고 Claude Code 는 유지보수자 하나인데, 유지보수자도 mod 를 쓰지 않는다(2026-10-23).
`mods/`·`docs/claude-code-pane.md`·`scripts/test_mod_tiket_flow.py` 를 지웠고, `render_agent_configs.py` 가 `.claude/settings.json` 에
`enabledPlugins`·`extraKnownMarketplaces` 를 더 이상 쓰지 않는다. Claude Code 자체 지원(`CLAUDE.md`·`.claude/` 훅)은 남긴다. 위 본문은 당시 기록으로 둔다.
