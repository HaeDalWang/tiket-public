# AWS CLI 프로필 생성 레퍼런스

고객 AWS 계정 접근을 위한 CLI 프로필 생성 절차.

## 기본(Base) 프로필 구조

| 프로필명 | 용도 | 계정 |
|----------|------|------|
| `csg-login` | SKILL_DIR 경로 탐색 전용 앵커 (login-only, AWS 자격증명 없음) | — |

- `csg-login`: `credential_process`가 login-only `get-sts-token`을 가리키는 **비특권 marker**입니다. Slack OAuth로 Bearer(로그인 토큰)만 발급하며 AWS 세션 자격증명을 담지 않습니다. SKILL.md/레퍼런스의 SKILL_DIR 탐색 앵커로만 사용하고 **직접 자격증명 소스로 쓰지 마세요.**
- 이 marker는 설치 관리자(`install.sh`/`install.ps1`)가 자동 생성합니다. 과거의 `source_profile`/`role_arn` 기반 특권 base 프로필은 더 이상 사용하지 않으며, 마이그레이션이 이를 삭제합니다 (역할/external-id/타입 해석은 브로커가 서버측에서 수행).

### csg-login marker 프로필 설정

> **이 섹션만 예외입니다.** `csg-login` 은 고객사 프로필이 아니라 **설치 관리자 영역의 marker** 이므로 아래처럼 `aws configure set` 으로 직접 설정합니다. **고객사 프로필은 절대 이렇게 만들지 않습니다** — 아래 [프로필 생성](#프로필-생성-assume_role_type-무관-단일-형태) 의 `register` 서브커맨드만 사용하세요.

설치 관리자가 자동 등록하지만, 수동 설정이 필요하면 `credential_process`를 login-only `get-sts-token`으로 지정합니다:

> `<SKILL_INSTALL_PATH>`는 설치한 에이전트에 따라 다릅니다. `./install.sh` 실행 후 출력 확인.

**Linux / macOS:**
```bash
aws configure set profile.csg-login.credential_process <SKILL_INSTALL_PATH>/get-sts-token.sh
aws configure set profile.csg-login.region ap-northeast-2
```

**Windows (PowerShell):**
```powershell
aws configure set profile.csg-login.credential_process "pwsh -NoProfile -File <SKILL_INSTALL_PATH>\get-sts-token.ps1"
aws configure set profile.csg-login.region ap-northeast-2
```

사전 설정 필요:
1. Slack App 설정 완료 — 관리자에게 문의
2. 설정 파일 생성 — `~/.config/msp/credential-broker.conf`

## 프로필 이름 규칙

**이 규칙을 손으로 적용할 일은 없습니다.** 프로필 이름은 `register` 가 `--account-name` 원문에서 직접 계산하며, 규칙의 구현체는 스크립트 안의 정규화 함수 **한 곳**뿐입니다. 아래 설명은 결과를 예측하기 위한 것이지 실행하기 위한 것이 아닙니다. `register` 에는 `--profile-name` 플래그가 의도적으로 없습니다.

**규칙** (순서대로 적용):

1. 소문자로 변환한다
2. `[a-z0-9-]` 이외의 모든 문자를 하이픈으로 바꾼다
3. 연속된 하이픈을 하나로 축약한다
4. 앞뒤의 하이픈을 제거한다
5. **마지막에 `csg-` 접두사를 붙인다** — 이 프로젝트가 만드는 모든 프로필은 `csg-` 네임스페이스 안에 있습니다

**예시**:
- `My Company` → `csg-my-company`
- `Test_Account (Dev)` → `csg-test-account-dev`
- `csg-my-company` → `csg-my-company` (접두사는 한 번만 — 아래 참고)

접두사는 **멱등**입니다: 정규화 결과에 이미 `csg-` 가 하나 있으면 그것을 벗겨낸 뒤 다시 붙이므로 `csg-csg-…` 가 생기지 않습니다. 그래서 충돌 시 `register` 가 stderr 로 제시하는 `csg-{회사명}-{계정명}` 대체명을 **그대로 `--account-name` 에 다시 넣어도** 안전합니다.

정규화 결과가 `^[a-z0-9][a-z0-9-]{0,63}$` 를 만족하지 않으면(예: 한글만으로 이루어진 계정명) `register` 는 `reason=invalid-account-name` 으로 중단합니다. 이 단언은 **접두사를 붙이기 전의 토큰**을 대상으로 합니다 — 최종 `csg-<토큰>` 을 검사하면 빈 토큰이 `csg-` 만으로도 "`[a-z0-9]` 로 시작"을 만족해 `[profile csg-]` 라는 쓰레기 섹션이 통과해 버리기 때문입니다.

**예약 프로필명**: 정규화+접두사 결과가 인프라 예약 이름(`default`, `crossaccount-user`, `crossaccount-role`, `msp-homepage`, `msp-internal`, **`csg-login`**)과 같으면 `register` 는 `reason=reserved-profile-name` 으로 **아무것도 쓰지 않고** 중단합니다. `csg-login` 이 목록에 있는 이유는 네임스페이스 도입으로 `--account-name "Login"` 이 SKILL_DIR 탐색 앵커와 정확히 같은 이름으로 파생될 수 있게 되었기 때문입니다 — 앵커를 고객사 프로필로 덮으면 에이전트가 스크립트 위치를 잃습니다.

**이름 충돌 시**: `csg-{회사명}-{계정명}` 형식을 사용합니다. 이 대체명은 직접 조립하지 말고 `register` 가 중단 메시지에 제시한 값을 그대로 쓰세요 — 재시도 명령까지 실행 가능한 형태로 함께 출력됩니다(대체명은 `--account-name` 으로 전달합니다). `--corp-name` 을 주지 않으면 회사명이 빠진 `csg-{계정명}` 이 제안됩니다.

## 기존 프로필 확인

**별도로 확인하지 않습니다.** `register` 가 `aws configure list-profiles` 로 프로필 전체를 열거해 중복을 판정하므로, 호출 전에 무언가를 조회할 필요가 없습니다.

이 방식이 중요한 이유:

- `aws configure list-profiles` 는 `~/.aws/config` 와 `~/.aws/credentials` 를 **모두** 열거합니다. 따라서 `credential_process` 키가 없는 **SSO 전용 프로필**과 `~/.aws/credentials` 에만 존재하는 **정적 키 프로필**까지 보입니다. 특정 키 하나를 `aws configure get` 으로 찔러보는 방식은 이 두 부류를 "없는 프로필"로 오판합니다 — 그 위에 덮어쓰면 남의 프로필이 사라집니다.
- 열거 자체가 실패하면(설정 파일 파싱 오류 등 exit 255) `register` 는 "없음"으로 간주하지 않고 **아무것도 쓰지 않은 채 중단**합니다(fail-closed). 이때 `reason=config-unparseable` 과 함께 원인 후보, 최근 백업 파일, 복구용 `cp` 명령이 출력됩니다.

구버전 프로필은 `role_arn` 키만 있고 `credential_process`가 없을 수 있습니다(서버측 ReadOnly 강제 미적용). 이 경우 같은 계정으로 `register` 를 다시 호출해 **재등록**하면 됩니다 — CSG 소유로 판정되는 프로필은 멱등하게 갱신됩니다.

## 프로필 생성 (assume_role_type 무관, 단일 형태)

역할 이름(`cross_account_role_name`)·external-id·assume 타입은 이제 **브로커가 서버측에서 해석**합니다. 클라이언트는 조회하지 않으며(get_account_info 빌링 플랫폼 계정/KMS 조회 폐기), 프로필에는 **계정 ID만** 전달합니다.

> **🔒 read-only 서버측 강제**: 모든 고객사 프로필은 `get-customer-credentials.sh`(또는 `.ps1`) `credential_process`로 등록합니다. 브로커가 `AssumeRole` 시 `ReadOnlyAccess`를 **서버에서** 부착하므로, 고객사 역할에 AdministratorAccess가 부여되어 있어도 세션은 ReadOnlyAccess로 제한됩니다 (서버측 session policy 강제 — AWS API 차원 차단). 클라이언트는 더 이상 `--policy-arns`를 붙이지 않습니다.
>
> ⚠️ 세션 최대 수명은 **1시간**입니다. 만료 시 래퍼가 캐시 갱신을 위해 자동 재발급합니다.

고객사 프로필은 `get-customer-credentials.{sh,ps1}` 의 **`register` 서브커맨드 단일 호출**로 생성합니다. `region`/`output`/`credential_process` 를 개별적으로 설정하지 않습니다 — register 가 소유권 marker 를 먼저 쓰고 `credential_process` 를 마지막에 쓰는 순서까지 보장합니다(중간에 실패해도 자격증명이 해석되는 미소유 프로필이 남지 않습니다).

### Linux/macOS

```bash
SKILL_DIR=$(dirname "$(aws configure get profile.csg-login.credential_process 2>/dev/null)")

# 성공 시 stdout 1줄이 생성된 프로필명이므로 그대로 변수로 받습니다.
PROFILE_NAME=$("$SKILL_DIR/get-customer-credentials.sh" register --account-id <ACCOUNT_ID> --account-name "Example-Dev" --corp-name "Example Corp")
```

### Windows

```powershell
$SkillDir = Split-Path (aws configure get profile.csg-login.credential_process 2>$null) -Parent

# 성공 시 stdout 1줄이 생성된 프로필명이므로 그대로 변수로 받습니다.
$ProfileName = pwsh -NoProfile -File "$SkillDir\get-customer-credentials.ps1" register --account-id <ACCOUNT_ID> --account-name "Example-Dev" --corp-name "Example Corp"
```

`SKILL_DIR` 산출은 **스크립트 위치를 찾기 위한 것**입니다. 프로필에 기록되는 `credential_process` 문자열은 register 가 자기 실행 경로에서 직접 만들기 때문에, `csg-login` marker 가 없어 `SKILL_DIR` 이 비어도 상대 경로가 config 에 구워지지 않고 "파일을 찾을 수 없음"으로 즉시 실패합니다.

### 호출 결과

| 결과 | exit | stdout | stderr |
|------|------|--------|--------|
| 성공(신규 생성 또는 갱신) | 0 | 프로필명 **정확히 1줄** | 진행 상황 |
| 중단 | 1 | **완전히 빈 값** | 첫 줄이 `[register] reason=<토큰>` |

중단은 **쓰기 전 중단**과 **쓰기 중/후 중단** 두 부류이며, `~/.aws/config` 상태가 다릅니다. 어느 쪽이든 stdout 은 완전히 비어 있습니다.

| 부류 | 해당 토큰 | `~/.aws/config` |
|------|-----------|-----------------|
| **쓰기 전 중단** | `foreign-profile`, `account-mismatch`, `contaminated-hybrid`, `unknown-profile`, `reserved-profile-name`, `config-unparseable`, `invalid-account-id`, `invalid-account-name`, `invalid-arguments` | **한 바이트도 변경되지 않음** |
| **쓰기 중/후 중단** | `write-failed`, `postcondition-failed` | **변경됨** — 부분 기록된(또는 검증되지 않은) 섹션이 남아 있음 |

`write-failed` / `postcondition-failed` 를 만나면 "아무것도 바뀌지 않았습니다" 라고 보고하면 **안 됩니다**. 마커(`csg_managed`)를 먼저 쓰기 때문에 부분 기록된 섹션은 credential 해석에 관여하지 않으며 CSG 소유로 판정되므로, 원인을 해결한 뒤 **같은 명령을 다시 실행하면 멱등 재등록 경로로 수렴**합니다.

주요 `reason` 토큰:

| 토큰 | 의미 |
|------|------|
| `foreign-profile` | 같은 이름이 이미 남의 프로필(SSO·정적 키·role chaining 등)로 존재 |
| `account-mismatch` | 같은 이름이 CSG 소유이지만 **다른 계정 ID** 에 묶여 있음 |
| `contaminated-hybrid` | CSG 소유 프로필에 외부 자격증명 키가 섞여 있음 (수동 정리 필요) |
| `unknown-profile` | 소유 근거도 외부 키도 없는 프로필이 이미 존재 (보수적 거부) |
| `reserved-profile-name` | 정규화 결과가 인프라 예약 프로필명(`default`, `crossaccount-user`, `crossaccount-role`, `msp-homepage`, `msp-internal`, `csg-login`) — 등록하면 cleanup 이 회수할 수 없고, `default` 는 무지정 CLI 호출 전체를 고객사 세션으로 바꾸며, `csg-login` 은 SKILL_DIR 탐색 앵커를 덮어 에이전트가 스크립트를 찾지 못하게 함 |
| `config-unparseable` | 설정 파일 열거 실패 — 복구용 `cp` 명령이 함께 출력됨. 단, 열거 이후 분류 단계에서 발생한 경우는 **프로필이 조회 도중 사라졌을 가능성**을 함께 안내하고 복구 명령을 출력하지 않음(재실행이 정답) |
| `invalid-account-id` / `invalid-account-name` / `invalid-arguments` | 인자 오류 |
| `write-failed` | `aws configure set` 이 실패 — **여기서부터는 config 가 변경된 상태**. 재실행하면 멱등 재등록으로 수렴 |
| `postcondition-failed` | 4개 키를 모두 쓴 뒤 되읽기 검증 실패 — **config 는 변경된 상태**. 재실행하면 멱등 재등록으로 수렴 |

충돌 계열(`foreign-profile`/`account-mismatch`/`unknown-profile`/`reserved-profile-name`)은 register 가 제안한 `csg-` 대체명으로 재시도하세요. `aws configure set` 으로 기존 프로필을 덮어쓰는 우회는 금지입니다.

## 기존 프로필 마이그레이션

본 스킬 이전 버전에서 생성된 프로필(`source_profile` + `role_arn` 방식, 또는 구버전 인자 형태)은 브로커를 거치지 않아 서버측 ReadOnly 강제가 적용되지 않습니다. 설치 관리자(`install.sh`/`install.ps1`)가 업그레이드 시 이런 특권/구버전 프로필을 자동 삭제합니다.

**전체 프로필을 훑는 일괄 마이그레이션은 `migrate` 서브커맨드가 담당합니다** (Phase 23 에서 출시). 지금 개별 프로필을 고쳐야 한다면 해당 계정으로 위 `register` 를 다시 호출하세요 — CSG 소유로 판정되면 멱등하게 갱신되고, 충돌로 중단되면 그 프로필은 CSG 소유가 아니라는 뜻이므로 덮어쓰지 말고 stderr 안내를 따르세요.

## 프로필 검증

`register` 자체는 네트워크 검증을 하지 않고 로컬 설정만 다룹니다. 생성 후 실제 동작을 확인하려면:

```bash
aws sts get-caller-identity --profile {name}
```

성공 시 `UserId`, `Account`, `Arn` 반환. 반환된 `Arn` 이 `arn:aws:sts::{accountId}:assumed-role/.../csg-*` 형태여야 정상입니다 — 브로커를 거쳐 발급된 세션이라는 뜻입니다.

## 변수 설명

| 변수 | 설명 |
|------|------|
| `{name}` | 프로필 이름 (이름 규칙 참조) |
| `{accountId}` | 고객 AWS 계정 12자리 ID |

> 역할 이름(`cross_account_role_name`)·external-id·assume 타입·에이전트 식별은 브로커가 서버측에서 해석/각인하므로 프로필 생성 시 전달하지 않습니다.

## 주의사항

- `~/.aws/config` 파일을 직접 편집하지 말 것 — 고객사 프로필은 반드시 `get-customer-credentials.{sh,ps1} register` 사용. 프로필에 대한 직접 `aws configure set` 도 같은 이유로 금지 (파일을 손으로 여느냐 CLI 로 여느냐의 차이일 뿐, 충돌 검사를 건너뛴다는 결과는 동일). 예외는 설치 관리자 영역인 `csg-login` marker 뿐
- 자격증명(credentials)을 코드나 문서에 포함하지 말 것
- **모든 고객사 프로필은 `credential_process`(`get-customer-credentials`)로만 등록** — 직접 `source_profile`/`role_arn`으로 등록하면 브로커를 우회해 서버측 ReadOnly 강제가 무력화됨
- 고객사 프로필에는 **계정 ID만** 전달 — 역할 이름/external-id/assume 타입은 브로커가 서버측에서 해석 (클라이언트 하드코딩 금지)
- 세션 1시간 제약은 AWS 강제 사항 (우회 불가) — 장시간 작업은 분할
