# 트러블슈팅 가이드

AWS 고객 계정 관리 작업 중 발생할 수 있는 문제와 해결 방법을 정리합니다.

---

## 1. Prerequisites 문제

### `BILLING_API_KEY` 미설정

| 항목 | 내용 |
|------|------|
| **증상** | BILLING API 호출 시 인증 실패 또는 빈 응답 |
| **확인** | env 또는 conf 어느 쪽이든 키가 있으면 OK: `[ -n "$BILLING_API_KEY" ] \|\| grep -q '^BILLING_API_KEY=' ~/.config/msp/credential-broker.conf` (값은 출력하지 마세요) |
| **해결** | `billing-api.sh` 래퍼는 키를 env(`BILLING_API_KEY`) → `~/.config/msp/credential-broker.conf`(`BILLING_API_KEY=` 라인) 순으로 해석합니다. 둘 중 하나에 키를 설정하세요. conf 파일에 추가하는 경우 비밀값이므로 반드시 `chmod 600 ~/.config/msp/credential-broker.conf` |

### `csg-login` marker 프로필 미존재

| 항목 | 내용 |
|------|------|
| **증상** | SKILL_DIR 경로 탐색 실패 / `The config profile (csg-login) could not be found` |
| **확인** | `aws configure get profile.csg-login.credential_process 2>/dev/null` |
| **해결** | 설치 관리자(`install.sh`/`install.ps1`) 재실행으로 csg-login marker 생성. login-only `get-sts-token`을 가리키는 경로 탐색 전용 앵커(AWS 자격증명 없음) |

### `aws`/`jq`/`curl`/`python3` 미설치

| 항목 | 내용 |
|------|------|
| **증상** | `오류: 'aws'이(가) 설치되어 있지 않습니다.` |
| **확인** | `which aws jq curl python3` |
| **해결** | 각 도구 설치: `aws` — AWS CLI v2, `jq` — JSON 처리기, `curl` — 브로커 HTTP 호출, `python3` — 로그인 스크립트 |

---

## 2. BILLING API 문제

### 401 Unauthorized

| 항목 | 내용 |
|------|------|
| **증상** | HTTP 401 Unauthorized 응답 |
| **원인** | API 키 만료 또는 잘못된 형식 |
| **해결** | 빌링 플랫폼 콘솔에서 API 키 재발급 후, `billing-api.sh`가 읽는 위치(env `BILLING_API_KEY` 또는 `~/.config/msp/credential-broker.conf` 의 `BILLING_API_KEY=` 라인)를 갱신. conf 파일은 비밀값이므로 `chmod 600` 유지 |

### 빈 body 반환

| 항목 | 내용 |
|------|------|
| **증상** | 응답의 `body`가 빈 배열 `[]` |
| **원인** | 검색어 불일치 — 대소문자 또는 정확한 이름 불일치 |
| **해결** | 검색어 확인 — API 응답 구조: `{header: {code, message}, body: [...]}` |

### `deleteFlag: "1"` 계정

| 항목 | 내용 |
|------|------|
| **증상** | 조회된 계정이 이미 삭제된 계정 |
| **원인** | BILLING API는 삭제된 계정도 반환함 |
| **해결** | `deleteFlag === "0"` 조건으로 필터링하여 제외 |

---

## 3. AWS Assume Role 문제

### `AccessDenied`

| 항목 | 내용 |
|------|------|
| **증상** | `An error occurred (AccessDenied) when calling the AssumeRole operation` |
| **원인** | 대상 계정에 `cross_account_role_name`에 해당하는 IAM 역할 미생성 또는 trust policy 문제 |
| **해결** | 대상 계정의 IAM 역할 존재 여부 및 trust policy 확인 — 소스 계정이 trusted entity에 포함되어야 함 |

### `ExpiredToken`

**로그인 세션 만료:**

