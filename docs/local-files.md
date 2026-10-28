# 내 PC 에 저장되는 파일

[← README](../README.md)

> **키 값은 채팅·이슈·PR 에 붙여넣지 마세요.** 이 문서도 파일 이름과 키 이름만 적어요. 값은 하나도 없어요.

키·설정이 어느 파일에 들어가고, 무엇이 그 파일을 쓰고 읽는지 한 곳에 모았어요. 코드를 읽어 적은 사실만 있어요.
코드에서 못 찾은 칸은 **확인 안 됨** 으로 뒀어요. 파일을 하나로 합치는 건 아직 안 정했어요(`development/open-questions.md`).

## 한눈에

| 위치 | 파일 | 종류 | 비밀 |
|---|---|---|---|
| `~/.config/msp/` | `zendesk.conf` | 자격증명 | 예 |
| | `itsm` | 자격증명 | 예 |
| | `credential-broker.conf` | 자격증명 + 설정 | 예 (키 한 줄 때문에) |
| | `msp-site` | 자격증명 (선택) | 예 |
| | `tiket-usage.conf` | 설정 | 아니요 |
| | `tiket-usage-sent`, `tiket-usage-sent-status`, `tiket-freshness`, `tiket-freshness-fetch-failures`, `tiket-zendesk-metrics.json` | 상태·캐시 | 아니요 |
| | `skill-home-copies-<시각>/` | 옛 스킬 사본 보관 | 아니요 |
| `~/.aws/config` | `[profile csg-login]` 줄 | 마커 | 아니요 |
| `~/.cache/msp/` | `sts-token.json` | 로그인 토큰 캐시 | 예 |
| | `customer-creds/` | 고객 계정 임시 자격 캐시 + 기록 | 예 |

## 권한

- `~/.config/msp/` 는 700, 비밀 파일은 600 으로 만들어요. 다만 700 은 **디렉터리를 새로 만드는 쪽**이 걸어요 —
  Zendesk 단계(`onboarding.sh`)와 `skill_setup.py`·`itsm_token.py`(`write_private`)가 그래요.
  사용 지표 단계가 먼저 만들면 700 을 걸지 않아요(`onboarding.sh` 코드상).
- 상태·캐시 파일은 코드가 권한을 정하지 않아요. 그냥 기본 권한이에요.
- `~/.cache/msp/` 자체는 코드가 700 을 걸지 않아요. 그 안의 `customer-creds/` 만 700 이에요.
- Windows 는 권한 비트가 없어요. 코드가 ACL 로 좁히는 건 `zendesk.conf` 하나뿐이에요(`onboarding.ps1`). 나머지는 **확인 안 됨**.

## 비밀이 든 파일

### `~/.config/msp/zendesk.conf`

- **키**: `ZENDESK_SUBDOMAIN`, `ZENDESK_EMAIL`, `ZENDESK_API_TOKEN`
- **만드는 곳**: 온보딩 6단계. 터미널에서 직접 돌릴 때만 물어요. Zendesk 가 200 으로 답했을 때만 저장해요. 권한 600.
- **읽는 곳**: `fetch-ticket.sh`·`.ps1`, `usage_zendesk.py`(지표 계산), `local_capabilities.py`(있는지만), `onboarding.sh` 8단계(상담사 이름 조회).
  환경변수(`ZENDESK_*`)가 있으면 그쪽이 먼저예요.
- **지우면**: 티켓 번호로 못 가져와요. 세션 시작에 "티켓 번호로 가져오기" 가 안 된다고 알려요. 지표의 Zendesk 계산도 `no_credentials` 로 비어요.
- **다시 만들기**: `bash scripts/onboarding.sh` (Windows: `pwsh -File scripts/onboarding.ps1`).
  세 키가 이미 다 있으면 다시 안 물어요. 바꾸려면 파일(또는 그 줄)을 지우고 다시 돌려요.

### `~/.config/msp/itsm`

- **키**: `ITSM_API_TOKEN` (`cops_` 로 시작). `DEV_ITSM_API_TOKEN` 은 `customer_notes.py --dev` 가 읽는 키예요. 누가 넣는지는 **확인 안 됨**.
- **만드는 곳**: 온보딩 7단계(`itsm_token.py`). 터미널에서만 물어요. GET 한 번으로 확인하고 `ITSM_API_TOKEN` 한 줄만 바꿔요. 다른 줄은 그대로 둬요. 권한 600.
- **읽는 곳**: `customer_notes.py`(고객 특이사항), `itsm_ticket.py`(문서 기준), `local_capabilities.py`(있는지만), `itsm_token.py`.
- **지우면**: 고객 특이사항을 못 읽어요. `customer_notes.py` 가 종료 3 으로 "특이사항 미확인" 을 알리고, 계정 조회는 진행해요.
- **다시 만들기**: `bash scripts/onboarding.sh`. 토큰이 이미 있으면 다시 안 물어요.

