---
observed:
  - 2026-10-22 | ticket 100024
sources:
  - 2026-10-26 | aws-doc | https://docs.aws.amazon.com/elasticloadbalancing/latest/network/load-balancer-cloudwatch-metrics.html | 표기 없음
  - 2026-10-22 | account-observation | `TCP_Target_Reset_Count` 를 `TargetGroup` 차원으로 조회 — 데이터 0건, 5분 집계 하루치에서 대부분 구간이 0 보다 큼 | 해당 없음
review_by: 2027-04-20
---

# NLB `TCP_Target_Reset_Count` 가 튄 것을 특정 타깃그룹·특정 요청 실패의 원인으로 읽으면 틀린다 — 이 지표는 NLB 전체 합이고 평시에도 0 이 아니다

## 무엇을 하면 틀리는가

- 장애 시각 근처의 좁은 창에서 `TCP_Target_Reset_Count` 가 0 에서 올라간 것을 보고 "이 타깃(서비스)이 연결을 끊었다 = 원인" 으로 결론낸다.
- 타깃그룹별로 보려고 `TargetGroup` 차원으로 조회하고, 데이터가 없으니 "리셋 없음" 으로 읽는다.

## 실제로 있었던 일

- 2026-10-22: API Gateway → VPC Link → NLB → ECS 경로의 간헐 500 을 조사했다. 좁은 창에서 평시 0 을 확인하고 리셋 증가를 원인으로 넘어갔다가,
  하루 단위로 보니 평시에도 대부분 구간이 0 이 아니고, 리셋이 수백 건인 구간에 해당 API 의 500 이 0 건인 반례가 나왔다. 같은 NLB 에 타깃그룹이 여러 개 붙어 있었다.

## 확인된 사실

- `TCP_Target_Reset_Count`(타깃이 클라이언트로 보낸 RST)의 차원은 `LoadBalancer` 와 `AvailabilityZone`+`LoadBalancer` 뿐이다. `TargetGroup` 차원이 없다
  — `ActiveFlowCount`·`NewFlowCount`·`HealthyHostCount` 는 `TargetGroup` 차원이 있는 것과 다르다. CloudWatch 는 발행되지 않은 차원 조합으로는 통계를 돌려주지 않는다
  (https://docs.aws.amazon.com/elasticloadbalancing/latest/network/load-balancer-cloudwatch-metrics.html).
- 그래서 이 값은 그 NLB 에 붙은 모든 타깃그룹의 합이다. 2026-10-22 조회에서 `TargetGroup` 차원은 0 건이었다(account-observation).

## 해야 할 것

1. 이 지표로 원인을 말하기 전에 같은 NLB 에 붙은 타깃그룹 수를 센다(`aws elbv2 describe-target-groups --load-balancer-arn`).
2. 평시 기준선은 좁은 창이 아니라 하루 이상 5분 집계로 본다. 리셋이 많은데 실패가 없는 구간(반례)이 있는지도 본다.
3. 특정 서비스가 끊었다고 말하려면 그 타깃 쪽 근거(애플리케이션·컨테이너 로그, 배포 이벤트, 타깃그룹 차원이 있는 지표)를 따로 댄다.

## 다시 쓰기 전에 확인할 것

- NLB 지표 문서의 `TCP_Target_Reset_Count` 차원 목록이 그대로인지.

## 변경 이력

- 2026-10-26: 작성. 교훈 후보에서 옮겼다.
