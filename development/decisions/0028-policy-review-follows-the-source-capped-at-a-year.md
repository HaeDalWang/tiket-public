# 0028. 규칙 카드의 재확인 기한은 원문을 따르되 1년을 넘지 못한다

- **언제**: 2026-09-30
- **정한 것**: active 규칙 카드의 `review_by` 는 원문의 성격에 맞춰 승인할 때 카드마다 정한다
  (Slack 공지 ≈ 3개월, 공식 문서 최대 1년). 검사기는 상한 `reviewed_at + 365일` 만 강제한다.
  같은 날 검사기가 통과시키던 허점도 막는다 — active 카드는 `sources.json` 에 등록된 `source_document`,
  달력에 있는 날짜(기록 날짜는 오늘 이후 불가), `-`·`?` 같은 자리표시 값 거부, 비지 않은 7개 섹션,
  날짜 붙은 변경 이력, 라우팅 표의 발효일·기한이 카드와 같을 것. `superseded` 는 실제 대체 카드 id 가 있을 것.
- **왜**: 사례 양식(0027)에서 찾은 허점이 규칙에도 있었다. active 카드 `POLICY-COST-ESC-001` 을 복사본에서
  10가지로 변형했더니 9개가 통과했다 — 근거 문서 없는 active, `review_by: 2999`, `reviewed_at` 1년 전에
  기한만 연장, `superseded` 인데 대체 카드 없음(`policy/README.md` 가 요구하는데 검사가 없었다),
  `source_version: "-"`, `approved_at: "어제쯤"`, `2026-13-45`, 미래 검토일, 빈 `Control statement`.
- **기한을 없애지 않은 이유**: 규칙 **내용**은 영원할 수 있다. 하지만 카드가 주장하는 것은 "원문 X 의 이 버전이
  이렇게 말하고, 그 원문이 아직 유효하다"이다. 원문은 개정되고(`POLICY-SEC-001` 원문에 "최종 업데이트 2026-02-10"),
  대체·폐지된다. 원문 해시 검사는 누가 새 원문을 가져와야만 걸린다. 기한은 "원문을 다시 열어 버전을 보라"는 알림이고,
  안 바뀐 원문이면 확인은 금방 끝난다.
- **버린 선택지**:
  - 모든 카드 92일 고정 — 헌법 같은 규칙에 분기마다 도장만 찍게 되고, 도장 찍기는 "안 열어 보고 기한만 미는"
    허점을 의식으로 만든다
  - 만료 없음 허용(`review_by: none`) — 원문이 바뀐 걸 알아챌 장치가 하나도 남지 않는다.
    **영원히 갈 규칙은 카드가 아니라 `CLAUDE.md` Absolute boundaries 로 올린다** — 만료가 없고, 문장 보존만
    검사하고, 4,500자 한도가 그 층을 짧게 지킨다
  - 사례처럼 180일 — 규칙 원문은 사례의 AWS 문서보다 느리게 바뀐다. 유지보수자가 1년으로 정했다
  - 규칙 템플릿 새로 만들기 — `policy/cards/_template.md` 가 이미 있다. 필드 주석만 보강했다
  - `playbooks/` 템플릿 — 파일 5개에 URL 0개, 전부 우리가 정한 절차라 낡을 바깥 사실이 없고, 규격·규칙·관문은
    생김새가 달라 한 양식에 안 들어간다. 핵심 문장은 이미 marker 검사가 지킨다.
    다시 볼 조건: 0026 경로로 `playbook` 후보가 승인되기 시작할 때
- **근거**: `scripts/validate_workspace.py` `validate_active_policy_card`·`validate_active_policy_dates`,
  `scripts/test_validate_workspace.py` `test_policy_*`, `policy/cards/_template.md`, `policy/README.md`
