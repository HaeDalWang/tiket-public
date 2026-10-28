---
source_id: SRC-FTR-ACM-001
source_type: de-identified-internal-document-excerpt
channel: "[MSP 회사] AWS Account Management(ACM).docx — FTR-PLS 2.0 제출 문서 (발표 자료 NEW_PLS_FTR_MSP_202411 의 ACM-003·004·006·007 근거)"
captured_at: 2026-10-08 KST
source_owner_role: The MSP (document submitted to AWS for the Partner-Led Support FTR)
source_link: local only — policy/raw/FTR-PLS 2.0/MSP-FTR-ACM.docx (gitignored)
reported_by: repository owner
authority_basis: The repository owner supplied the folder on 2026-10-08 and stated it is the document actually defined between the MSP and AWS, with a clear source, and in force
---

# AWS Account Management (ACM) — 비식별 source excerpt

Text extracted from the document body. Mail addresses and phone numbers are replaced by `<메일>` / `<전화>`; the initial 빌링 플랫폼
password rule is replaced by a marker and is not carried over; figures are not text and are absent. Only ACM-003, ACM-004, ACM-006,
and ACM-007 are here. ACM-001, 002, 005, 008 are console walkthroughs with no ticket rule; ACM-009 and 010 belong with billing.
Four-part section numbers are written as `§3-1-3-3` (the workspace validator reads dotted quads as IPv4 addresses).
Heading marks such as `[10]` `[20]` `[3]` `[4]` are the document's heading levels.

## ACM-003 — 입점 (본문 그대로)