### `~/.config/msp/credential-broker.conf`

- **키**: `API_URL`, `CLIENT_ID` (공개 값, `skills/aws-customer-account-ops/broker-defaults.conf` 에서 와요), `BILLING_API_KEY` (**비밀**)
- **만드는 곳**: 온보딩 5단계(`skill_setup.py --install`). 권한 600. `BILLING_API_KEY` 는 환경변수에도 파일에도 없을 때만, 터미널에서 물어요.
- **읽는 곳**: `get-sts-token.sh`·`.ps1`(`API_URL`, `CLIENT_ID`), `get-customer-credentials.sh`·`.ps1`(`API_URL`), `billing-api.sh`·`.ps1`(`BILLING_API_KEY`, 환경변수가 먼저).
- **지우면**: Slack 로그인, 고객 AWS 조회, 빌링 플랫폼 조회가 다 안 돼요.
- **다시 만들기**: `bash scripts/onboarding.sh` (스킬만 맞추려면 `python3 scripts/skill_setup.py --install`). 주소·ID 는 자동으로 다시 채워지고, 키는 다시 물어요.

### `~/.config/msp/msp-site` (선택)

- **키**: `MSP_PERSONAL_KEY`
- **만드는 곳**: **사람이 직접**. 온보딩도 다른 스크립트도 이 파일을 만들지 않아요. 사이트의 내 정보 → 개인 API 키에서 발급해 한 줄로 두고 `chmod 600` 해요(`weekly_diary_save.py` 안내문). 권한은 코드가 확인하지 않아요.
- **읽는 곳**: `weekly_diary_save.py` (일기 임시저장). 환경변수 `MSP_PERSONAL_KEY` 가 먼저예요.
- **지우면**: 일기 임시저장만 못 해요. 다른 기능은 그대로예요.

### `~/.cache/msp/sts-token.json`