| 항목 | 내용 |
|------|------|
| **증상** | `An error occurred (ExpiredTokenException) when calling the ... operation` |
| **원인** | Slack 로그인(Bearer) 세션 만료 |
| **해결** | `get-sts-token.sh --clear-cache` 실행 후 재로그인. 이후 고객사 프로필 명령이 브로커에서 새 세션을 발급받음 |

**고객사 AssumeRole 세션 만료 (1시간):**

| 항목 | 내용 |
|------|------|
| **증상** | `An error occurred (ExpiredTokenException) when calling the ... operation` |
| **원인** | Role chaining 제약으로 고객사 세션 최대 수명 1시간 |
| **해결** | 래퍼(`get-customer-credentials.sh`)가 자동 재발급. 동일 명령 재실행하면 됨 |

### 고객사 프로필이 ReadOnly 제약 없이 동작 (구버전 프로필)

| 항목 | 내용 |
|------|------|
| **증상** | 고객사 프로필로 쓰기 명령이 실행됨 / 서버측 ReadOnly 세션 정책이 적용되지 않음 |
| **원인** | `source_profile`/`role_arn` 방식으로 직접 설정된 구버전 프로필 — 브로커 `credential_process`를 거치지 않아 서버측 ReadOnly 강제가 무력화됨 |
| **확인** | `aws configure get profile.<프로필명>.credential_process` — 결과에 `get-customer-credentials`가 포함되어야 정상. 없으면 구버전 |
| **해결** | SKILL.md Step 2 절차에 따라 `--account-id`-only 형태로 프로필 재생성 |

### AccessDenied — 읽기 명령인데도 거부됨

| 항목 | 내용 |
|------|------|
| **증상** | Describe/Get/List 명령인데 `AccessDenied` 발생 |
| **원인** | 고객사 역할의 trust policy가 올바르지 않거나, ReadOnlyAccess 세션 정책과 역할 정책 교집합이 비어 있음 |
| **확인** | `aws sts get-caller-identity --profile <프로필명>`으로 AssumeRole 자체가 성공하는지 먼저 확인 |
| **해결** | 고객사 IAM 역할의 trust policy 및 권한 정책 재확인. 역할에 최소 ReadOnlyAccess 이상 부여 필요 |

### 프로필이 사라졌다 / `The config profile (...) could not be found`

| 항목 | 내용 |
|------|------|
| **증상** | 어제까지 쓰던 프로필명이 `The config profile (example-dev) could not be found` 로 거부됨. `aws configure list-profiles` 에도 그 이름이 없음 |
| **원인** | 일회성 마이그레이션이 구 이름 CSG 프로필을 `csg-` 네임스페이스로 재작성했습니다(`example-dev` → `csg-example-dev`). 구 섹션은 삭제되므로 구 이름은 더 이상 존재하지 않습니다. 마이그레이션은 `credential_process` 서브프로세스 안에서 자동 실행되고 **구명→새명 매핑표를 stderr 로만** 출력하기 때문에, 에이전트가 그 출력을 삼켰다면 이름이 바뀐 사실 자체를 놓쳤을 수 있습니다 |
| **확인** | `aws configure list-profiles \| grep '^csg-'` — 새 이름이 여기 있습니다. 마이그레이션 요약을 다시 보려면 `get-customer-credentials.sh migrate` 를 직접 실행하세요(이미 끝났으면 "대상 없음"으로 조용히 끝납니다) |
| **해결** | 새 `csg-` 이름을 그대로 쓰면 됩니다. 이름을 모르겠으면 `register` 를 같은 인자로 다시 호출하세요 — 멱등하게 갱신하고 최종 프로필명을 stdout 1줄로 알려줍니다. **shell 의 `AWS_PROFILE` 환경변수가 구 이름을 가리키고 있으면 반드시 갱신하세요** — `AWS_PROFILE` 은 프로필을 명시하지 않은 모든 AWS CLI 호출에 적용되므로, 구 이름이 남아 있으면 `--profile` 을 안 준 명령이 전부 같은 에러로 실패합니다. `~/.zshrc`/`~/.bashrc` 등에 export 해 두었다면 거기까지 고쳐야 새 셸에서도 재발하지 않습니다 |