[10] ACM-003
[20] 입점
본 매뉴얼은 MSP 회사 입점 프로세스에 대한 내용이며, 입점 프로세스 중 EUR(End User Report) 관련해서는 5. EUR(End User Report) 부분에서 확인 가능합니다.
[3] 입점 시 제한 사항
MSP 회사 입점 시 조직 초대 시 제한사항에 대한 내용입니다.
[4] 타 조직 이관
입점을 위해서는 MSP 회사에서 관리되는 Payer 계정 조직에 속해야 되며, AWS Organization 특성에는 멤버 계정은 1개의 Oragnization에만 속할 수 있습니다.
기존에 Oragnization 기능을 사용한 고객이나 타 MSP사에 Oragnization에 속한 경우 입점 시 제한이 될 수 있기에 Oragnization 탈퇴 후에 MSP 회사 Oragnization에 초대 승인이 가능합니다.
[3] Zendesk Ticket
CSR 담당자는 위 장표를 토대로 Zendesk Ticket을 생성합니다.
COC 측에서는 해당 티켓을 받고 다음과 같이 변경 후에 3.1.3을 실행합니다.
요청자 -> 장표상 “고객사 내부 AWS 담당자”로 요청자를 신규 생성 후 변경합니다.
담당자 -> TS팀/서포트데스크로 변경합니다.
참조 -> CSR 담당자, 경영지원팀 담당자 “반드시” 추가합니다.
요청회사 -> 장표상 “고객사명”으로 변경합니다.
Ticket 제목은 [MSP 회사/고객사명] 신규 계정 통합 안내 로 변경합니다.
[3] 조직 초대 및 계정 설정
Zendesk Ticket상 설정은 3.1.2로 변경했다면 조직 초대 및 초대된 Account 내의 역할을 추가해야 합니다.
[4] Payer 조직 초대
MSP 회사에 Payer 조직에 속할 수 있도록 조직 초대를 합니다.
MSP 회사 Consolidated Billing과 publicspp 계정은 COC가 조직 초대를 진행하며, 별도 Payer로 빠져있는 경우 해당 고객사의 TS 담당자가 아래 절차에 맞춰 조직 초대를 진행합니다.
Payer 계정에 로그인 합니다.
검색 창에 Organization 검색 후 해당 서비스로 접근합니다.
왼쪽 메뉴 창에 “초대”을 클릭 한 후 화면이 전환되면 “AWS 계정 초대”를 클릭합니다.
“기존 AWS 계정 초대”를 선택 후 Zendesk Ticket상 전달받은 “AWS 계정”을 입력하고 아래 문구를 입력한 후 “초대 전송”을 클릭합니다..(다수 계정인 경우 “다른 계정 추가”를 누른 후 계정을 추가해주시면 됩니다.)
안녕하세요MSP 회사 서포트데스트OOO입니다.
[고객사명] 신규 계정 조직 초대를 위한 메일입니다.
확인 부탁드립니다.
감사합니다.
(초대 메뉴에서 상태가 “ACCEPTED”라면 조직 초대가 완료된 것이며, “OPEN”인 경우 아직 초대 승인 전인 상태입니다.)
조직 초대을 완료했다면 COC 측에서 고객사에 아래 내용과 함께 “기초보안가이드.pdf”, “AWS_운영_메뉴_CrossAccount_설정v5.pdf”을 Zendesk Ticket을 통해 고객에게 전달 후 고객사에 승인 요청 유선 연락합니다.
안녕하세요,
MSP 회사 서포트데스크 OOO입니다.
[고객사명] 계정 통합 안내드립니다.
1. AWS 빌링 통합 안내
1-1. AWS 계정 빌링 통합
▪ 아래 링크를 클릭하신 후 승인을 요청드립니다.
▫ 초대 메일 승인: https://console.aws.amazon.com/organizations/home#/invites
("Your AWS account has been invited to join an AWS organization"라는 제목의 메일을 통해서도 승인 가능합니다.)
▪ 승인 이후 부터 AWS 계정의 모든 AWS 사용 내용 및 사용 금액 정보가 MSP 회사의 AWS 계정으로 이관됩니다.
따라서, 통합 이후 "AWS root" 계정으로 접속하더라도 빌링 정보 조회가 불가능합니다.
1-2. 빌링 플랫폼 포탈 계정 발급
▪ AWS 콘솔 내의 빌링 페이지 차단으로 인해 MSP 회사에서는 별도의 빌링 포탈을 제공합니다.
▫ 빌링 플랫폼 포탈: https://billing.example.com/
▪ 귀사의 현재 빌링 플랫폼 계정 정보는 다음과 같습니다.
▫ 빌링 플랫폼 계정 정보: (빌링 플랫폼 ID : [ 고객사명_영어 ] <초기 비밀번호 규칙 — 옮기지 않음>
2. AWS Billing 확인 안내
2-1. 빌링 플랫폼 주 기능
▪ Service Trend : 계정의 월별 서비스 사용 비용을 확인할 수 있는 메뉴입니다.
▪ Cost Detail by Service : 계정에서 사용되는 서비스의 월별 사용 비용, RI기준 사용량 및 비용을 확인할 수 있습니다.
▪ Billing History : 그동안 청구된 History를 확인할 수 있습니다.
▪ Resources : RI기준 사용중인 서비스를 확인할 수 있습니다. (Instance ID, Active or Stop, Public IP, Instance Type, etc.)2-2. 빌링 레포트 확인
▪ 빌링 레포트는 다음달을 시작으로 매달 5~10일 사이에 송부되며, 세금계산서는 "won"단위 입니다.
▪ 빌링 통합을 진행한 달의 1일부터 빌링 통합 완료 시점까지의 사용량에 대해 기존과 동일한 방법으로 AWS에서 청구됩니다.
3. AWS 기술지원 안내
3-1. Cross Account 설정
▪ 신속한 지원을 위해 <AWS 운영 메뉴 CrossAccount 설정v5.pdf> 를 참고하여 Cross Account 설정을 요청드립니다
※ MSP 회사에서는 고객사의 인프라를 수정하지 않으며, 설정된 정보만을 수집합니다.
※ <AWS 운영 메뉴 CrossAccount 설정v5.pdf>는 메일 내용 가장 하단에 URL형태로 첨부되어있습니다.
4. AWS 계정 잔여 크레딧 현황 확인
4-1. 크레딧 정보 확인
▪ 통합을 진행한 AWS 계정에 적용 중인 잔여 크레딧이 있을 경우, Credit을 파트너사에서 확인 할 수 있도록 하기 위해 하단의 가이드를 통한 설정을 요청드립니다.
※ Cross Account를 통한 잔여 크레딧을 확인하는 용도 외에는 사용되지 않습니다.
▫ 크레딧 확인 설정 가이드: 결제 정보에 대한 IAM 사용자 및 역할 액세스 활성화 가이드
▪ 해당 가이드 링크 후 로그인 화면 발생 시 로그인 창 하단에 "비밀번호 만들기"를 클릭하신 후 입점 안내 메일을 받은 메일 주소 입력 및 비밀번호를 생성 후 로그인하여 가이드를 확인하실 수 있습니다.
5. AWS 계정 보호 안내
최근 해킹 사례가 빈번하게 발생하고 있습니다.
아래 내역 필히 적용하여 해킹으로 인한 피해를 방지하시기 바랍니다.
루트 사용자보다 최소 권한을 가진 IAM 사용자를 생성하여 사용하시는 것이 보안적으로 안전합니다.
모든 AWS 사용자에 대해서 MFA 설정을 권장 드립니다.
(MFA는 AWS OTP 설정으로 로그인 시 일회성 암호를 발급하여 인증하는 방법입니다.)
대부분의 해킹은 액세스 키 유출로 인해 발생합니다. 이에 따라 액세스 키 보안 모범 사례를 확인하여 안하게 관리하시는 것을 권장 드립니다.
첨부 드린 <기초 보안 가이드> 참고하시어 적용하시기 바라며, 추가 보안 사항도 검토 후 적용하여 보안 침해 사례에 대비하시길 권장 드립니다.
설정 시 궁금하신 사항 있으시다면, 언제든지 연락 주시길 바랍니다.
◾ 기술 문의 및 장애 지원 : <전화>
◾ MSP 회사 Support Desk : <메일>
◾ MSP 회사 대표번호 : <전화>
감사합니다.
[4] 빌링 플랫폼 계정 생성
MSP 회사 입점이후에는 Billing and Cost Management home 서비스를 이용할 수 없기 때문에 Billing and Cost Management home 기능을 사용할 수 있는 MSP 회사 Billing Tool인 빌링 플랫폼을 사용할 수 있도록 계정을 생성하는 내용입니다.
https://billing.example.com에 계정 생성 권한이 있는 계정으로 로그인 합니다.
왼쪽 메뉴 “ADMIN”항목 중 “고객사 목록”을 클릭합니다.
“+ 신규 고객사 추가”를 클릭하고 다음 항목을 추가한 후 “Save”을 클릭합니다.
Payer Type : 조직 초대를 보낸 Payer Account Name
Corp Name : Zendesk Ticket 상 고객사명
invoice_mail_address: Zendesk Ticket 상 세금 계산서 수신 이메일
info_mail_address: Zendesk Ticket 상 고객사 내부 AWS 담당자 정보
고객 담당자: Zendesk Ticket 상 고객사 내부 AWS 담당자 정보
테이블 검색에 고객사명을 검색한 후 Actions 탭의 “정보 수정”을 클릭합니다.
Account Settings 클릭 후 “+AWS Account 추가”를 클릭한후 다음 정보 입력 후 “추가 완료”를 클릭합니다.
AWS Account_ID: Zendesk Ticket 상 AWS 계정
CrossAccount IAM Role: MspCrossAccount
User Management 클릭 후 “+ 사용자 추가”를 클릭한 후 다음 정보 입력 후 “추가 완료”를 클릭합니다.
User Id: Zendesk Ticket 상 고객사명(영어)
<초기 비밀번호 규칙 — 옮기지 않음>
Email: Zendesk Ticket 상 고객사 내부 AWS 담당자 정보
User Auth : 관리자
[4] MspCrossAccount 설정
AWS의 권한 공유 방법 중 하나인 CrossAccount 설정을 통해 입점된 고객의 AWS 계정의 권한에 대한 내용입니다. 설정 방법은 내부 가이드 “AWS_운영_메뉴_CrossAccount_설정v5”을 참고해주시면 됩니다.
[Policy]
ReadOnlyAccess: AWS 자원의 Read 만 허용하는 권한입니다.
AWSSupportAccess: case open을 할 수 있는 support 권한입니다.
AWSSavingsPlansReadOnlyAccess: Savings Plans 서비스에 대한 읽기 전용 액세스 제공
msp_custom_deny: Custom policy로 고객사의 DB 및 스토리지 등에 대한 접근을 막는 추가 거부 권한입니다
{
"Version": "2012-10-17",
"Statement": [
{
"Effect": "Deny",
"Action": [
"dynamodb:GetItem",
"dynamodb:BatchGetItem",
"dynamodb:Query",
"dynamodb:Scan",
"ecr:BatchGetImage",
"ecr:GetAuthorizationToken",
"ecr:GetDownloadUrlForLayer",
"kinesis:Get*",
"s3:GetObject",
"glacier:Get*",
"sdb:Select*",
"sqs:ReceiveMessage"
],
"Resource": "*"
}
]
}
[Role]
위 4개 Policy를 가진 “MspCrossAccount”를 생성합니다.
신뢰 관계는 다음과 같습니다.
{
"Version": "2012-10-17",
"Statement": [
{
"Effect": "Allow",
"Principal": {
"AWS": [
"arn:aws:iam::[the MSP Payer ID]:user/crossaccount
]
},
"Action": "sts:AssumeRole",
"Condition": {}
}
]
}
위 역할을 설정하면 빌링 플랫폼을 통해 MSP 회사 담당자가 “Switch Role”을 통해 고객사 계정에 접근이 가능합니다.
[3] EUR 설정
EUR(End User Report)은 솔루션 제공업체 할인을 받기 위해 매월 AWS 계정을 리포팅한다는 약속이며, AWS 파트너가 고객의 요구 사항을 체계적으로 관리하고, 이를 바탕으로 최적의 AWS 솔루션을 제공하기 위한 중요한 과정입니다.
등록 과정은 5.4 EUR(End User Report) 등록 방법을 참고하시면 됩니다.
[3] 빌링 플랫폼 추가 설정
[4] AWS CloudFront단가 할인 적용
입점 고객사의 AWS CloudFront 할인 적용 시 빌링 플랫폼 접속하여 고객사 목록 메뉴에 들어갑니다. 고객사 명 또는 Account ID 입력 후 해당 고객사가 맞는지 확인합니다. 정보 입력 버튼 클릭합니다. 정보 입력 화면 좌측에서 CloudFront Discount Settings를 클릭합니다.  CloudFront Discount Settings 화면에 들어와서 우측 상단에 CF 할인 정보 등록을 누릅니다. Cloud Front 할인 정보 등록 화면에서 할인 기간을 설정하고 협의된 할인 내용을 기입 후에 Save 버튼을 눌러서 적용합니다.
[4] 할인 및 추가청구
할인 및 추가 청구는 입점 고객사와 협의된 내용이 해당하는 경우 등록합니다.
빌링 플랫폼에 접속합니다. 접속 후 할인/추가청구 메뉴를 클릭하면 Inventory와 할인 이력 메뉴가 나옵니다. Inventory를 클릭합니다.
[5] §3-1-5-2.1 할인
고객과 협의 시 할인을 협의한 고객사에게 해당하는 메뉴입니다.
Inventory 화면에서 왼쪽 위 할인 탭을 클릭합니다.
우측 상단 할인 등록을 클립 합니다. 신규 할인 등록 창이 나옵니다.  창에서 각 항목은 하기와 같습니다.
할인 유형 : 할인 종류를 선택합니다. Ex)AWS Credit, MSP 회사 Credit, MSP 할인, MSP 회사 할인, 선납금
업체명 : 입점하는 고객사의 명을 입력합니다.
AWS Account ID : 입점하는 고객사의 AWS Account ID를 선택합니다.
AWS Service : 입점하는 고객사의 어느 AWS Service에 할인을 적용할 지 선택합니다. (옵션 : ALL, Support)
할인 금액 : 입점하는 고객사와 제공하기로 협의된 할인 금액을 입력합니다. (달러,원화 선택가능)
적용 기간 : 입점하는 고객사와 협의된 할인 적용 기간을 입력합니다.
Description : 입력한 할인 내용에 대해서 요약 설명을 입력합니다.
[5] §3-1-5-2.2 추가 청구
입점하는 고객과의 AWS 사용료 외 추가 된 비용이 있을 시 추가 청구 등록을 하게 됩니다.
Inventory 화면에서 왼쪽 위의 추가청구 탭을 클릭합니다.
우측 상단의 추가청구 등록 버튼을 클릭합니다.  신규 추가청구 등록 창이 나옵니다. 창에서 각 항목은 하기와 같습니다.
업체명 : 업체를 선택합니다.
ChargeItem : 어느 내용 때문에 추가 청구를 하는지 제목을 입력합니다. (고객사가 청구서에 보여지는 제목)
추가 청구 금액 : 추가 청구할 금액이 얼마인지 달러와 원화를 선택 후 작성합니다.
적용 기간 : 추가 청구할 항목의 적용 기간을 입력합니다.
Description : 추가 청구하는 내용의 세부 내용을 적거나 CSR팀 내부에서 확인 할 수 있도록 작성합니다.
[20] Diagnosis 및 Trouble shooting을 위한 정책 설정
본 매뉴얼은 MSP 회사 입점 후 PLS 대상 계정에서 진단 및 Trouble Shooting 기능을 사용하기 위해서 추가하는 정책 및 역할입니다.
§3-1-3-3 MspCrossAccount를 통해 생성했던 IAM Role인 “MspCrossAccount”에 Trouble Shooting 서비스가 역할을 수행할 수 있도록 추가하며, Role의 신뢰관계도 변경해야합니다.
Diagnosis 및 Trouble shooting을 위한 정책 설정 방법은 다음과 같습니다.
검색 창에 IAM 검색 후 해당 서비스로 접근합니다.
왼쪽 메뉴 창에 “정책”을 클릭한 후 “정책 생성”을 클릭한 후 JSON에 다음과 같은 내용을 넣고 정책 이름을 “msp_ts_policy”로 생성합니다.MSP 회사_ts_policy : Custom policy로 Trouble Shooting 서비스를 사용하여 진단할 수 있도록 하는 권합입니다.
{
"Version": "2012-10-17",
"Statement": [
{
"Action": [
"ts:GetExecution",
"ts:GetExecutionOutput",
"ts:GetTool",
"ts:ListExecutions",
"ts:ListTools",
"ts:StartExecution",
"ts:TagResource",
"ts:UntagResource",
"ts:ListTagsForResource",
"iam:PassRole"
],
"Effect": "Allow",
"Resource": "*"
}
]
}
왼쪽 메뉴 창에 “역할”을 클릭한 후 “MspCrossAccount” 를 검색합니다.
검색된 역할을 클릭한 후 신뢰 관계 탬에서 “신뢰 정책 편집”을 클릭한 후 JSON에 다음과 같은 내용을 추가하고 “정책 업데이트”를 합니다.
{
"Version": "2012-10-17",
"Statement": [
{
"Effect": "Allow",
"Principal": {
"Service": "ts.amazonaws.com", # 추가
"AWS": "arn:aws:iam::[the MSP Payer ID]:user/crossaccount
},
"Action": "sts:AssumeRole",
"Condition": {}
}
]
}

