# EC2 인스턴스 목록 조회

> 사용자 요청: "MSP 회사 EC2 인스턴스 조회해줘"

## 시나리오

고객사 "MSP 회사"의 EC2 인스턴스 목록을 조회하는 전체 흐름.

---

## Step 1 — 고객사 식별

회사명 "MSP 회사"로 BILLING API 검색 (`billing-api.sh` 래퍼가 API 키를 env 또는 conf에서 해석):

```bash
SKILL_DIR=$(dirname "$(aws configure get profile.csg-login.credential_process 2>/dev/null)")

"$SKILL_DIR/billing-api.sh" GET "/api/admin/v1/companies" \
  | jq '.body[] | select(.corpName | test("MSP 회사"; "i")) | {corpId, corpName}'
```

응답 예시:
```json
{
  "corpId": "00000000-0000-0000-0000-00000000000a",
  "corpName": "MSP 회사"
}
```

## Step 2 — 계정 조회

corpId로 해당 회사의 AWS 계정 목록 조회:

```bash
"$SKILL_DIR/billing-api.sh" GET "/api/admin/v1/companies/00000000-0000-0000-0000-00000000000a/accounts" \
  | jq '.body[] | select(.deleteFlag == "0") | {accountName, accountId}'
```

응답 예시:
```json
{
  "accountName": "Example-Dev",
  "accountId": "<ACCOUNT_ID>"
}
```

## Step 3 — 프로필 생성

Step 2에서 얻은 12자리 `accountId`와 `accountName` **원문**을 `register` 서브커맨드에 그대로 넘긴다. 프로필명은 register 가 정하므로 에이전트가 계산하지 않고, 프로필에 대해 `aws configure set` 을 직접 실행하지 않는다. 역할 이름·external-id·assume 타입은 **브로커가 서버측에서 해석**하므로 클라이언트는 조회하거나 지정하지 않는다:

```bash
SKILL_DIR=$(dirname "$(aws configure get profile.csg-login.credential_process 2>/dev/null)")

# 성공 시 stdout 1줄이 생성된 프로필명이므로 그대로 변수로 받는다.
PROFILE_NAME=$("$SKILL_DIR/get-customer-credentials.sh" register --account-id <ACCOUNT_ID> --account-name "Example-Dev" --corp-name "MSP 회사")
```

> `SKILL_DIR` 은 register 를 **호출할 경로**를 찾기 위한 것이며, 프로필에 구워지는 `credential_process` 문자열은 register 가 자기 실행 경로에서 직접 만든다. 그래서 marker 가 없어 `SKILL_DIR` 이 비면 상대 경로가 config 에 구워지는 대신 "파일을 찾을 수 없음"으로 즉시 실패한다.
>
> 중단(exit 1)되면 stdout 은 비어 있고 `~/.aws/config` 는 **한 바이트도 변경되지 않은** 상태다. stderr 첫 줄의 `[register] reason=<토큰>` 을 그대로 보고하고, register 가 출력한 대체 이름으로 재시도한다.

> 🔒 read-only(`ReadOnlyAccess`)는 브로커가 `AssumeRole` 시 **서버측에서 부착**한다 — 클라이언트는 `--policy-arns`를 붙이지 않으며 프로필에는 계정 ID만 전달한다. 고객사 역할에 AdministratorAccess가 부여되어 있어도 세션은 IAM 차원에서 ReadOnlyAccess로 차단된다.

설정 확인:
```bash
aws configure list --profile ${PROFILE_NAME}
```

## Step 4 — EC2 인스턴스 조회

```bash
aws ec2 describe-instances --profile ${PROFILE_NAME} \
  --query 'Reservations[*].Instances[*].[InstanceId,State.Name,InstanceType,Tags[?Key==`Name`].Value|[0]]' \
  --output table
```

## Step 5 — 결과 해석

출력 예시:
```
--------------------------------------------------------------------
|                        DescribeInstances                         |
+----------------------+-----------+--------------+----------------+
|  i-0a1b2c3d4e5f67890 |  running  |  t3.medium   |  web-server-1  |
|  i-0f9e8d7c6b5a43210 |  stopped  |  t3.large    |  batch-worker  |
|  i-0abcdef1234567890  |  running  |  m5.xlarge   |  api-server    |
+----------------------+-----------+--------------+----------------+
```

| 컬럼 | 설명 |
|------|------|
| InstanceId | 인스턴스 고유 ID |
| State.Name | 실행 상태 (`running`, `stopped` 등) |
| InstanceType | 인스턴스 유형 |
| Name 태그 | 인스턴스 이름 |

## 추가 조회 명령어

```bash
# 인스턴스 상태 확인
aws ec2 describe-instance-status --profile ${PROFILE_NAME}

# CloudWatch CPU 사용률 (최근 1시간, 5분 간격)
aws cloudwatch get-metric-statistics --profile ${PROFILE_NAME} \
  --namespace AWS/EC2 \
  --metric-name CPUUtilization \
  --dimensions Name=InstanceId,Value=i-0a1b2c3d4e5f67890 \
  --start-time $(date -u -v-1H +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Average
```

> ⚠️ 모든 명령은 **읽기 전용**(Describe, Get, List)만 허용됩니다. 리소스 변경 명령은 실행하지 마세요.
