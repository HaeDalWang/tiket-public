---
source_id: SRC-FTR-STD-001
source_type: de-identified-internal-document-excerpt
channel: "FTR-PLS 2.0 제출 문서 셋에서 뽑음 — AWS Root User Management(ARC), IAM Best Practices(IAM) 의 IAM-001~005 해당 부분, CloudTrail Best Practices(CTL)"
captured_at: 2026-10-08 KST
source_owner_role: The MSP (documents submitted to AWS for the Partner-Led Support FTR)
source_link: local only — policy/raw/FTR-PLS 2.0/MSP-FTR-{ARC,IAM,CTL}.docx (gitignored)
reported_by: repository owner
authority_basis: The repository owner supplied the folder on 2026-10-08 and stated it is the document actually defined between the MSP and AWS, with a clear source, and in force
---

# Root, IAM, CloudTrail standards (ARC · IAM · CTL) — 비식별 source excerpt

Text extracted from the document bodies: the statements of the standards only. Left out: console and CLI walkthroughs, policy and
template code, Config and SCP samples, screenshots, the Main Payer's own settings, and the encryption and Secrets Manager chapters
(IAM-006·007, no card). ARC-004 repeats the incident section of ARC-001 word for word and is given once. Mail addresses are replaced
by `<메일>`; the AWS sender domains named in the password-reset steps are public and kept. Heading marks are the documents' heading levels.

## ARC-001 — ROOT 계정 운영 표준, 사고 대응 (본문 그대로)