## ACM-004 — 퇴점 (본문 그대로)

[10] ACM-004
[20] 퇴점
본 매뉴얼은 MSP 회사 퇴점 프로세스에 대한 내용입니다.
[3] 퇴점 시 제한 사항
퇴점의 경우 고객 직접 퇴점과 MSP 회사 퇴점이 있습니다.
MSP 회사 퇴점 시 조직 탈퇴 시 제한사항에 대한 내용입니다.
[4] 결제 정보 만료(결제 정보 없음)
AWS 계정 생성시 등록했던 결제정보가 만료되었거나 AWS 조직 내 계정 생성으로 인해 결제 정보를 입력하지 않은 경우에 “조직에서 제거”시 Access Deny가 발생됩니다.
퇴점 시에는 결제 정보를 확인해야 합니다.
[4] SCP 정책
고객이 직접 퇴점을 하려는 경우 Payer를 확인해야 합니다.
MSP 회사 Consolidated Billing를 제외한 Payer에는 멤버계정이 조직을 탈퇴할 수 없도록 scp가 설정되어 있기 때문에 고객이 직접 퇴점할 수 없습니다.
{
"Version": "2012-10-17",
"Statement": [
{
"Sid": "Statement1",
"Effect": "Deny",
"Action": [
"organizations:LeaveOrganization"
],
"Resource": [
"*"
]
}
]
}
[3] Zendesk Ticket
CSR 담당자는 위 템플릿을 토대로 Zendesk Ticket을 생성합니다.
TS 계정 해지 담당자는 해당 티켓을 받고 다음과 같이 변경 후에 4.1.3을 실행합니다.
담당자 -> TS팀 계정 해지 담당자로 변경합니다.
요청회사 -> 템플릿 상 회사명으로 변경합니다.
Ticket 제목은 [고객사명] 계정 통합 해지 요청으로 변경합니다.
[3] 조직 멤버 계정 제거 및 계정 설정
Zendesk Ticket상 설정은 4.1.2로 변경했다면 조직 멤버 계정 제거 및 MC 서비스를 제공받은 Account에 설정 변경해야 합니다.
[4] 조직 멤버 제거
퇴점을 위해 MSP 회사 조직에서 제거를 합니다.
MSP 회사 Consolidated Billing과 publicspp 계정은 TS 계정 해지 담당자가 조직 제거를 진행하며, 별도 Payer로 빠져있는 경우 해당 고객사의 TS 담당자가 아래 절차에 맞춰 조직 초대를 진행합니다.
만약 MC 서비스를 제공받은 Account라면 §4-1-3-2 계정 설정 변경을 사전에 한 후 아래 작업을 수행합니다.
Payer 계정에 로그인 합니다.
검색 창에 Organization 검색 후 해당 서비스로 접근합니다.
왼쪽 메뉴 창에 “AWS 계정”을 클릭한 후 해지가 필요한 Account ID number를 검색합니다.
검색된 계정을 체크한 후 “작업” -> “조직에서 제거”를 클릭 후 새로운 창이 활성화되면 “계정 제거”를 클릭합니다.
조직 해제 관련된 내용을 Zendesk Ticket에 내부 메모로 작성 후 Ticket을 종료합니다.
[4] 계정 설정 변경
MC 서비스(MSP 포함)를 제공받는 경우 SNS 구독이 <메일> 지정되어 있습니다.
SNS 구독 삭제가 필요합니다.
(해당 계정에 권한이 있다는 전제 하에 진행됩니다. 없는 경우는 권한 요청 후 진행해주세요.)
해지할 계정에 Switch Role을 통해 접근합니다.
검색 창에 SNS검색 후 해당 서비스로 접근합니다.
왼쪽 메뉴에 “구독”으로 클릭 후 <메일> 선택 후 “삭제”을 클릭합니다.
[3] 빌링 플랫폼 설정
퇴점의 경우 빌링 플랫폼에서 고객 사용 여부를 미사용으로 설정 후 저장합니다.
설정 방법은 다음과 같습니다.
[11] 빌링 플랫폼 포탈 접속
MSP 회사 계정으로 접속합니다.
고객사 목록 메뉴를 클릭합니다.
테이블 검색란에 퇴점하는 고객사 명을 작성합니다.
검색된 내역을 퇴점한 고객이 맞는지 확인 후 정보수정 버튼을 클릭합니다.
고객 사용 여부를 미사용으로 설정 후 Save Change 버튼을 클릭합니다.