### SSO 프로필이 이상하다 / CSG 키가 섞여 있다

| 항목 | 내용 |
|------|------|
| **증상** | 본인의 SSO(또는 정적 키) 프로필이 갑자기 고객사 세션처럼 동작하거나, `[guard] 외래 키 섹션 건너뜀: <프로필명>` 경고가 보임 |
| **원인** | 한 섹션 안에 엔지니어 본인의 credential 키와 CSG 가 쓴 키(`credential_process`, `csg_managed`)가 함께 있는 **오염된 하이브리드** 상태입니다. 과거 버전이 남긴 흔적이거나 수동 `aws configure set` 으로 CSG 키를 덧쓴 결과입니다. 이 상태에서 CSG 로직은 남의 프로필을 건드리지 않으려고 해당 섹션을 건너뛰므로, 정상 동작도 복구도 되지 않습니다 |
| **확인** | `get-customer-credentials.sh doctor` — 오염된 섹션을 열거해 보여줍니다. 아무것도 지우지 않고 먼저 보고만 하므로 안전하게 돌려볼 수 있습니다 |
| **해결** | `get-customer-credentials.sh doctor` 로 복구하세요. doctor 는 오염된 섹션에서 **`csg_managed` 와 `credential_process` 두 키만** 제거하고 본인의 SSO/정적 키는 그대로 둡니다. 복구 후 SSO 프로필이면 `aws sso login --profile <프로필명>` 으로 다시 로그인하면 정상 동작합니다. 그 계정을 CSG 로도 쓰려면 doctor 이후 `register` 를 호출해 `csg-` 네임스페이스에 **별도 프로필**로 만드세요 |

---

## 4. Slack 인증 문제

> `csg-login` marker 프로필은 Slack OAuth 기반 login-only `credential_process`(`get-sts-token`)를 사용합니다.

### 설정 파일 없음

| 항목 | 내용 |
|------|------|
| **증상** | `오류: 설정 파일을 찾을 수 없습니다` |
| **확인** | `test -f ~/.config/msp/credential-broker.conf && echo "설정 파일 존재" || echo "설정 파일 없음"` |
| **해결** | 관리자에게 Slack OAuth 설정 안내를 요청하여 파일 생성 |

### 브라우저가 열리지 않음

| 항목 | 내용 |
|------|------|
| **증상** | `get-sts-token.sh` 실행 시 브라우저가 열리지 않음 |
| **원인** | SSH/원격 환경 또는 `xdg-open`/`open` 미설치 |
| **해결** | `get-sts-token.sh --no-browser` 옵션으로 실행 후 출력된 URL을 직접 브라우저에 입력 |

### 인증 시간 초과

| 항목 | 내용 |
|------|------|
| **증상** | `오류: 인증 시간 초과` |
| **원인** | 제한 시간 내에 Slack 로그인을 완료하지 못함 (기본 120초, `--no-browser` 모드는 300초) |
| **해결** | 재실행 후 빠르게 Slack 로그인 진행 |

### 도메인 검증 실패

| 항목 | 내용 |
|------|------|
| **증상** | API 응답 403: `Slack workspace not authorized.` |
| **원인** | Slack team ID(`T192GUYE7`)가 일치하지 않음 — MSP 회사 워크스페이스가 아닌 다른 Slack 계정으로 로그인 (검증 기준은 도메인이 아니라 team ID) |
| **해결** | 회사 Slack 워크스페이스(`msp`)의 계정으로 로그인 |

### 이메일 검증 실패

| 항목 | 내용 |
|------|------|
| **증상** | API 응답 403: `Slack email domain not authorized.` |
| **원인** | Slack 프로필의 이메일이 `@msp.example.com`이 아님 |
| **해결** | Slack 프로필 설정에서 이메일 주소 확인 — 회사 이메일 사용 필요 |