[Heading1] ARC-001
[Heading2] ROOT 계정 운영 표준
Account당 한 개씩 구성되는 ROOT 계정은 최상위 권한 계정으로 최소권한 원칙 적용이 불가하고 대체할 수 없어 일반적인 용도로는 미사용해야 하며 보안을 강화하여 침해사고 등의 영향을 최소화해야 합니다.
[Heading3] ROOT계정에 대한 기본적인 권장 설정
아래 항목들에 대한 설정을 적용해야 합니다.
ROOT 사용 상황 외 작업에 ROOT 사용 금지
ROOT 사용자 액세스 키 삭제 및 생성하지 않음
다중 인증(MFA)를 통한 ROOT 보호
강력한 비밀번호 정책 사용 : 최소 8자, 계정이름, 이메일과 동일하지 않도록 설정
ROOT계정에 연동되는 Account의 등록 정보는 회사 그룹의 공용 이메일, 전화번호를 사용하여 담당자 1인에게 종속되지 않도록 설정
[Heading3] ROOT 사용 상황
아래 상황에서는 ROOT의 권한이 필요하기에 해당 작업에 대해서는 ROOT를 사용할 수 있습니다.
계정 설정을 변경합니다. 여기에는 계정 이름, 이메일 주소, 루트 사용자 암호 및 루트 사용자 액세스 키가 포함됩니다. 연락처 정보, 결제 통화 기본 설정 및 AWS 리전 등의 기타 계정 설정에는 루트 사용자 보안 인증이 필요하지 않습니다.
IAM 사용자 권한을 복원합니다. IAM 관리자가 실수로 권한을 취소하면 루트 사용자로 로그인하여 정책을 편집하고 해당 권한을 복원할 수 있습니다.
AWS 계정을 닫습니다(삭제합니다).
멀티 팩터 인증(MFA)을 활성화하도록 Amazon S3 버킷을 구성합니다.
모든 보안 주체를 거부하는 Amazon Simple Queue Service(Amazon SQS) 리소스 정책을 편집하거나 삭제합니다.
모든 보안 주체를 거부하는 Amazon Simple Storage Service(S3) 버킷 정책을 편집하거나 삭제합니다.
AWS GovCloud (US)에 가입합니다.
AWS Support에서 AWS GovCloud (US) 계정 루트 사용자 액세스 키를 요청합니다.
AWS Key Management Service 키를 관리할 수 없게 되는 경우 루트 사용자로 AWS Support에 문의하여 키를 복구할 수 있습니다.
예약 인스턴스 마켓 플레이스에 판매자로 등록합니다.
아래 작업에서도 ROOT 권한이 필요하지만 MSP 회사의 Main Payer에 소속된 일반 고객이거나 비용 관련 정책은 MSP 회사 빌링 플랫폼을 고객에게 제공하고 일반 작업 권한은 제공하지 않도록 합니다. 따라서 비용관련 작업은 MSP 회사에서만 사용합니다.
과금 정보 및 비용 관리 콘솔에 대한 IAM 액세스를 활성화합니다.
특정 세금 계산서를 조회합니다. aws-portal:ViewBilling 권한이 있는 IAM 사용자는 AWS 유럽(AWS Inc. 또는 Amazon Internet Services Private Limited(AISPL) 제외)에서 VAT 인보이스를 보고 다운로드할 수 있습니다.
[Heading3] ROOT 계정 사고 대응
ROOT 계정은 정의된 사용상황을 제외하고는 사용을 금지합니다.
허가되지 않은 ROOT 계정의 사용에 대하여 Cloudwatch Logs를 통한 지표 생성, GuardDuty를 통한 로그인 시도 탐지 등으로 모니터링이 가능합니다.
이하 내용은 허가되지 않은 로그인 시도, 계정 분실 상황 등에 대한 시나리오별 대응 방안입니다.
내부 대응 및 고객 가이드라인에 활용합니다.
고객 가이드 진행 시 진행 과정에서 파트너사 MSP 회사의 지원을 받을 수 있음을 가이드합니다.
미허가 ROOT 로그인 시도 탐지
미허가 로그인 시도 발생 시 자격증명이 유출된 것으로 판단합니다. 사용중인 자격증명은 변경절차를 수행합니다.
인지 즉시 아래 항목들을 수행합니다.
ROOT 액세스키 삭제
ROOT IAM 비밀번호 변경
MFA 교체
CSG그룹 리더(고객 환경인 경우 고객 담당자)에게 보고
ROOT 이메일 액세스 불가
분실된 ROOT 이메일이 사내 도메인에 포함된 메일인 경우
사내 이메일 도메인을 컨트롤 가능한 경우 ROOT에 등록된 이메일을 대상으로 복구용의 다른 이메일 주소로 이메일을 리디렉션 합니다.
이후 암호 변경에 대한 아래 절차를 수행합니다.
ROOT 비밀번호 재설정
AWS Management Console에서 비밀번호 찾기 링크를 통해 비밀번호 재설정이 가능합니다.
AWS 계정에 등록된 ROOT 이메일주소와 액세스 권한이 필요합니다. 비밀번호 재설정 링크는 해당 이메일로 전송 됩니다.
상세 작업 순서
Console에서 로그아웃 된 상태에서 AWS Management Console 로그인 창으로 이동합니다.
ROOT 사용자 이메일 주소를 사용하여 로그인을 시작합니다.
Forgot password? 링크를 사용하여 비밀번호 복구 페이지로 이동합니다.
보안문자 등 절차를 완료하고 send email 버튼을 클릭합니다.
ROOT의 이메일에 액세스하여 AWS에서 @signin.aws 혹은 @verify.signin.aws 주소를 통해 전송한 이메일을 확인합니다.
이메일의 링크를 통해 ROOT 사용자 비밀번호를 재설정 합니다.
계정 복구 시도 실패시
계정 복구를 위한 비밀번호 변경, 이메일 복구 등 작업에 실패할 경우 AWS에 지원 요청을 보내야 합니다.
아래 링크를 통하여 지원 센터에 계정 이슈에 대한 직접적인 지원을 요청할 수 있습니다.
로그인 지원 링크 : Amazon Web Services 계정 지원
MFA 분실
MFA 분실 상황에서 ROOT 계정에 연결된 이메일 및 기본 연락처에 액세스 가능한 상황이라면 해당 방법을 통해 복구를 시도할 수 있습니다.
상세 작업 순서
루트 사용자를 선택하고 AWS 계정이메일 주소를 입력하여 AWS Management Console에 계정 소유자로 로그인합니다.
추가 확인 필요(Additional verification required) 페이지에서 인증할 MFA 방법을 선택하고 다음(Next)을 선택합니다.
추가 확인 필요(Additional verification required) 페이지 또는 복수 단계 인증(Multi-factor authentication) 페이지에서 MFA 문제 해결(Troubleshoot MFA)을 선택합니다.
필요할 경우 암호를 다시 입력하고 로그인을 선택합니다.
디바이스 인증 문제 해결(Troubleshoot your authentication device) 페이지에 있는 대체 인증 팩터를 사용하여 로그인(Sign In Using Alternative Factors of Authentication) 섹션에서 대체 팩터를 사용하여 로그인(Sign in using alternative factors)을 선택합니다.
대체 인증 팩터를 사용하여 로그인(Sign In Using Alternative Factors of Authentication) 페이지에서 이메일 주소를 확인하여 계정을 인증하고 확인 이메일 보내기(Send verification email)를 선택합니다.
AWS 계정과 연결된 이메일에서 Amazon Web Services(<메일>)의 메시지를 확인합니다. 이메일 지침을 따릅니다.
계정에 이메일이 없는 경우에는 스팸 폴더를 확인하거나 브라우저로 돌아가 이메일 재전송(Resend the email)을 선택합니다.
지금 전화하기(Call me now)를 선택합니다. AWS 전화를 받고, 요구에 따라 AWS 웹사이트의 6자리 숫자를 전화 키패드에 입력합니다.
전화 번호를 확인한 후에는 콘솔에 로그인(Sign in to the console)을 선택하여 계정에 로그인할 수 있습니다.
기존에 사용하던 키는 분실되었으니 제거가 필요합니다.
가상 MFA 디바이스의 경우, 디바이스에서 계정을 제거합니다. 그런 다음 AWS 보안 자격 증명 페이지로 이동하여 기존 MFA 가상 디바이스 엔터티를 삭제한 다음 새 엔터티를 생성합니다.
보안 키의 경우, AWS 보안 인증 페이지로 이동하여 기존 FIDO 보안 키를 비활성화한 다음 새 키를 활성화합니다.
하드웨어 TOTP 토큰의 경우, 타사 제공업체에 연락해 디바이스 수리 또는 교체를 위한 도움을 받으세요. 새 디바이스를 받기 전까지 다른 인증 요소를 사용하여 계속 로그인할 수 있습니다. 하드웨어 MFA 디바이스를 새로 받은 후에는 AWS 보안 자격 증명 페이지로 이동하여 기존 MFA 디바이스를 삭제합니다.
해당 방법을 사용할 수 없는 경우 AWS의 지원요청이 필요합니다. 아래 링크를 통하여 직접 지원을 요청합니다.
MFA 분실 지원 링크  : Amazon Web Services MFA 지원