- **키**: `Version`, `Expiration`, `BrokerVersion`, `SlackAccessToken`, `SlackUserId`. AWS 자격증명은 안 넣어요.
- **만드는 곳**: `get-sts-token.sh`·`.ps1` (Slack 로그인, [`ONBOARDING.md` 5절](../ONBOARDING.md#5-로그인-처음-한-번-브라우저가-열립니다)). 권한 600.
- **읽는 곳**: `get-customer-credentials.sh`·`.ps1`.
- **지우면**: 다음 조회 때 브라우저로 Slack 로그인을 다시 해요.
- **다시 만들기**: `get-sts-token.sh --clear-cache` 가 지우고 바로 다시 로그인해요.

### `~/.cache/msp/customer-creds/`

- **만드는 곳·읽는 곳**: `get-customer-credentials.sh`·`.ps1`. 디렉터리 700.
- `<계정ID>.json` — 고객 계정 임시 자격 캐시. 만들 때 권한 600. `Expiration` 외 필드 이름은 **확인 안 됨**.
  지워도 돼요. 다음 조회 때 다시 받아요. `get-customer-credentials.sh cleanup` 은 만료된 `csg-` 프로필을 `~/.aws/config` 에서 지우고, `cleanup --all` 은 캐시 파일까지 지워요.
- `guard-skips.jsonl`, `migrations.jsonl`, `scope-window.jsonl`, `scope-acks.jsonl`, `.scope.lock` — 기록과 잠금 파일. 이름이 `.jsonl` 인 건 `cleanup` 이 일부러 안 지우게 하려는 거예요.
  **지우지 마세요.** 지우면 한 번만 도는 이전 작업이 다시 돌거나, 짧은 시간에 여러 고객 계정을 부르는 걸 막는 브레이크 기록이 사라져요(코드 주석).

## 설정·상태 파일 (비밀 아님)

### `~/.config/msp/tiket-usage.conf`

- **키**: `TIKET_ENGINEER`(온보딩이 써요). `TIKET_TELEMETRY`, `TIKET_LESSONS`, `TIKET_TELEMETRY_URL` 은 필요할 때 직접 넣어요([무엇이 나가나](data-and-lessons.md)).
- **만드는 곳**: 온보딩 8단계. 터미널에서 이름을 정했을 때만 써요. 권한 600 (`onboarding.sh`). Windows 는 권한을 좁히는 코드가 없어요.
- **읽는 곳**: `report_usage.py`, `report_lessons.py`.
- **지우면**: 이름이 `git user.name` 으로 나가요. `TIKET_TELEMETRY=off` 도 같이 사라져서 **지표가 다시 켜져요.**
- **다시 만들기**: `bash scripts/onboarding.sh`.

### 상태·캐시 — 지워도 돼요

모두 `~/.config/msp/` 에 있고, 지우면 스크립트가 알아서 다시 만들어요.

| 파일 | 들어 있는 것 | 쓰는 곳 → 읽는 곳 | 지우면 |
|---|---|---|---|
| `tiket-usage-sent` | 빈 파일. 수정 시각이 "마지막 전송 시도" | `report_usage.py` → 같은 스크립트 (6시간에 한 번) | 다음 세션 시작에 바로 보내요 |
| `tiket-usage-sent-status` | JSON: `at`, `outcome`, `failures`, `lessons` | `report_usage.py` → 같은 스크립트 (미리보기) | 미리보기에 마지막 전송 기록이 없어요 |
| `tiket-freshness` | 숫자 하나 (초 단위 시각) | `check-freshness.sh`·`.ps1` → 같은 스크립트 (6시간에 한 번) | 다음 호출에 바로 새 버전을 확인해요 |
| `tiket-freshness-fetch-failures` | 숫자 하나 (연속 실패 횟수) | `check-freshness.sh`·`.ps1`. 성공하면 스크립트가 지워요 | 실패 횟수가 0 부터 다시 세요 |
| `tiket-zendesk-metrics.json` | JSON: `date`, `shape`, `payload` (집계 숫자) | `usage_zendesk.py` → 같은 스크립트 (하루 한 번) | 다음 계산 때 Zendesk 를 다시 불러요 |

경로는 환경변수로 바꿀 수 있어요: `TIKET_USAGE_STAMP`, `TIKET_USAGE_CONF`, `TIKET_FRESHNESS_STAMP`, `TIKET_ZENDESK_METRICS`.

### `~/.config/msp/skill-home-copies-<시각>/`

- **만드는 곳**: `skill_migration.py`. 예전에 `$HOME` 에 설치한 스킬 사본을 이 워크스페이스 스킬로 바꿀 때, 옛 사본을 여기로 옮겨 둬요.
- **읽는 곳**: 없어요. 되돌리는 명령을 그때 한 번 알려 줘요.
- **지우면**: 조회에는 영향이 없어요. 옛 사본으로 되돌릴 수는 없게 돼요.

## `~/.aws/config` 의 `[profile csg-login]`

- **들어 있는 것**: `credential_process`(이 워크스페이스의 `get-sts-token.sh` 경로. Windows 는 `pwsh -NoProfile -File "<경로>"`), `region = ap-northeast-2`. 비밀은 없어요.
- **만드는 곳**: 온보딩 5단계(`skill_setup.py --install`). 이 한 줄만 바꾸거나, 섹션이 없으면 끝에 붙여요. 바꾸기 전에 `config.bak.tiket-<시각>` 으로 백업해요.
- **읽는 곳**: AWS CLI, `local_capabilities.py`(스킬 설치 여부), `skill_setup.py`, `skill_migration.py`.
- **지우면**: 세션 시작에 "스킬 미설치" 로 알려요. 워크스페이스 폴더를 옮기거나 지워도 이 경로가 깨져요.
- **다시 만들기**: `bash scripts/onboarding.sh`.
- `csg-login` 말고 `csg-<계정>` 프로필도 `get-customer-credentials.sh` 가 이 파일에 쓰고 정리해요. 쓰는 지점만 확인했고 자세한 동작은 **확인 안 됨**.

## 확인 안 됨

- `DEV_ITSM_API_TOKEN` 을 누가 넣는지
- `customer-creds/<계정ID>.json` 의 필드 이름 (`Expiration` 외)
- Windows 에서 `zendesk.conf` 외 파일의 권한
- `csg-<계정>` 프로필이 만들어지고 지워지는 세부 동작
- `~/.cache/msp/update/last_check` — 이 PC 에 있지만 저장소 코드에서 쓰는 곳을 못 찾았어요