## ACM-006 ~ ACM-007 — MFA, CrossAccount Role (본문 그대로)

[10] ACM-006
[20] MFA을 통한 고객 및 파트너 계정의 보안 강화 및 권한 관리
MSP 회사는 빌링 플랫폼이라는 자체 웹을 통해 고객 계정에 접근하며, 빌링 플랫폼 로그인시 아이디, 패스워드, MFA가 필수로 적용 되어 있습니다.
[20] 멀티팩터인증(MFA) 설정
[3] 멀티팩터인증(MFA)인증 개요
업무간 빌링 플랫폼 포털를 이용하거나 고객의 계정에 접근을 해야하는 경우, 관련한 사내의 모든 직원은 멀티팩터인증(MFA)인증을 필수로 설정하며, 설정하지 않을 경우, 포털에 접근 제한됨을 원칙으로 업무를 진행해야 합니다.
[3] 빌링 플랫폼 멀티팩터 인증(MFA) 설정
사내 클라우드 서비스 지원 포털인 빌링 플랫폼을 사용하는 모든 사내 직원 해당 포털의 ID를 할당 받으며, 각자의 ID를 이용하여 해당 포탈로 로그인합니다
첫 로그인 이후, 포털 우측 상단에 위치한 본인의 이름을 클릭 후 계정 설정 페이지로 이동합니다.
계정 설정 페이지에서 Authentication (MFA) 탭으로 이동한 후, MFA 디바이스 추가 버튼을 클릭하면 등록을 위한 QR코드가 나타납니다. 해당 QR코드를 이용하여 본인이 사용하는 디바이스에 등록 절차를 진행합니다.
모든 절차가 완료 후 빌링 플랫폼의 재 로그인을 시도하면 위와 같은 멀티팩터인증(MFA) 절차 페이지로 넘어가며, 해당 절차를 완료하지 않는다면 로그인에 실패합니다.
해당 과정은 반드시 빌링 플랫폼 포털을 이용하는 사내의 모든 직원이 걸쳐야 할 절차입니다.
[10] ACM-007
고객계정에 접근하는 Role(MspCrossAccount)은 ReadOnlyAccess,
AWSSupportAccess, AWSSavingsPlansReadOnlyAccess 및 msp_custom_deny 가 연결 됩니다.
Msp_custom_deny 정책은 S3, ECR, DynamoDB 등 리소스 정보 접근 권한을 막는 정책입니다.
[20] CrossAccount Role 설정
[3] CrossAccount Role 설정 개요
빌링 플랫폼을 통해 고객계정의 접근을 위하여 사전 설정 단계가 필요하며, 해당 설정을 통해 사내 직원은 역할을 위임받아 고객 계정에 접근을 합니다.
해당 역할은 고객의 허가없이 관리자 권한을 취할수 없으며, 최소 권한의 원칙을 따라 필요 권한만을 가짐을 원칙으로 합니다.
[3] IAM Policy(정책) 생성
AWS IAM 대쉬보드로 이동 후, 정책생성을 통해 아래의 JSON을 추가합니다.
{
"Version": "2012-10-17",
"Statement": [
{
"Effect": "Deny",
"Action": [
"dynamodb:GetItem",
"dynamodb:BatchGetItem",
"dynamodb:Query",
"dynamodb:Scan",
"ecr:BatchGetImage",
"ecr:GetAuthorizationToken",
"ecr:GetDownloadUrlForLayer",
"kinesis:Get*",
"s3:GetObject",
"glacier:Get*",
"sdb:Select*",
"sqs:ReceiveMessage"
],
"Resource": "*"
}
]
}
해당 Json 형식은 위와같으며 행당 Action이 의미는 다음과 같은을 인지합니다.
- dynamodb:GetItem: Amazon DynamoDB에서 단일 항목을 조회하는 작업을 금지합니다.
- dynamodb:BatchGetItem: 여러 항목을 일괄적으로 조회하는 작업을 금지합니다.
- dynamodb:Query: 인덱스를 사용하여 DynamoDB에서 데이터를 조회하는 작업을 금지합니다.
- dynamodb:Scan: DynamoDB에서 전체 테이블 또는 인덱스를 스캔하여 데이터를 조회하는 작업을 금지합니다.
- ecr:BatchGetImage: Amazon Elastic Container Registry(ECR)에서 이미지를 일괄적으로 가져오는 작업을 금지합니다.
- ecr:GetAuthorizationToken: ECR에서 인증 토큰을 가져오는 작업을 금지합니다.
- ecr:GetDownloadUrlForLayer: ECR 이미지 레이어에 대한 다운로드 URL을 가져오는 작업을 금지합니다.
- kinesis:Get*: Amazon Kinesis 스트림에서 데이터를 조회하는 모든 작업을 금지합니다.
- s3:GetObject: Amazon S3 버킷에서 객체를 가져오는 작업을 금지합니다.
- glacier:Get*: Amazon S3 Glacier에서 데이터를 조회하는 모든 작업을 금지합니다.
- sdb:Select*: Amazon SimpleDB에서 데이터를 선택하는 모든 작업을 금지합니다.
- sqs:ReceiveMessage: Amazon Simple Queue Service(SQS) 큐에서 메시지를 수신하는 작업을 금지합니다.
해당 JSON 파일은 MSP 회사에서 고객의 계정에 접근 시 최소권한의 원칙을 지키위한 Custom 정책으로 정책명은 “msp_custom_deny”로 명명합니다.
[3] IAM Role(역할) 생성
AWS IAM 대쉬보드로 이동 후, 역할을 생성합니다.
Trusted entity type에서 [AWS account]항목을 선택한 후, 하단에서 Another AWS account를 선택하고 Account ID에 MSP 회사의 Account ID를 입력 후, [Next: Permissions]버튼을 클릭합니다.
ReadOnlyAccess 권한, AWSSavingsPlansReadOnlyAccess 권한,  AWSSupportAccess 권한, Msp_custom_deny 권한까지 총 4개의 권한에 체크박스를 선택합니다.
[Next: Review]버튼을 클릭하여 Review화면으로 이동합니다.
적용된 정책은 다음과 같습니다:
- ReadOnlyAccess
AWS 자원에 대한 읽기 전용 권한을 부여하는 정책입니다. 사용자는 AWS 리소스의 데이터를 조회할 수 있지만, 수정, 삭제 또는 생성과 같은 쓰기 작업은 허용되지 않습니다.
- AWSSupportAccess
AWS Support에서 지원 요청을 생성(case open)할 수 있는 권한을 부여하는 정책입니다. 이 정책을 통해 사용자는 AWS 지원팀과 문제를 보고하고, 기술 지원을 받을 수 있습니다.
- Msp_custom_deny
고객사의 데이터베이스 및 스토리지 자원에 대한 접근을 차단하는 사용자 정의 거부 정책입니다. 이 정책은 보안과 데이터 보호를 목적으로, 특정 리소스에 대한 접근을 제한합니다.
- AWSSavingsPlansReadOnlyAccess
AWS Savings Plans 서비스에 대한 읽기 전용 권한을 부여하는 정책입니다. 사용자는 Savings Plans와 관련된 정보를 조회할 수 있으나, 설정 변경 또는 구매와 같은 수정 작업은 허용되지 않습니다.
위의 정책들은 사용자의 접근 권한을 제어하여 시스템 보안을 강화하고, 필요한 리소스에만 제한된 접근을 허용합니다.
해당 Role name은 MspCrossAccount로 명명합니다.
[3] IAM Trust Relationship(신뢰정책) 적용
신뢰 정책 편집을 통해 MSP 회사 계정으로 변경을 합니다.
해당 신뢰관계를 통해 MSP 회사 계정에서 설정한 CrossAccount를 사용하여 고객의 계정에 액세스 할 수 있으며, 사용 가능한 권한은 최소 권한의 원칙을 따릅니다.
[20] CrossAccount을 통한 고객계정 접근
모든 과정이 완료된 사내 직원은 빌링 플랫폼 포털을 통해 로그인 후, 고객사 목록을 통해 입점되어있는 고객사를 검색후 Switch Role 버튼을 통해 설정되어있는 CrossAccount Role을 통한 로그인이 가능합니다.