## ARC-002 ~ ARC-004 (ARC-001 과 겹치지 않는 부분)

[Heading1] ARC-002
MFA 강제화를 위한 SCP 룰을 기본 표준으로 하고 있습니다. 더해서 SCP 적용 불가한 main payer 등 관리시에는 config 규칙을 통하여 mfa 설정 여부를 지속적으로 모니터링하고 있습니다.
[Heading2] ROOT의 물리 OTP 사용 현황
콘솔화면, 실제 MFA 키 사진
[Heading2] MFA 강제화 정책
2. 추가 보안 SCP Rule
보안 강화를 위하여 고객환경에 맞추어 아래 SCP를 추가 권고 합니다.
MFAOnly
API나 역할은 MFA가 설정되지 않으면 동작하지 않습니다. AWS의 자체 동작은 예외로 합니다.
[Heading2] Accesskey 관리 표준
Accesskey는 관리자의 CLI 방식을 통한 관리활동 및 자동화된 프로그래밍 방식 API동작에 활용되며 잦은 해킹 위협에 노출되는 대상이 됩니다.
자동화된 작업은 운영에 도움이 되나 그만큼 탈취 시 피해 수준도 높아질 수 있습니다.
기본적으로 아래와 같은 원칙을 이행해야 합니다.
장기 액세스키 발급/사용 하지 않음
ROOT에는 액세스키 사용을 금지
장기 액세스키 대신 IAM 역할 사용
액세스키를 코드에 직접 포함하지 않음(하드코딩 금지)
공용 액세스키 사용 금지
정기적으로 액세스키를 교체하고 미사용 액세스키 삭제
일반 사용자용 액세스키에 MFA 적용
Admin 권한 사용을 금지하고 최소 권한 원칙 적용
액세스키 사용상황은 대부분의 경우 임시 자격증명으로 대체할 수 있는 상황입니다.
기본적으로 장기 액세스키를 사용해서는 안되며 아래의 경우에 담당자 판단과 고객협의를 거쳐 진행할 수 있습니다.
IAM 역할을 부여하는 용도만을 보유한 IAM 장기 액세스키 사용
장기 액세스키 발급은 하였으나 Secrets Manager 등으로 보안성을 강화하는 경우
사람이 아닌 시스템에서 사용하는 개인정보, 신용정보를 처리하지 않는 READ 관련 권한 사용
3rd 툴 사용 시 필요에 의해 액세스 키를 부여해야 될 경우
Local 개발 환경에서 액세스 키를 사용해야 하는 경우
위 절차를 거쳐 장기 액세스키를 발급했을 경우 아래와 같은 관리 요건을 필수적으로 적용하도록 해야 합니다.
해당 액세스키의 중요도가 높다고 판단될 경우에는 Cloudtrail이 연동된 Cloudwatch Logs에 별도 로그 지표를 필터링하여 관리자에게 작업 알람이 발생하도록 설정하여 보안 및 관리 방안을 강화
접근 시 IP를 체크하여 허용된 IP에서만 작업 가능하도록 권한 설정
최소 권한의 원칙으로 불필요하게 권한이 많이 부여되지 않도록 하고 Admin권한은 절대 금지
사람이 사용하는 액세스키일 경우 MFA 설정
Config 규칙에서 Root 액세스키가 없음을 확인하는 캡쳐
ROOT 사용자가 액세스 키를 사용하지 않음
[Heading1] ARC-004
ROOT 사고에 대한 내부 대응 방법을 명시 했습니다. 이는 자격증명 교체 등 일반적인 상황 뿐만 아니라 AWS에 지원 요청 등에 이르는 런북 형태로 구성됩니다.
[Heading2] Root사용자의 비허가 로그인 관리
Amazon GuardDuty의 설정을 통해 Root접근에 대해 탐지하며 EventBridge를 트리거로 사용하여 SNS로 내부 보안 담당자가 수신하도록 설정되어있다.

