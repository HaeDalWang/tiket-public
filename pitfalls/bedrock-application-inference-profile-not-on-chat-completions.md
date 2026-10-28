---
observed:
  - 2026-10-08 | ticket 100020
sources:
  - 2026-10-19 | aws-doc | https://docs.aws.amazon.com/bedrock/latest/userguide/projects.html | 표기 없음
  - 2026-10-19 | aws-doc | https://docs.aws.amazon.com/bedrock/latest/userguide/inference-profiles-use.html | 표기 없음
  - 2026-10-19 | aws-doc | https://docs.aws.amazon.com/bedrock/latest/userguide/inference-chat-completions.html | 표기 없음
  - 2026-10-19 | poc | us-west-2, openai.gpt-oss-20b-1:0 — 모델 ID 로 Chat Completions 200, 같은 모델을 복사한 application inference profile ARN 으로 Chat Completions 400, 같은 ARN 으로 Converse 성공 | bedrock-runtime /openai/v1/chat/completions
review_by: 2027-01-19
---

# Bedrock application inference profile 을 Chat Completions(OpenAI 호환)에 쓸 수 있다고 답하기 쉬운데, 2026-10-19 실제 호출은 400 으로 거절됐다 — 문서끼리 말이 다르니 문서 한쪽만 보고 단정하지 않는다

## 무엇을 하면 틀리는가

- Projects 문서의 비교 표("Inference Profiles … OpenAI-compatible API (Chat Completions)")만 보고 application inference profile(AIP)
  ARN 을 OpenAI SDK 의 `model` 에 넣으면 된다고 안내한다.
- 반대로, 문서에 없다는 이유만으로 "인퍼런스 프로파일은 Chat Completions 를 전혀 못 쓴다" 고 일반화한다 — 시스템 정의(cross-Region)
  프로파일은 이 카드에서 확인하지 않았다.

## 실제로 있었던 일

- 2026-10-08(후보 등록일): AIP 로 비용을 나누면서 OpenAI 호환 Chat Completions 를 쓰려는 문의. 담당자가 공식 문서끼리 지원 여부가
  엇갈리는 것을 찾았고 "테스트로 확정하라" 는 교훈 후보로 올렸다.
- 2026-10-19: 유지보수자가 문서를 다시 보고 실제 호출로 확인했다(아래 `poc`).

## 확인된 사실

- Projects 문서의 비교 표는 Inference Profiles 가 `bedrock-runtime` 에서 "Native Bedrock APIs (Invoke, Converse), OpenAI-compatible API
  (Chat Completions)" 를 지원한다고 적는다. 시스템 정의 프로파일과 AIP 를 나누지 않는다
  (https://docs.aws.amazon.com/bedrock/latest/userguide/projects.html).
- 인퍼런스 프로파일 사용 문서는 쓸 수 있는 API 로 InvokeModel, Converse, RetrieveAndGenerate 등을 나열하고 Chat Completions 는 없다
  (https://docs.aws.amazon.com/bedrock/latest/userguide/inference-profiles-use.html).
- Chat Completions 문서는 `bedrock-runtime` 의 `/openai/v1/chat/completions` 를 설명한다
  (https://docs.aws.amazon.com/bedrock/latest/userguide/inference-chat-completions.html).
- 2026-10-19 `poc`(us-west-2, `openai.gpt-oss-20b-1:0`):
  - 모델 ID 로 Chat Completions → `HTTP 200`
  - 그 모델을 `copyFrom` 한 AIP ARN 으로 Chat Completions → `HTTP 400`
    `"Application inference profiles are not supported by this API."` (`validation_error`)
  - 같은 AIP ARN 으로 Converse → 성공. AIP 자체는 정상이었다.

`unknown` — 다른 모델·리전, 시스템 정의 프로파일(`us.`·`global.` 접두어)로 Chat Completions 를 부를 때. `bedrock-mantle` 의 Projects 는
이 카드의 대상이 아니다.

## 해야 할 것

1. AIP 로 OpenAI 호환 API 를 쓰려는 문의에 "된다" 고 단정하지 않는다. 2026-10-19 기준 `bedrock-runtime` Chat Completions 는 AIP 를
   400 으로 거절했다고 알리고, 위 오류 문구를 근거로 든다.
2. 비용 태깅이 목적이면 대안을 함께 적는다: AIP 로 Converse/InvokeModel 을 쓰거나, OpenAI 호환 API 가 꼭 필요하면 `bedrock-mantle` 의
   Projects(태그로 비용 추적)를 검토한다.
3. 고객 환경(모델·리전·프로파일 종류)이 위 `poc` 와 다르면 결과를 옮겨 쓰지 말고, 같은 조건으로 한 번 호출해 보라고 안내한다.

## 다시 쓰기 전에 확인할 것

- Projects 문서 비교 표와 인퍼런스 프로파일 사용 문서의 API 목록이 바뀌었는지.
- 같은 호출이 지금도 400 인지 — AIP 를 만들고 `/openai/v1/chat/completions` 에 ARN 을 넣어 한 번 부르고, AIP 는 지운다.

## 변경 이력

- 2026-10-19: 작성. 승인된 교훈 후보에서 옮겼다. 후보가 근거로 든 "AIP 전용 문서의 미지원(400) 문구" 는 문서에서 찾지 못해
  실제 호출로 대신 확인했다.
