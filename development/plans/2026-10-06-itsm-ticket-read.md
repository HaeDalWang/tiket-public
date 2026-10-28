# ITSM 에서 티켓을 읽는다 — `fetch-ticket.sh` 가 Zendesk 대신 부를 것

상태 (2026-10-06): 소스만 읽었다. 한 번도 불러 보지 않았다. 만들지 않는다 — 요청 문안의 근거를 모으는 단계다.
상태 (2026-10-23, 유지보수자): 요청 넷을 기다리지 않고 지금 API 로 `scripts/itsm_ticket.py` 를 만들었다 — 실제 전환은 2027-04 쯤이라 오면 고친다.
`fetch-ticket.sh` 에는 잇지 않았다. 검색 4종·단건·활동, 처음 보는 활동 종류는 `[구분 모름]`, GET 만, 정확 일치가 없을 때만 Zendesk 번호를 단건으로 대조한다.
소스로 못 가른 것: Zendesk 번호와 `ticket_number` 의 관계, `problem` 은 활동 경로가 없다, `ticket_authority` 는 장애에만 있다, 첨부 내려받기.
같은 날 `origin/dev`(`0f910b9d`)에 요청 넷은 하나도 없다.

근거는 전부 `~/work/itsm` 의 `origin/dev` 다(읽기만, 2026-10-06 04:32 UTC 커밋까지). 운영(`origin/main`)은 431 커밋 뒤라 아래 중 일부가 없다.

## 1. 지금 `fetch-ticket.sh` 가 Zendesk 에서 받는 것

티켓 메타(번호·상태·제목·생성·갱신·우선순위·유형), 댓글 전체(시간순, 작성자 이름·역할, 공개/내부 구분, 본문),
첨부 이름·크기, 본문에 붙여넣은 이미지(`--images` 로 내려받기).

## 2. ITSM 에서 같은 것을 받는 길

| 필요한 것 | ITSM (`origin/dev`) | 상태 |
|---|---|---|
| 번호 → 티켓 | `GET /api/search/tickets?q=<번호>` — `ticket_number`(4종 공통 번호) 정확 일치, Zendesk 번호(`zendesk_ticket_id`)·제목은 부분 일치. `{items:[{type,id,ticket_number,customer_id,…}]}` (`routes/ticket-search.js`) | 확인. 단건 조회가 아니라 검색이다 — 제목에 그 숫자가 든 다른 티켓도 섞여 온다. 정확 일치는 맨 앞에 온다 |
| 티켓 메타 | `GET /api/incidents/:id` — `i.*` + `customer_name` + SLA + `tags` (`routes/incidents.js:680`). 서비스 요청은 `GET /api/service-requests/:id` | 확인(장애). 서비스 요청 쪽은 안 읽었다 |
| 댓글 스레드 | `GET /api/incidents/:id/activity` — `{activities:[…], sla}`. 최신순. 작성자 이름·역할·팀, `content`, `attachments[]` | 확인 |
| 공개/내부 구분 | 내부 전용 종류가 `work_note`·`internal_note`·`reply_cc` 로 정의돼 있다 (`lib/activity-visibility.js`) | 확인. 고객 답변의 종류 이름은 안 읽었다 |
| 첨부 | 활동마다 `attachments[].download_url`, 메일로 온 첨부는 티켓의 `inbound_attachments[]` | 확인(목록). 토큰으로 내려받아지는지는 모른다 |
| 본문 이미지 | 서버가 본문의 이미지 주소를 CloudFront 서명 URL 로 바꿔 내린다 | 확인(치환). 만료 시간·토큰 없이 받아지는지는 모른다 |
| 그 고객의 특이사항 | 티켓에 `customer_id` 가 있다 → `GET /api/customers/<customer_id>/notes` 로 바로 간다 | 확인. **`corpId` 로 `lookup` 할 필요가 없다** |

## 3. 빠졌거나 걸리는 것 — 요청 후보

