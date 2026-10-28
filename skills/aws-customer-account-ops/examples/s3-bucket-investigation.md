# S3 버킷 퍼블릭 접근 확인

> 사용자 요청: "예시의료 S3 버킷 중 퍼블릭 접근 가능한 것 확인해줘"

## 시나리오

고객사 "예시의료"의 S3 버킷 퍼블릭 접근 상태를 점검하는 전체 흐름.

---

## Step 1 — 고객사 식별

계정명 "democo"으로 BILLING API 검색 (`billing-api.sh` 래퍼가 API 키를 env 또는 conf에서 해석):

```bash
SKILL_DIR=$(dirname "$(aws configure get profile.csg-login.credential_process 2>/dev/null)")

"$SKILL_DIR/billing-api.sh" GET "/api/admin/v1/accounts" \
  | jq '.body[] | select(.accountName | test("democo"; "i")) | {accountId, accountName, corpId, corpName}'
```

응답 예시:
```json
{
  "accountId": "<ACCOUNT_ID_2>",
  "accountName": "DemoCo-Prod",
  "corpId": "00000000-0000-0000-0000-00000000000a",
  "corpName": "예시의료"
}
```

## Step 2 — 프로필 생성

Step 1에서 얻은 12자리 `accountId`와 `accountName` **원문**을 `register` 서브커맨드에 그대로 넘긴다. 프로필명은 register 가 정하므로 에이전트가 계산하지 않고, 프로필에 대해 `aws configure set` 을 직접 실행하지 않는다. 역할 이름·external-id·assume 타입은 **브로커가 서버측에서 해석**하므로 클라이언트는 조회하거나 지정하지 않는다:

```bash
SKILL_DIR=$(dirname "$(aws configure get profile.csg-login.credential_process 2>/dev/null)")

# 성공 시 stdout 1줄이 생성된 프로필명이므로 그대로 변수로 받는다.
PROFILE_NAME=$("$SKILL_DIR/get-customer-credentials.sh" register --account-id <ACCOUNT_ID_2> --account-name "DemoCo-Prod" --corp-name "예시의료")
```

> `SKILL_DIR` 은 register 를 **호출할 경로**를 찾기 위한 것이며, 프로필에 구워지는 `credential_process` 문자열은 register 가 자기 실행 경로에서 직접 만든다. 그래서 marker 가 없어 `SKILL_DIR` 이 비면 상대 경로가 config 에 구워지는 대신 "파일을 찾을 수 없음"으로 즉시 실패한다.
>
> 중단(exit 1)되면 stdout 은 비어 있고 `~/.aws/config` 는 **한 바이트도 변경되지 않은** 상태다. stderr 첫 줄의 `[register] reason=<토큰>` 을 그대로 보고하고, register 가 출력한 대체 이름으로 재시도한다.

> 🔒 read-only(`ReadOnlyAccess`)는 브로커가 `AssumeRole` 시 **서버측에서 부착**한다 — 클라이언트는 `--policy-arns`를 붙이지 않으며 프로필에는 계정 ID만 전달한다. 고객사 역할에 AdministratorAccess가 부여되어 있어도 세션은 IAM 차원에서 ReadOnlyAccess로 차단된다.

## Step 3 — S3 퍼블릭 접근 조사

```bash
# 버킷 목록 조회
aws s3api list-buckets --profile ${PROFILE_NAME} --output json

# 각 버킷의 퍼블릭 접근 차단 설정 확인
aws s3api get-public-access-block --bucket democo-user-uploads --profile ${PROFILE_NAME}

# 버킷 정책의 퍼블릭 여부 확인
aws s3api get-bucket-policy-status --bucket democo-user-uploads --profile ${PROFILE_NAME}
```

출력 예시 (퍼블릭 접근 차단 설정):
```json
{
  "PublicAccessBlockConfiguration": {
    "BlockPublicAcls": true,
    "IgnorePublicAcls": true,
    "BlockPublicPolicy": false,
    "RestrictPublicBuckets": false
  }
}
```

## Step 4 — AWS Agent Toolkit 활용

퍼블릭 접근 관련 AWS 모범 사례를 참조할 때 [AWS Agent Toolkit](https://github.com/aws/agent-toolkit-for-aws)을 활용하면 AWS 공식 문서를 즉시 검색하고 읽기 전용 API를 직접 호출할 수 있습니다.

예시: S3 퍼블릭 접근 차단 베스트 프랙티스, 관련 IAM 정책 문서 등을 Agent가 직접 조회하여 정확한 근거와 함께 결과를 제공합니다.

> 트러블슈팅이나 설정 해석이 필요할 때 AWS Agent Toolkit을 활용하면 정확한 AWS 공식 문서를 즉시 참조할 수 있다.

## Step 5 — 결과 해석 및 보고

분석 기준:

| 설정 | 의미 | 위험도 |
|------|------|--------|
| `BlockPublicAcls: false` | 퍼블릭 ACL 추가 가능 | ⚠️ 주의 |
| `BlockPublicPolicy: false` | 퍼블릭 정책 설정 가능 | ⚠️ 주의 |
| `IsPublic: true` (정책 상태) | 버킷 정책이 퍼블릭 | 🔴 위험 |
| 4개 설정 모두 `true` | 퍼블릭 접근 완전 차단 | ✅ 안전 |

보고 예시:

> 예시의료 계정(<ACCOUNT_ID_2>)에 총 5개 S3 버킷이 있습니다.
> - `democo-user-uploads`: BlockPublicPolicy, RestrictPublicBuckets가 false — **퍼블릭 정책 설정 가능 상태**
> - 나머지 4개 버킷: 퍼블릭 접근 차단 설정 완료 (안전)
>
> `democo-user-uploads` 버킷의 퍼블릭 접근 차단 설정 활성화를 권장합니다.

> ⚠️ 모든 명령은 **읽기 전용**(List, Get, Describe)만 허용됩니다. 버킷 정책 변경, 삭제 등 수정 명령은 실행하지 마세요.
