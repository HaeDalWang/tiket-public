# 0029. 온보딩은 막힘과 제한을 가르고, 이 PC 에서 되는 기능은 세션마다 다시 본다

- **언제**: 2026-10-01
- **정한 것**:
  - 온보딩(`onboarding.sh`/`.ps1`)의 FAIL 을 없앤다. **막힘**은 워크스페이스가 안 돌거나 경계가 깨지는 것뿐이다 —
    git·python3, 에이전트, push guard, MCP 설정 누락·경계 위반. exit 1 은 막힘에서만 난다.
    **제한**은 그 기능만 빠지는 것이고, 줄마다 빠지는 기능 이름을 붙인다(티켓 번호로 가져오기, 고객 AWS·비용 조회,
    Hermes 자동 업데이트·지표, 지표에 내 이름 표시, 저장소 규칙 검사). 마지막 줄이 안 되는 기능을 모아 보여 준다.
  - 온보딩 결과는 어디에도 저장하지 않는다. 세션 시작 때 `check-freshness` 가 `local_capabilities.py --if-missing`
    을 불러, 파일만 보고(Zendesk 키 3개, `fetch-ticket.sh` 의 curl·jq, `csg-login` 마커) 빠진 게 있을 때만 한 줄 알린다.
  - `agents/runtime-status.md` 의 표는 팀 공통 상태(유지보수자 PC 관찰)라고 밝히고, 이 PC 는 위 한 줄을 따르게 한다.
- **왜**: 8단계 중 하나만 빠져도 빨간 FAIL 과 "N개 항목이 남았다" 가 떠서 동료가 유지보수자를 불렀다(유지보수자).
  실제로는 대부분 기능 하나가 빠질 뿐이었다 — 지표 이름이 비어도 FAIL 이었다. 그리고 에이전트가 읽으라는
  `runtime-status.md` 는 유지보수자 PC 를 2026-09-11 에 본 결과라, 스킬이 없는 동료 PC 에서도 `enabled` 로 읽혔다.
- **버린 선택지**:
  - 온보딩이 결과를 `~/.config/msp/` 에 파일로 남긴다 — 나중에 설치하면 그 순간 낡는다. 매번 보는 비용은
    파일 몇 개 읽기다
  - 세션 시작 명령에 새 단계를 더한다 — Codex 는 명령 해시를 사용자마다 승인받는다(0020). 그래서 모든 호스트가
    이미 지나가는 `check-freshness` 안에서 부른다. 스로틀보다 앞이라 매 세션 돌고, `--notify-only`(fetch-ticket)는 건너뛴다
  - 다 될 때도 한 줄 — 다 갖춘 사람에게 매 세션 소음이다. 직접 물으면(`python3 scripts/local_capabilities.py`) 답한다
  - push guard 를 제한으로 — 고객 자료 push 차단이 꺼지는 보안 경계라 막힘에 둔다(유지보수자 확인)
- **남는 한계**: Hermes 는 훅 출력을 버린다(`hermes_hook.py`) — Hermes 에서는 직접 실행해야 보인다.
  Windows 에서 curl·jq 는 쓰지 않으므로(`fetch-ticket.ps1`·스킬 `.ps1` 확인) 건너뜀으로 둔다.
- **근거**: `scripts/local_capabilities.py`, `scripts/test_local_capabilities.py`,
  `scripts/test_onboarding_parity.py` `OnboardingOutcomeTests`, `scripts/test_check_freshness.py` 의 capabilities 시나리오