### 포트 9876 사용 중

| 항목 | 내용 |
|------|------|
| **증상** | `오류: 로컬 인증 서버를 시작하지 못했습니다. 포트 9876 사용 여부를 확인해주세요.` |
| **원인** | 다른 프로세스가 포트 9876을 사용 중 |
| **확인** | `lsof -i :9876` (Linux/macOS) |
| **해결** | 해당 프로세스 종료 후 재시도 |

### 캐시된 토큰 문제

| 항목 | 내용 |
|------|------|
| **증상** | 인증은 성공하지만 AWS CLI에서 계속 `ExpiredToken` 에러 |
| **원인** | 캐시 파일 손상 또는 시스템 시간 불일치 |
| **해결** | `get-sts-token.sh --clear-cache` 실행 후 재인증 |

### `InvalidExternalId` / external-id 관련 AccessDenied

| 항목 | 내용 |
|------|------|
| **증상** | `An error occurred (AccessDenied)` + external ID 관련 메시지 |
| **원인** | external-id는 이제 **브로커가 서버측에서** 관리합니다. 브로커 백엔드 등록 값과 대상 계정 신뢰 정책이 불일치할 때 발생 |
| **해결** | 클라이언트에서 조치 불가 — 관리자에게 대상 계정의 external-id/신뢰 정책 확인 요청 |

---

## 5. 브로커 자격증명 발급 문제 (get-customer-credentials)

> 역할 이름·external-id·assume 타입 해석과 `AssumeRole`(+ReadOnlyAccess 부착)은 이제 **브로커가 서버측에서** 수행합니다. 과거 클라이언트의 `get_account_info` 빌링 플랫폼 계정/KMS 조회 경로는 폐기되었습니다(파일은 유지되나 워크플로우에서 호출하지 않음 — 최종 정리는 Phase 20). 실패는 브로커 HTTP 응답으로 표면화됩니다.

### 403 인가 거부

| 항목 | 내용 |
|------|------|
| **증상** | `get-customer-credentials` 호출이 403 + `{ "error": ... }` 로 실패 |
| **원인** | Bearer(로그인 토큰) 누락/만료, 또는 open-proxy/신원 가드에 의한 거부 |
| **해결** | 먼저 `get-sts-token.sh`로 로그인해 Bearer 확보. 그래도 거부되면 stderr의 서버 메시지를 사용자에게 그대로 전달 |

### 400 잘못된 요청

| 항목 | 내용 |
|------|------|
| **증상** | 400 + `{ "error": ... }` |
| **원인** | `--account-id`가 12자리 형식이 아니거나 브로커가 계정을 해석하지 못함 |
| **해결** | 계정 ID(12자리) 재확인. BILLING로 계정을 다시 식별 |

### 대상 계정 역할/신뢰 정책 문제

| 항목 | 내용 |
|------|------|
| **증상** | 브로커가 `AssumeRole` 단계에서 실패 (AccessDenied) |
| **원인** | 브로커가 서버측에서 해석한 cross-account 역할이 대상 계정에 없거나 신뢰 정책이 잘못됨 |
| **해결** | 관리자에게 대상 계정의 cross-account 역할/신뢰 정책 확인 요청 |

### 다계정 fan-out 브레이크 거부

| 항목 | 내용 |
|------|------|
| **증상** | 호출이 exit 1 로 끝나고 stdout 은 비어 있으며, stderr 거부 블록의 첫 줄이 `[scope] reason=fan-out-threshold` |
| **원인** | 300초 윈도우 안에서 승인되지 않은 서로 다른 계정 **6개째의 신규 발급**을 시도. 캐시 적중은 세지 않으며, 이미 윈도우에 들어 있는 계정을 다시 발급받아도 카운트가 늘지 않음 |
| **해결** | SKILL.md **Step 1.5** 로 돌아가 대상 계정을 열거하고 사용자 승인을 받은 뒤 `scope-ack --account-ids <id,id,...>`(12자리 계정 2개 이상)를 실행하고 재시도. 거부 메시지의 **마지막 stderr 줄이 이미 그대로 붙여 쓸 수 있는 재시도 명령** |

