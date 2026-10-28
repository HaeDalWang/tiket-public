# 0016. 최신 여부는 알리기만 한다 — 자동 pull 은 하지 않는다

- **언제**: 2026-09-08
- **정한 것**: 세션 시작마다 `scripts/check-freshness.sh` 가 하루 1회 `git fetch` 하고,
  공용 저장소가 앞서 있으면 **한 줄로 알린다**. `git pull` 은 사람이 친다.
  Claude Code 훅은 `.claude/settings.json` 이 생성물이므로
  `render_agent_configs.py` 의 `render_claude_settings()` 가 찍는다.

- **왜 이 논의가 나왔나**: 공용 규칙이 자주 바뀔 예정이라, 엔지니어가 낡은 규칙으로
  고객 답변을 쓰는 상황을 막고 싶다. "하루/일주일에 한 번 자동으로 pull 하게 하자"가
  제안됐다.

- **자동 pull 을 버린 이유**:
  - 이 저장소에서 pull 은 코드가 아니라 **에이전트의 계약**(`CLAUDE.md`, `policy/`,
    `playbooks/`)을 세션 도중에 바꾼다. 진행 중인 판단의 근거가 발밑에서 달라진다.
  - 작업 트리가 더러우면 pull 이 실패하거나 머지 커밋을 만든다. 치우는 건 엔지니어
    몫이고, 그건 우리가 만든 문제다.
  - `fetch` 는 작업 트리를 건드리지 않는다. "3커밋 갱신됨 → git pull" 한 줄이면
    유도 효과는 사실상 같다.

- **거짓 초록불을 먼저 막는다**: 저장소를 `maintainer-gh/tiket` 에서 `example-org/tiket` 로
  **새로 만들어** 옮겼다. transfer 가 아니라서 옛 주소 리다이렉트가 없다. 이미 clone 해간
  사람의 origin 은 여전히 옛 저장소를 가리키고, **그 저장소는 살아 있어서 fetch 가
  성공하고 "뒤처짐 0" 이 나온다.** 최신이 아닌데 최신이라고 표시되는 것이 프레시니스
  도구의 최악 실패 모드다.
  그래서 스크립트는 뒤처짐을 세기 **전에** origin URL 이 정본과 같은지 먼저 보고,
  다르면 스로틀을 무시하고 매번 `git remote set-url` 을 안내한다.

- **실패해도 세션을 막지 않는다**: 저장소가 아님, 네트워크 실패, upstream 없음,
  스탬프 파일 쓰기 실패 — 전부 조용히 exit 0. 온보딩과 달리 이건 관문이 아니다.

- **스탬프를 fetch 앞에 찍는 이유**: 오프라인에서 매 세션 느린 fetch 를 반복하지 않기
  위해서다. 대가로 오프라인인 날은 확인을 한 번 건너뛴다. 세션 지연보다 낫다고 봤다.

- **확인한 사실** (2026-09-08):
  - `.claude/settings.json` 은 `render_claude_settings()`(`scripts/render_agent_configs.py:74`)
    가 통째로 생성한다. 손으로 hooks 를 넣으면 `--check` 가 드리프트로 잡는다.
  - 샌드박스 실측: 업스트림이 2커밋 앞선 상태에서 `공용 규칙이 2커밋 갱신됐다` 출력,
    `git pull` 후 재실행 시 무출력.
  - origin 이 옛 주소일 때 교정 명령 출력 확인.

- **아직 안 한 것**:
  - Codex·Kiro·Hermes 의 세션 훅 규약은 확인하지 않았다. 현재 자동 실행되는 에이전트는
    **Claude Code 하나**다. 나머지는 `bash scripts/check-freshness.sh` 를 직접 돌려야 한다.
  - `check-freshness.ps1` 은 이 머신에 `pwsh` 가 없어 실행 검증하지 못했다.

- **고정 방법**: `test_onboarding_parity.py::FreshnessParityTests` 가 두 스크립트에
  자동 pull 이 없는지, 정본 remote 를 고정했는지, 스로틀과 `--force` 가 양쪽에 있는지 본다.

- **2026-09-24 뒤집힘**: [[0025-workspace-updates-itself-to-release-tags]] 가 "알리기만" 을
  "정식 태그로, 안전할 때만 스스로 올린다" 로 바꿨다. 알림을 다들 귀찮아해서 실제로 pull 을
  안 쳤다. 이 문서의 세 이유가 각각 어떻게 풀렸는지는 0025 에 있다. 거짓 초록불(origin 검사)
  과 실패해도 세션을 막지 않는다는 원칙은 그대로 산다.