1. **읽기 전용 토큰이 없다 (가장 크다).** `api_tokens` 에 범위 칸이 없고(`migrations/008`), 미들웨어가 `viaApiToken: true` 를 달지만
   그것을 보는 코드가 없다. 주석도 "권한은 발급자 본인과 동일" 이다. 같은 토큰으로 `POST /api/incidents/:id/comments` 에
   `visibility=customer` 와 `idempotency_key` 를 주면 고객 답변이 된다(발송 정책 검사는 거친다).
   우리 "초안만, 보내지 않는다" 경계가 ITSM 에서는 문구뿐이다 — Zendesk OAuth 로 얻으려던 "쓰기가 서버에서 막힌다" 가 없다.
   → 요청: 토큰 발급 때 `scope: read`. 읽기 전용 토큰은 GET 외 전부 403. 특이사항 쓰기만 따로 열 수 있으면 더 좋다.
2. **번호로 한 건을 바로 받는 길이 없다.** 검색 → 단건 → 활동 세 번을 부르고, 검색 결과에서 정확 일치를 우리가 골라야 한다.
   → 요청: `GET /api/tickets/by-number/<번호>` 가 종류와 id(또는 스레드까지)를 준다. 없어도 우리 쪽에서 걸러 쓸 수는 있다.
3. **티켓에 `billing_corp_id` 가 안 실린다.** `customer_name` 만 온다. 특이사항에는 필요 없지만 빌링 플랫폼·자격증명 브로커는 `corpId` 로 묻는다.
   → 요청: 티켓 단건 응답에 `customer.billing_corp_id`.
4. **공개/내부를 한 칸으로 알 수 없다.** 종류 이름 목록을 우리가 알고 있어야 한다. 목록이 늘면 내부 메모를 고객 발언으로 읽는다.
   → 요청: 활동마다 `is_internal`(또는 `visibility`). 지금 정의가 한 파일에 모여 있어 붙이기 쉽다.
5. **본문이 HTML 일 수 있다**(`content_format` 이 `html`|`text`). 우리 쪽에서 텍스트로 바꿔야 한다 — 요청이 아니라 우리 일이다.
6. **엔지니어 토큰은 전 고객 티켓 목록을 받을 수 있다**(`GET /api/incidents/all`). 특이사항에서 막은 "여러 고객이 한 응답에 섞인다" 가
   티켓에서는 열려 있다. 우리 스크립트가 그 경로를 안 부르는 것으로 막는다 — 권한 규칙에 넣는다.

## 4. 불러 봐야 갈리는 것

dev 에서 GET 만으로 확인한다(유지보수자가 말하면): 서비스 요청의 단건·활동 형태, 고객 답변의 종류 이름, 첨부·서명 URL 내려받기,
Zendesk 에서 넘어온 티켓의 `ticket_number` 가 Zendesk 번호와 같은지(동료는 Zendesk 번호로 부른다).

## 5. 모르는 것

전환 일정. `ticket_authority`(`itsm`|`zendesk`) 가 티켓마다 있어 병행 기간에는 어느 쪽 스레드가 정본인지 티켓마다 다를 수 있다 — 읽는 쪽이 이 칸을 봐야 하는지 모른다.

## 6. 낼 문안 (2026-10-06 작성, 냈는지는 모른다)

ITSM 기능 요청 양식의 `사유` 칸. 항목은 3절의 1번이 중심이고 2~4번은 없어도 우리 쪽에서 돌려 쓴다.
PR 로 내지 않는다 — 그 저장소는 브랜치를 푸시하면 게이트를 거쳐 `dev` 에 바로 머지·배포되고(`CONTRIBUTING.md`), 작업마다 Jira `SCRUM` 티켓이 먼저인데 유지보수자는 Jira 계정이 없다.

> 제가 개인적으로 만들어 쓰는 티켓 처리 AI 워크스페이스(tiket)를 나중에 Zendesk 대신 ITSM API 로 붙이려고 dev 소스를 읽어 봤습니다.
> 지금 API 그대로도 티켓을 읽는 데는 문제가 없습니다. 다만 cops_ 토큰이 발급자와 권한이 같아서, AI 에 물린 토큰으로 고객 답변 등록(POST /api/incidents/:id/comments, visibility=customer)까지 됩니다.
> 저는 "AI 는 초안만, 발송은 사람이" 원칙으로 쓰는데 지금은 프롬프트로만 막고 있어, 서버에서 막히는 읽기 전용 토큰이 있으면 좋겠습니다.
> 공식 요구사항이 아니라 개인 프로젝트 쪽 사정이라, 우선순위에 안 맞으면 편하게 넘기셔도 됩니다.