이것은 마찰과 기록이지 강제 차단이 아닙니다 — 클라이언트 측 임계값이므로 실제 fan-out 은 브로커의 서버측 감사에서 따로 관찰됩니다.

---

## 6. AWS Agent Toolkit 활용

고급 트러블슈팅 시 [AWS Agent Toolkit](https://github.com/aws/agent-toolkit-for-aws)을 활용할 수 있습니다.

AWS Agent Toolkit은 AWS 공식 문서 검색, 읽기 전용 AWS API 호출, 리전별 서비스 가용성 확인 등의 기능을 제공합니다. 설치 및 사용법은 [aws/agent-toolkit-for-aws](https://github.com/aws/agent-toolkit-for-aws)를 참고하세요.

### 활용 시나리오

- **에러 코드 해석**: AccessDenied, AssumeRole 관련 오류 원인을 AWS 공식 문서에서 검색
- **서비스 제한 확인**: STS, IAM 서비스 쿼터 및 제한 조회
- **Best practice 조회**: IAM cross-account access, S3 퍼블릭 접근 차단 등 모범 사례 참조
- **리전별 서비스 확인**: 특정 리전에서 서비스/API 가용성 확인

---

## 7. 보안 아키텍처 참고사항

### 서버측 고객 AssumeRole + 엔지니어별 신원 각인 (v1.6)

v1.6부터 고객사 접근은 브로커가 **서버측**에서 수행하는 고객 `AssumeRole`입니다. 브로커는 OAuth 검증된 Slack 신원으로 `RoleSessionName=msp-ai@{slackUserId}`(및 지원 시 `SourceIdentity`)를 **서버에서 각인**하고 `ReadOnlyAccess`를 세션 정책으로 부착한 read-only 고객 세션만 발급합니다. 따라서 각 고객 세션은 **엔지니어별로 CloudTrail에서 개별 식별 가능**합니다 (이 프로젝트의 Core Value).

| 항목 | 내용 |
|------|------|
| **구조** | 브로커가 `POST /v1/customer-credentials`에서 crossaccount IAM User 자격증명으로 고객 역할을 서버측 AssumeRole → `ReadOnlyAccess` 세션정책 부착 → read-only 고객 세션만 반환 (`lib/customer-assume.mjs`) |
| **감사 추적** | ✅ **개별 식별 가능** — 각 세션의 `RoleSessionName`에 Slack User ID가 서버 각인되어 CloudTrail에서 엔지니어별로 구분됨 (지원 role은 `SourceIdentity`도 각인). 사용한 에이전트는 세션명에 들어가지 않고 브로커 사내 감사 로그(`event: audit`의 `agent` 필드)에만 남음 |
| **읽기 전용** | 브로커가 세션 정책으로 `ReadOnlyAccess`를 서버측 부착 — 클라이언트가 privileged 크레덴셜을 쥐지 않으므로 우회 불가 (IAM API 차원 차단) |
| **인증** | Slack OAuth로 인증된 엔지니어(워크스페이스 + `@msp.example.com` 도메인 검증)만 세션 발급 가능, 브로커 로그에 emailHash/Slack ID 기록 |
| **참고 (로그인 레그)** | 로그인용 `POST /v1/credentials`는 ROL-03 이후 **identity-only** 응답만 반환함 (Slack Bearer + SlackUserId + 합성 Expiration) — `GetSessionToken`이나 crossaccount AWS 세션은 더 이상 반환되지 않으며 exec-role의 `sts:GetSessionToken` 권한도 제거됨 (마지막 우회 경로 폐쇄). 실제 고객 접근은 위의 서버측 AssumeRole 경로가 담당 |