## IAM — 자격 증명 관리, IAM 사용자 관리, IAM 관리 표준, MFA, 최소 권한 (표준 문장만)

[20] 자격 증명 관리 방안
자격증명 관리에 있어서 아래 항목을 표준으로 하여 업무를 진행해야 합니다.
사람(관리자) 사용 시 다단계 인증(MFA) 적용
개인 전용 자격 증명 활용(공용 자격 증명 금지 원칙)
그룹화 하여 관리
최소 권한 원칙 적용
분기(90일) 단위의 주기적인 권한 관리
임시 자격 증명(IAM 역할 등 권한 수명을 보유)을 사용
비밀 번호 사용 시 최소 8자리 이상, 세 가지 종류 이상의 문자 구성의 복잡성을 부여
유출 시 ENDUSER 피해가 발생하는 자격증명의 모니터링 시스템 설정
[20] IAM 사용자 관리
IAM 사용자는 보안 인증 정보로 고유한 장기 자격 증명을 갖고 있습니다. 보안 인증 정보 유출 시 심각한 보안 피해가 발생할 수 있으므로 보안 침해 사고 예방 및 피해 최소화를 위해 아래 모범 사례를 적용해야 합니다.
사용자는 IAM 사용자 계정을 공용으로 사용하지 않고 개별적인 전용 자격 증명을 사용해야 합니다.
주기적으로 미사용 자격 증명을 추적하고 제거해야 합니다.
IAM 사용자 자격 증명은 AWS Management Console 액세스의 ID/PW와 API에 대한 프로그래밍 방식 액세스의 AccessKey로 구분할 수 있습니다.ID/PASSWORD는 최소 8자 이상, 세 가지 종류 이상의 문자 구성의 강력한 비밀번호 정책을 적용해야 합니다. (참고 : KISA 패스워드 선택 및 이용 안내서)또한 암호 만료 기간 설정을 통해 주기적으로 패스워드 및 AccessKey 교체가 수행되어야 합니다.
[20] IAM 관리 표준
IAM은 AWS의 API 활동 전반에 대한 권한을 관리하며, 그에 따라 관리자의 자격증명 및 AWS 리소스의 권한제어, 보호 활동 전반을 다룹니다.
침해 발생 시 피해가 크게 발생할 수 있으나 관리가 미비한 고객이 다수 있기에 아래 몇 가지 원칙을 항상 기본적으로 강조하여 이행해야 합니다.
ROOT 및 IAM 사용자는 다단계 인증(MFA) 적용
IAM 사용자는 개인 전용 자격 증명 활용(공용 자격 증명 금지 원칙)
IAM사용자는 그룹화해서 관리
최소 권한 적용 및 분기 단위를 표준으로 하는 주기적인 권한 관리
임시 자격 증명(IAM 역할)을 사용
상세 내용은 이하 하위 목차를 기준으로 하여 고객 환경에 따라 적용해야 합니다.
[3] MFA 설정 표준
MFA는 ROOT 사용자와 IAM 사용자(User)에게 할당하여 인증 시 추가적인 보안이 적용될 수 있도록 구성할 수 있습니다. ROOT 사용자의 경우 해당 계정이 AWS Organizations 서비스에서 제공하는 계정 생성 메뉴를 통해 생성한 것이 아니라면 해당 계정을 생성한 ROOT 사용자에 의해 MFA가 설정되어야 합니다. 그리고, 특정 계정 내의 IAM 사용자에 대해서는 IAM의 관리 권한을 가진 IAM Administrator가 MFA의 사용을 강제하여 해당 계정 내의 모든 IAM 사용자 혹은 특정 IAM 사용자가 인증 시 MFA를 적용하도록 구성할 수 있습니다.
[MFA 방식]
IAM에서 지원하는 방식을 전체 사용하며 대표적인 MFA 유형은 아래와 같습니다.
가상 인증 애플레케이션 방식
하드웨어 TOTP 토큰(하드웨어 MFA 디바이스)
하드웨어 보안 키
[MFA 관리 방안]
하드웨어 디바이스, 하드웨어 보안 키
하드웨어 방식의 MFA를 사용하는 경우 잠금 장치가 구비된 저장 장소와 사용을 위한 승인절차가 필요합니다.
보관 장소
잠금 장치가 구비된 금고 형식을 사용하며 MSP 회사 경영지원실에 요청하여 금고를 사용합니다.
사용 승인 프로세스
요청자는 CSG그룹 보안담당자에게 Email로 사전 요청을 진행합니다.
보안담당자는 CSG 리더에게 Email로 최종 승인을 요청합니다.
보안담당자는 승인 이후 사용 전, 후 사용 관리대장을 작성합니다.
[20] MFA 강제화 정책
보안 강화를 위하여 고객환경에 맞추어 아래 SCP를 추가 권고 합니다.
MFAOnly
API나 역할은 MFA가 설정되지 않으면 동작하지 않습니다. AWS의 자체 동작은 예외로 합니다.
[20] 최소 권한 표준화
[3] 권한 분리 적용
IAM 사용자에게 직접 권한을 부여할 경우 부서 변경, 퇴직 등 인사 이동에 대한 적절한 통제 장치가 마련되어야 합니다. 권한 관리의 효율성과 편의를 위해 그룹에 권한을 할당하고 권한이 필요한 IAM 사용자를 해당 그룹에 연결하는 작업을 수행해야 합니다.
그룹에 정책 연결 시 AdministratorAccess는 AWS에 대한 모든 권한을 포함하고 있기 때문에 사용을 금지해야 합니다. 사용자 또는 그룹이 업무를 수행하는데 필요한 작업, AWS 서비스에 따라 권한을 부여해야 하며 와일드카드(*) 설정을 피하는 것이 중요합니다. 권한 부여 시 다음 권한 분리 모범 사례(표 1)을 참고하여 적용해야 합니다.
[20] Multi Account 구조에서의 최소 권한 표준
[3] Payer Account와 동일한 권한 적용 제한
Payer Account에 AWSAdministratorAccess 및 AWSOrganizationFullAccess 권한을 설정하면 SSO 관리 계정은 자신을 포함한 사용자 및 그룹에 AWSAdministratorAccess 및 AWSOrganizationFullAccess 권한 적용이 제한됩니다.(제한전에 이미 AWSAdministratorAccess를 부여한적이 있는 경우 권한이 회수되거나 중단되지 않으므로 수동 권한제거 必 )
[20] 메인 Payer 권한 설정
MSP 회사의 경우, 메인 Payer Account에 대부분의 일반 고객이 링크 되어 있습니다. 해당 계정은 핵심 계정으로 매우 높은 중요도를 가지며 빌링 플랫폼 가동 등 필수 기능 운영 업무를 제외하면 일반 계정은 최대한 사용하지 않습니다.

