---
observed:
  - 2026-10-02 | ticket 100019
sources:
  - 2026-10-07 | aws-doc | https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-maintenance.html | 표기 없음
  - 2026-10-07 | aws-doc | https://docs.aws.amazon.com/AmazonECS/latest/developerguide/service-event-messages-list.html | 표기 없음
review_by: 2027-03-31
---

# Fargate task retirement 에서 "새 태스크를 먼저 띄운다" 를 minimumHealthyPercent 로 설명하기 쉬운데, 그 순서를 만드는 것은 maximumPercent 다

## 무엇을 하면 틀리는가

- "`minimumHealthyPercent` 가 100% 이므로 새 태스크가 뜬 뒤에 기존 태스크가 내려간다 — 중단이 없다" 고 답한다.
  `maximumPercent` 를 보지 않았다.
- AWS 문서의 한 문단이나 Health 알림 본문만 옮겨 적는다. 같은 문서의 다른 문단은 다른 값을 기준으로 든다.
- 고객이 "`minimumHealthyPercent` 100 으로 해 뒀으니 괜찮죠?" 라고 물을 때 그 전제를 그대로 받는다.

## 실제로 있었던 일

- 2026-10-02(후보 등록일 — 티켓이 들어온 날은 받지 못했다): Fargate task retirement 문의에서 고객은 `minimumHealthyPercent` 만
  보고 있었다. 담당자가 AWS 문서를 대조하다가 같은 문서 안에서 두 기준이 섞여 있음을 찾았고, 교훈 후보로 올렸다.

## 확인된 사실

- 같은 문서가 두 가지로 설명한다(https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-maintenance.html).
  - 도입부: 스케줄러는 태스크를 멈출 때 **`maximumPercent`** 를 쓴다. REPLICA 서비스의 기본값은 200% 이므로 새 태스크를 먼저
    띄우고 실행을 기다린 뒤 기존 태스크를 내린다. **`maximumPercent` 를 100% 로 두면 먼저 멈추고 그 다음에 대체한다.**
  - "How does Amazon ECS handle tasks that are part of a service?" 절과 Health 알림 예시 본문: **minimum healthy percent** 를
    쓰고, 기본값이 100% 이므로 새 태스크를 먼저 띄운다고 적는다.
- `minimumHealthyPercent` 는 실행 중이어야 하는 태스크 수의 **하한**(올림), `maximumPercent` 는 **상한**(내림)이다. 예: 상한 200% 에
  desired 4 면 새 태스크 4개를 먼저 띄울 수 있고, 상한 125% 에 desired 3 이면 결과가 3 이라 하나도 더 띄울 수 없다
  (https://docs.aws.amazon.com/AmazonECS/latest/developerguide/service-event-messages-list.html).
- 대체 태스크를 못 띄우면(IAM 역할, 서브넷 여유, 보안 그룹, 태스크 정의 오류) 기존 태스크는 **대체 없이** 내려간다(task-maintenance 문서
  "Troubleshooting service availability during task retirement").

`hypothesis` — 내림 규칙을 retirement 에 그대로 적용하면 desired 1 에 `maximumPercent` 150% 도 상한이 1 이라 새 태스크를 먼저 띄울 수
없다. 문서는 이 경우를 retirement 로 직접 적지 않았다. 고객 답변에 쓰려면 AWS Support 확인이나 재현이 필요하다.

## 해야 할 것

1. 서비스의 `desiredCount`, `minimumHealthyPercent`, `maximumPercent` **셋을 다** 확인한다. 하나만 보고 답하지 않는다.
2. `desiredCount × maximumPercent`(내림)가 `desiredCount` 보다 큰지 계산한다. 크지 않으면 "새 태스크 먼저" 를 약속하지 않는다.
3. 고객이 `minimumHealthyPercent` 만 말하면 전제를 정정한다 — 하한은 내려가지 않게 막을 뿐이고, 먼저 띄울 자리는 상한이 만든다.
4. 답변에 근거를 붙일 때 문서 안의 두 설명이 다르다는 점을 숨기지 않는다. 기준으로 삼은 문단을 밝힌다.
5. 태스크가 하나뿐이거나 standalone 태스크면 "무중단" 이라고 쓰지 않는다. standalone 은 ECS 가 대체하지 않는다.

## 다시 쓰기 전에 확인할 것

- **task-maintenance 문서의 두 문단이 아직 서로 다른지.** AWS 가 한쪽으로 고치면 이 카드의 설명도 바뀐다.
- 그 서비스의 현재 배포 설정 값(`deploymentConfiguration`)과 `desiredCount`, 스케줄러 종류(REPLICA 인지 DAEMON 인지 — 기본값이 다르다).
- 배포 방식(rolling / blue-green / external) — 문서의 설명은 서비스 스케줄러가 대체하는 경우다.

## 변경 이력

- 2026-10-07: 작성. 승인된 교훈 후보에서 옮겼다. 승인 때 후보의 근거가 지워져, 티켓 쪽 경위는 후보 요약 한 줄에서만 가져왔다.
