# 사용 지표 A·B·C·D — 일단 다 모으고, 한 주 보고 걷어낸다

- 시작: 2026-10-04 (휴일) · 결정: 유지보수자 — "ABCD 전부 모으도록 개발하고 다음 주 자체를 본다. 필요 없는 건 걷어낸다"
- 상태 (2026-10-04): 착수. 조율자가 워크트리 셋에 Kiro 를 나눠 맡기고 검증한다.
- 2026-10-04 오후: W1·W2·W3 끝. 조율자가 각각 테스트를 다시 돌리고 변이로 단언을 확인한 뒤 main 과 사이트 작업 트리로 옮겼다.
  W2 는 검토 1차에서 네 가지를 고쳤다(20초 상한이 B 에만 걸려 있었다 · 오류를 캐시하지 않았다 · 못 막는 변이 셋 · 머리말).
  W3 는 가중 평균이 null 을 0 으로 세던 것을 고쳤다. `report_usage.build_payload` 에 `zendesk` 를 이었고, `TIKET_ZENDESK=off` 로
  이것만 끌 수 있다. 테스트는 그 스위치로 진짜 Zendesk 를 막는다.

## 왜

지금 지표는 활동량뿐이다 — 분모가 없고(30건이 많은지 모른다), 시간이 없고, 누적 합계라 주끼리 비교가 안 된다.
도입 효과 보고서(2026-10-02)가 "개선" 과 "속도" 를 비워 둔 이유가 이것이다.

## 무엇을 모으나

| | 무엇 | 어디서 | 답하는 질문 |
|---|---|---|---|
| A | 기록의 작성 주(`날짜:` 의 ISO 주)별 검사 결과 — 매번 **지금 검사기로 다시 채점** | PC 의 `tickets/` | 검사 통과율이 주마다 오르나 |
| B | `## 답변 초안` 과 Zendesk 에 실제로 올라간 **내 공개 답변**의 유사도 | 기록 + Zendesk 댓글 | AI 초안을 얼마나 고쳐서 보냈나 |
| C | 첫 응답·해결까지 걸린 시간, 재오픈 — tiket 기록이 **있는** 티켓과 **없는** 티켓을 나눠서 | Zendesk `metric_sets` | 빨라졌나. Zendesk 에 도입 전 이력이 있어 이전과 비교된다 |
| D | 그 주에 해결된, 나에게 배정된 티켓 수와 그중 기록이 있는 수 | Zendesk 검색 | 맡은 티켓 중 몇 %를 tiket 으로 처리했나 |

B 를 기록 안에서 재지 않는 이유: `## 실제 발송` 은 보낸 문장이 아니라 메모다 — 2026-09-28 에 재 보니 유사도 0.02~0.16 이었다
(`report_usage.sent_counts` 주석).

## 근거 (2026-10-04, Zendesk 공식 문서)

- `GET /api/v2/tickets/{id}/metrics`, 필드 `reply_time_in_minutes` · `full_resolution_time_in_minutes`(각각 calendar/business) · `reopens`. Agent 권한으로 읽는다.
- `GET /api/v2/search/count?query=…` 건수만. 검색은 쿼리당 최대 1,000건, 페이지당 100건.
- 검색어 `assignee:me`, `solved>YYYY-MM-DD solved<YYYY-MM-DD`.
- 티켓 사이드로드 `include=metric_sets` — `GET /api/v2/tickets/show_many?ids=…&include=metric_sets` 로 100건씩 한 번에.

## 보내는 모양 (schema_version 은 2 그대로, 키만 더한다)

수집기는 `schema_version` 이 {1, 2} 인지만 보고 payload 를 통째로 저장한다(64KB 상한). **키를 더하기만 하면 수집기를
바꾸거나 다시 배포할 필요가 없다.** 사이트는 모르는 키를 무시한다. 그래서 순서에 얽매이지 않는다.