## CTL — CloudTrail 설정 표준 (표준 문장만)

[20] Cloudtrail 설정 표준
[3] CloudTrail 보안 모범 사례
CloudTrail은 자체 보안 정책을 개발하고 개발하고 구현할 때 고려해야 할 여러 보안 기능을 제공합니다. CloudTrail을 활용하여 AWS 계정에 대한 활동을 추적하고 로그를 모니터링하여 책임 추적성 확보 및 보안 침해 사고를 예방할 수 있습니다. 따라서 추적 대상을 선정하고 로그를 안전하게 관리할 수 있도록 설정하는 것이 중요합니다.
이하 본 문서의 목차에 포함된 내용에 따라 적용해야 하며 개요는 아래와 같습니다.
멀티 리전 추적 생성
멀티 Account 중앙 집중화 추적 생성
무결성 옵션 설정하여 생성
관련 모니터링 기능 활성
추적 로그 저장 시 암호화
로그 대상 최소 권한 액세스 설정
로그 삭제 시 MFA 삭제
[3] CloudTrail 추적
CloudTrail 관리 이벤트는 기본적으로 90일간의 이벤트 기록 정보를 제공합니다. 따라서 지속으로 모든 이벤트 유형이 포함된 기록을 얻기 위해 추적 생성을 활성화해야 합니다.  추적 생성의 경우 로그에 대한 위/변조 방지 방안과 모니터링에 대해 모범 사례를 적용하는 것이 중요합니다.
[4] CloudTrail 계정(멀티 리전) 추적
CloudTrail을 통해 AWS에서의 API 활동을 추적하여 보안 피해를 탐지하고 예방할 수 있습니다. CloudTrail은 기본적으로 90일간의 이벤트 기록 정보만 제공하므로 90일 이후 이벤트에 대해서 별도의 로깅 구성을 해야 합니다. 따라서 S3버킷에 이벤트 로깅를 구성하는 CloudTrail 추적 생성이 필요합니다.
[20] 중앙 집중화 로깅
CloudTrail 로그에 대한 중앙 집중화 로깅 구현되어야 하며 이를 통해 엄격한 보안 제어, 액세스 및 업무 분리를 시행할 수 있습니다. 주요 구성 안은 아래와 같습니다.
별도의 AWS 계정을 로그 아카이브 계정으로 생성하고 CloudTrail 추적 생성을 통해 모든 AWS 계정에 대한 데이터를 로깅
AWS Organizations 환경에서는 조직 추적을 생성하여 로그 아카이브 계정으로 로그 중앙 집중화
신뢰할 수 있는 관리자만 로그 아카이브 계정에 대해 계정 및 감사 데이터에 액세스 허용
[20] 저장 로그 암호화
S3 버킷은 기본적으로 새 객체 업로드를 위해 Amazon S3 관리형 키(SSE-S3)를 사용한 서버 측 암호화를 자동으로 활성화합니다. CloudTrail 로그 암호화 적용 시 S3 관리형 키(SSE-S3)보다 AWS KMS(SSE-KMS)를 사용하여 서버 측 암호화를 수행해야 됩니다. 이때 AWS KMS에서 제공하는 고객 관리형 키(CMK)를 사용 및 관리를 통해 암호화 관련 규정 준수 요구 사항을 충족시키는 것이 중요합니다.
[20] 최소 권한 액세스 구현
CloudTrail 이벤트 로그 파일의 무결성과 안전성을 위해 반드시 권한을 가진 사용자만 액세스 가능하도록 구성해야 합니다. 따라서 로그 파일을 저장하는 모든 버킷에 대한 S3버킷 정책을 검토하고 필요한 경우 조정하여 불필요한 액세스를 차단하는 것이 중요합니다.
아래 내용을 적용해야 합니다.
CloudTrail 이벤트 로그 저장 버킷에 대하여 특정 사용자 액세스 지정
[20] 저장 로그 MFA 삭제 활성화
로그 저장 버킷을 삭제하려는 경우 멀티 팩터 인증(MFA)를 구성하여 추가 인증을 요구할 수 있습니다. 계정 활동 감사 로그 등 보안 침해에 대한 로그에 대해 추가적인 보호 조치를 적용해야 합니다. 이러한 로그에 대해 MFA를 적용하여 Amazon S3 객체를 영구 삭제할 권한을 가진 사용자 외 임의의 사용자로부터 로그 파일을 손상시키거나 삭제할 수 있는 행위를 방지할 수 있습니다.
S3 객체 삭제에 대한 MFA 활성화
[20] 객체 수명 주기 관리
CloudTrail 추적의 기본값은 Amazon S3 버킷에 로그를 무기한 저장하는 것입니다. Amazon S3 객체 수명 주기 관리 규칙을 사용하여 비즈니스 및 감사 필요에 더 적합하게 자체 보존 정책을 정의할 수 있습니다. 이를 통해 일정 기간이 지난 로그에 대하여 삭제를 수행하거나 Amazon Glacier에 아카이빙 구성할 수 있습니다.
객체 수명 주기 설정을 통해 만료 로그에 대한 삭제 및 아카이빙 구성 적용
▣ 주의 :
MFA 삭제 활성화 버킷에 대해서는 객체 수명 주기 적용이 불가능합니다. 따라서 계정 감사 등과 같은 중요 로그 외 일반적인 AWS API 활동에 한해 객체 수명 주기 적용을 해야 합니다.
[20] CloudTrail 로그 파일 무결성
CloudTrail 이벤트 로그에 대한 수정, 삭제 또는 위조를 방지를 위해 무결성 검증 방안이 적용되어야 합니다. CloudTrail에서는 추적 생성 시 로그 파일 검증 옵션을 통해 해당 기능을 제공하고 있습니다. 따라서 CloudTrail 추적 활성화 시 로그 파일 검증 옵션을 적용해야 합니다.
추가로 S3 객체 잠금을 활용하여 CloudTrail Log 저장 버킷에 대한 write-once-read-many(WORM) 모델을 적용할 수 있습니다. S3 WORM 구성은 로그 자체에 대한 삭제 또는 덮어쓰기를 방지하는데 도움이 되기 때문에 적극 활용해야 합니다.
CloudTrail 로그 파일 검증 옵션 활성화
CloudTrail 로그 저장 버킷에 대한 S3 객체 잠금 설정
[20] CloudTrail모니터링
보안 침해나 취약점이 발견되었을 때 즉각적인 조치를 취할 수 있도록 모니터링 방안이 구현되어야 합니다. CloudTrail에서는 이벤트 로그를 CloudWatch Logs로 전송하고 지표 필터 및 경보를 생성할 수 있습니다. 이러한 방식으로 보안 침해 발생 시 즉각적으로 대응할 수 있는 모니터링 구성이 가능합니다.
CloudWatch Logs를 활용하여 모니터링 구성 적용
