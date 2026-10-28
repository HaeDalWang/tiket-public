# 0013. 폐기된 무거운 형식의 잔해를 전부 제거

- **언제**: 2026-09-07
- **정한 것**: [[0001-drop-the-heavy-ticket-format]] 에서 규칙만 바꾸고 남겨뒀던 파일과
  검증 코드를 실제로 삭제한다.

- **삭제한 것**

  | 대상 | 규모 |
  |---|---|
  | `templates/` 폐기 템플릿 5개 (decision-packet · reply-brief · ticket · ticket-evidence · ticket-history) | 208줄 |
  | `examples/` 전체 (옛 3파일 형식 견본) | 9파일 |
  | validator 의 Decision Packet v1/v2 검증 | 325줄 |
  | validator 의 examples 검증 | 95줄 |
  | validator 의 `customers/*/tickets/` 옛 3파일 검사 | 59줄 |
  | 호출부가 사라진 헬퍼 3개 + 죽은 상수 4개 | 36줄 |

  `scripts/validate_workspace.py` **1,658줄 → 1,034줄 (624줄, 38% 감소)**.
  전체로는 2,622줄 삭제.

- **왜 이제 지웠나**: 0001 은 "규칙부터 바꾸고 파일 삭제는 나중에"였다. 되돌리기 쉬운
  것부터 했기 때문이다. 이후 산출물 3종이 확정([[0009-work-order-is-runnable-steps]] ·
  [[0010-investigation-output-locked]] · [[0011-advisory-output-locked]])되고 실제 티켓
  네 건에 적용해 검증했으므로, 대체재가 자리를 잡았다고 판단했다.

- **폐기 형식이 남아 있으면 생기는 일**: `agents/task-router.md` 가 삭제된
  `templates/decision-packet.md` 를 가리키고 있었고, `playbooks/reply-writing-rules.md` 는
  Decision Packet v2 를 쓰라고 지시하고 있었다. **읽는 쪽이 어느 쪽을 따라야 할지 알 수 없다.**
  실제로 다른 엔지니어가 워크스페이스를 돌렸을 때 어긋난 초안이 나왔다([[0012-pre-send-gate]]).

- **`examples/` 는 통째로 삭제했다** (사용자 결정). 옛 형식으로 쓰여 있어 새 형식과
  충돌했고, 새로 쓰는 대신 지우는 쪽을 택했다.
  **비용**: 신규 엔지니어가 볼 완성된 티켓 예시가 없다. `templates/ticket-intake.md` 와
  `playbooks/ticket-outputs.md` 가 형식을 설명하지만 완성본은 아니다.
  실제 티켓이 쌓이면 비식별 예시를 다시 만들 수 있다.

- **남긴 것**:
  - `CUST-NNN` 비식별 규칙 — 0002 는 **로컬 `tickets/` 에서만** 마스킹을 뺐다.
    tracked 파일과 공용 저장소에서는 그대로 유효하므로 건드리지 않았다.
  - `customers/*/tickets/` 가 존재하면 "tickets/ 로 옮기라"고 실패시키는 검사 8줄.
    옛 구조를 쓰던 워크스페이스가 조용히 넘어가지 않게 한다.

- **작업 중 발견한 사고 — 안전 경계가 세 진입점에서 사라져 있었다**:
  `Never call customer-account write APIs, change infrastructure, or run terraform apply`
  가 `CLAUDE.md`, `AGENTS.md`, `.kiro/steering/00-repository-rules.md` **셋 모두**에서
  없어진 상태였다. 이번 정리에서 건드린 파일이 아니고 언제 사라졌는지 특정하지 못했다.

  `CLAUDE.md` 는 `CANONICAL_MARKERS` 가 잡아냈지만, **나머지 둘은 아무도 못 잡았다** —
  `ENTRYPOINT_MARKERS` 가 경로 참조만 검사하고 안전 문장은 검사하지 않았기 때문이다.
  세 진입점의 안전 문장을 `ENTRYPOINT_SAFETY_MARKERS` 로 묶어 전부 고정했고,
  실제로 한 줄을 지워 FAIL 이 나는 것까지 확인했다.

  **교훈**: 정본 하나만 검사하면 사본이 조용히 갈라진다. 같은 문장을 여러 파일이
  나눠 갖는다면 검사도 그 수만큼 있어야 한다.