```json
"weekly": {
  "2026-W40": {"count": 3, "passed": 2, "failed": 1, "pre_schema": 0,
               "categories": {"safety": 0, "routing": 1, "record": 0, "lessons": 0, "format": 0}}
},
"zendesk": {
  "computed_at": "2026-10-04T05:00:00Z",
  "weeks": {
    "2026-W40": {
      "solved": 12, "with_record": 3,
      "reply_minutes":      {"with": {"n": 3, "calendar": 42, "business": 30}, "without": {"n": 9, "calendar": 95, "business": 61}},
      "resolution_minutes": {"with": {"n": 3, "calendar": 600, "business": 300}, "without": {"n": 9, "calendar": 1440, "business": 700}},
      "reopened": {"with": 0, "without": 1}
    }
  },
  "draft_similarity": {"2026-W40": {"n": 2, "median": 0.71, "high": 1, "mid": 1, "low": 0}}
}
```

- 주는 ISO 주(`YYYY-Www`), 최근 **8주**. 분 단위 값은 **중앙값**(정수). 값이 없으면 `null`, `n` 은 그 중앙값의 표본 수.
- 유사도 구간: high ≥ 0.9, mid 0.6~0.9, low < 0.6. `difflib.SequenceMatcher` 비율, 공백을 접은 평문끼리.
- Zendesk 를 못 읽으면 `"zendesk": {"error": "<짧은 코드>"}` — `no_credentials` · `auth` · `timeout` · `http_<code>` · `parse`. 값은 지어내지 않는다.
- **티켓 번호·고객명·본문은 보내지 않는다.** 기존 `assert_no_identifiers` 를 그대로 지난다.

## 시간과 실패

- Zendesk 계산은 **하루 한 번**만 한다. 결과를 `~/.config/msp/tiket-zendesk-metrics.json` 에 두고, 6시간마다의 전송은 그 값을 싣는다.
- 한 번 계산에 상한 20초. 넘으면 그때까지 것을 버리고 `timeout`. 세션 시작 훅의 한 단계 상한(50초) 안이다.
- 무엇이 실패해도 세션 시작을 막지 않고 아무것도 출력하지 않는다 — `run_if_due` 의 원칙 그대로.
- 자격증명은 `fetch-ticket.sh` 와 같은 곳(`~/.config/msp/zendesk.conf`, 환경변수 우선). OAuth 이전 백로그와 같은 길이다.

## 보이는 범위

- 사이트는 **팀 합계만** 보인다. 사람별 속도는 평가 도구로 읽힐 수 있다 — 유지보수자가 정하기 전까지 기본은 팀 합계(조율자 제안, 2026-10-04).
- 수집기에는 지금처럼 사람별 행이 쌓인다(사이트의 기존 사람별 표는 그대로).

## 나눠 맡기기

| 작업자 | 워크트리 | 맡는 것 | 겹치지 않게 |
|---|---|---|---|
| W1 Kiro | tiket `usage-weekly` | A — `report_usage.py` 에 `collect_weekly` | `report_usage.py`·그 테스트만 |
| W2 Kiro | tiket `usage-zendesk` | B·C·D — 새 파일 `scripts/usage_zendesk.py`(+테스트). `collect_zendesk(root, today) -> dict` 하나를 내놓는다 | `report_usage.py` 를 건드리지 않는다 |
| W3 Kiro | 사이트 `usage-abcd` | 위 모양을 읽어 팀 합계 카드·주별 그래프 | 배포는 유지보수자 |
| 조율자 | `main` | 검증, `build_payload` 에 두 줄 연결, README "밖으로 나가는 데이터"·온보딩 고지·`TECHNICAL.md`, 릴리스 노트 | |

모든 스크립트는 TDD + 변이 확인. 테스트는 실서버(Zendesk·수집기)에 닿지 않는다.

## 다음 주에 볼 것 (2026-10-05 ~ 10-11)

- 동료 행에 `weekly`·`zendesk` 가 실리나, `zendesk.error` 가 얼마나 나오나(자격증명 없는 PC 가 몇이나 되나).
- D 의 비율이 사람마다 의미 있게 갈리나. C 의 with/without 표본이 비교할 만큼 쌓이나(주당 n).
- B 의 유사도가 0 근처에 몰리면 초안과 실제 답변의 모양이 달라 비교가 무의미한 것이다 — 그러면 걷어낸다.
- 걷어낼 때 이 계획서에 날짜와 이유를 남긴다.
