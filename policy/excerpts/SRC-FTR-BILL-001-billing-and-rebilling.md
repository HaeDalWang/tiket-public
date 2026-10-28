---
source_id: SRC-FTR-BILL-001
source_type: de-identified-internal-document-excerpt
channel: "FTR-PLS 2.0 제출 문서 넷에서 뽑음 — Billing and Cost Management(BIL), Solution Provider Rebilling(RBL), AWS Account Management(ACM) 의 ACM-009·010, Solution Provider Customer Tenancy(SPP) 의 SPP-001·002"
captured_at: 2026-10-08 KST
source_owner_role: The MSP (documents submitted to AWS for the Partner-Led Support FTR)
source_link: local only — policy/raw/FTR-PLS 2.0/MSP-FTR-{BIL,RBL,ACM,SPP}.docx (gitignored)
reported_by: repository owner
authority_basis: The repository owner supplied the folder on 2026-10-08 and stated it is the document actually defined between the MSP and AWS, with a clear source, and in force
---

# Billing and rebilling (BIL · RBL · ACM-009·010 · SPP-001·002) — 비식별 source excerpt

Text extracted from the document bodies. Left out on purpose: the list of Payer accounts and the customer names beside them (SPP-002),
the sentence of ACM-010 that carries a Payer account number, BIL-003 (payment and tax settings with address, phone, and mail), the
빌링 플랫폼 feature list and page walkthroughs, and figures. Mail addresses are replaced by `<메일>`. Four-part section numbers are
written as `§2-2-4-1` (the workspace validator reads dotted quads as IPv4 addresses). Heading marks are the documents' heading levels.

## BIL-001 — 빌링 플랫폼 예산 (본문 그대로)

[Heading1] BIL-001
[Heading2] 빌링 플랫폼 예산이란?
빌링 플랫폼 예산은 사용자가 정의한 예산 임계값을 기준으로 AWS 비용을 추적하고 조치를 취할 수 있습니다.
빌링 플랫폼 예산은 실시간 비용 알림이 아니며, 24시간마다 1회 이상 집계된 비용 데이터(고객사 별 blended_cost 데이터)를 바탕으로 계정별로 고객께서 설정하신 임계치를 초과하는 경우 알림이 발생됩니다.
예산 정보는 업데이트는 일반적으로 이전 업데이트 후 8~12시간 사이에 발생합니다.
[Heading2] 예산 알람 범위
빌링 플랫폼 예산에 해당하는 비용 범위는 다음과 같습니다.
AWS 온디맨드 비용
RI, SP 관련 비용
CFRC, PPA 적용 비용
[Heading2] 빌링 플랫폼 예산 페이지 설명
빌링 플랫폼 예산은 Setting > Notification > Budgets 메뉴에 위치하고 있습니다.
사용자는 예산을 AWS 계정단위로 기간과 Threshold, Alert Rate, 알람 수신자, 설명을 설정할 수 있습니다.
AWS  계정 : 빌링 플랫폼과 연동이 되어야 설정할 수 있습니다. 연동되지 않은 경우 예산을 설정할 수 없습니다.
기간 : 예산 알람을 적용받을 기간(월 단위)을 설정할 수 있습니다.
Treshold : 월별 예산입니다.
Alert Rate : Threshold 기준으로 알람 비율을 설정할 수 있습니다. 설정한 알람 비율이 초과할 때 알람이 발생합니다. 최소 10% 부터 최대 100%로 설정할 수 있습니다.
알람 수신자 : 사용자가 설정한 예산 알람 기준으로 이메일로 받을 수신자를 설정할 수 있습니다. 이메일 다중 입력 시 “,”로 구분합니다.
같은 달에 대해 이미 알람이 발생된 경우 다시 이메일 발송하지 않습니다.
AWS Budget 기능을 활용하고 있지 않고, MSP 회사에서 자체적으로 Budget기능을 만들어서 수행하고 있습니다.
[Heading2] 예산 알림 설정 방법
아래 사진와 같이 예산 설정은 Setting > Notification > Budgets 메뉴에서 우측 상단 “예산 알림 추가" 버튼을 클릭하여 설정할 수 있습니다.
버튼을 클릭하게 되면 아래와 같이 화면이 표기됩니다.
예산 알람을 등록할 AWS Account와 감지 기간, 예산, 비율, 수신인, 설명을 설정하여 “추가 완료" 버튼을 클릭하여 등록합니다.
[Heading2] 예산 알람 메일 예시
[Heading2] 빌링 플랫폼 예산 기능 로드맵
내년 25년.1Q~2Q 크레딧, 반복 결제 금액, 선결제 금액 등을 제외하거나 포함할 수 있는 옵션을 추가할 예정입니다.
그 외 나머지 혼합/비혼합 비용, 상각된 비용은 현재 관리하고 있지 않으므로 25년.하반기 이후 검토 예정입니다.

## BIL-002 — Type 별 기능 소개, Cost Detail, Cost Allocation Tags (본문 그대로, 화면 설명 제외)

참고. Type 별 기능 소개
사용하신 AWS 비용 추이를 세부 Type 별로 확인할 수 있습니다.(조회가능한 Type 값에 대해서만 필터에서 선택할 수 있습니다)
credit : AWS가 청구에서 적용하는 모든 크레딧입니다. AWS가 청구서 금액이 확정된 후 해당 월에 대해 계정에 크레딧을 적용하는 경우에는 AWS가 보고서를 완성된 이후에 업데이트할 수 있습니다.
discountedusage : RI 혜택을 보유한 모든 인스턴스의 요금입니다.
discount : MSP 회사에서 제공하는 할인된 요금입니다.
fee : 구독에 대해 지불한 모든 선결제 연간 요금입니다. 예를 들어, Route53 도메인 및 기타 서비스, 전체 선결제 RI 또는 부분 선결제 RI에 대해 지불한 선결제 요금입니다.
savingsplanupfrontfee : Savings Plan 구독에 대해 지불한 모든 선결제 연간 요금입니다. 예를 들어, 전체 선결제 Savings Plan 또는 부분 선결제 Savings Plan 에 대해 지불한 선결제 요금입니다.
refund : AWS가 환급하는 음수 값의 요금입니다. AWS가 청구서 금액이 확정된 후 해당 월에 대해 계정에 환급금을 적용하는 경우에는 AWS가 보고서를 완성된 이후에 업데이트할 수 있습니다.
rifee : RI 구독에 대해 매달 발생하는 요금입니다. 예를 들면, Partial Upfront RI(부분 선결제 RI), No Upfront RI(선수금 없음 RI) 및 All Upfront(전체 선결제)에 대해 매달 지불하는 반복 요금입니다.
savingsplanrecurringfee : Savings Plans 구독에 대해 매달 발생하는 요금입니다. 예를 들면, Partial Upfront SP(부분 선결제 Savings Plan), No Upfront SP(선수금 없음 Savings Plan) 및 All Upfront(전체 선결제)에 대해 매달 지불하는 반복 요금입니다.
tax : AWS가 청구서에 적용하는 모든 세금(예 : VAT 또는 미국 매출세)입니다.
usage : 온디맨드 기준 인스턴스 요금이 부과되는 모든 사용량입니다.
applyri : RI가 적용되어 할인되는 금액입니다.
applysavingsplanec2 : EC2 Savings Plan이 적용되어 할인되는 금액입니다.
applysavingsplancompute : Compute Savings Plan이 적용되어 할인되는 금액입니다.
msp credit : MSP 회사에서 청구서에 적용하는 크레딧 입니다. 청구서 금액이 확정된 후 해당 월에 대해 계정에 크레딧을 적용하는 경우에는 보고서를 완성된 이후에 업데이트할 수 있습니다.
aws credit : AWS에서 제공하는 크레딧 입니다.
선납금 : MSP 회사 청구서에 적용 된 선납금 입니다.
complimentary : MSP 회사에서 제공하는 1TB CloudFront 사용료 할인입니다.
applysavingsplansagemaker : SageMaker Savings Plan이 적용되어 할인된 금액입니다.
[Heading3] Cost Detail
Q. Cost Detail 페이지에서는 무엇을 확인할 수 있나요?
A. AWS 서비스 Usage 관련 청구(또는 할인) 금액이며 AWS support요금, Credit할인, MSP요금 등 부가적인 청구(또는 할인) 금액은 포함하지 않습니다.
[Heading2] Cost Allocation Tags
주의사항
비용 할당 태그를 처음으로 사용하시는 경우, 24시간 이상 소요될 수 있습니다. (영업일 기준)
비용 할당 태그가 적용된 AWS 리소스의 비용 및 사용량은 해당 태그가 활성화된 이후부터 추적되며, 활성화 이전의 사용량은 조회되지 않을 수 있습니다.
[Heading3] 페이지 개요
Cost Allocation Tags 페이지에서 비용 할당 태그를 활성화하면, Tag Explorer 페이지에서 해당 태그가 지정된 AWS 리소스(들)의 비용 및 사용량 정보를 모아서 확인할 수 있습니다.
빌링 플랫폼은 Cross Account를 설정하지 않은 계정이 소유한 리소스의 태그에 접근할 수 없습니다. 비용 할당 태그를 사용하려면 Cross Account 설정이 필요합니다.
[Heading3] 주요 용어 정리
리소스 태그 : AWS 내 리소스에 지정된 모든 태그들을 말합니다.
Available Tags : 리소스 태그 중 비용 할당 태그로 활성화할 수 있는 태그 리스트입니다.
Unavailable Tags : 리소스 태그 중 비용이 발생하지 않았거나 비용 할당 태그로 활성화할 수 없는 태그입니다. 비용이 발생하지 않은 리소스 태그는 비용 발생 후 Available Tags 리스트에 포함됩니다.
Selected Tags : Available Tags 중 비용 및 사용량 추적을 위해 선택된 태그입니다.
Cross-Account 접근 : 한 AWS 계정의 IAM 사용자가 다른 AWS 계정의 리소스에 접근하는 것을 의미합니다.
Cross Account 미설정 계정 : 빌링 플랫폼의 AWS 계정이 고객의 AWS 계정 리소스에 Cross-Account 접근하여 리소스 태그를 가져오기 위해서는 Cross Account 설정이 필요합니다. Cross Account를 설정하지 않은 계정은 Cross Account 미설정 계정에서 확인하실 수 있습니다.
[Heading3] 비용 할당 태그 활성화 절차
[Heading4] Cross Account 설정
비용 할당 태그를 사용하려면 Cross Account 설정이 필요합니다. Cross Account 미설정 계정 영역에서 설정 여부를 확인하고, 미설정되어 있을 경우 설정 가이드 다운로드 버튼을 눌러 가이드를 참고하여 설정해 주시기 바랍니다.
[Heading4] 리소스 태그 지정
AWS에서 비용 및 사용량을 추적하고자하는 리소스에 태그를 지정합니다. 최대 8시간 이후 빌링 플랫폼의 Cost Allocation Tags 페이지의 Available Tags에서 앞서 리소스에 지정한 태그를 확인할 수 있습니다.
[Heading4] 비용 할당 태그 선택
Available Tags 리스트의 태그들 중 비용 할당 태그로 활성화하고자 하는 태그를 Selected Tags 리스트로 옮깁니다. 비용 할당 태그는 `최대 5개`까지 선택할 수 있습니다.
[Heading4] 비용 할당 태그 활성화
Selected Tags 리스트를 확인한 후 Save 버튼을 눌러 선택한 비용 할당 태그를 활성화합니다. 비용 할당 태그를 처음으로 사용할 경우 활성화는 영업일 기준 24시간 이상 소요될 수 있으며, `비용 할당 태그 활성화 이후` 시점부터 해당 태그가 적용된 리소스의 비용 및 사용량이 추적됩니다.
[Heading4] 데이터 확인
빌링 플랫폼의 Tag Explorer 페이지에서 비용 할당 태그를 선택하고 검색하면 해당 태그가 지정된 AWS 리소스의 비용 및 사용량 정보를 확인할 수 있습니다.
[Heading3] FAQ
§2-2-4-1 AWS에서 비용 및 사용량 추적을 원하는 리소스에 태그를 지정헸지만 빌링 플랫폼의 Cost Allocation Tags 페이지의 Available Tags 리스트에 해당 태그가 보이지 않습니다.
태그를 지정한 리소스를 소유한 AWS 계정에 Cross-Account 설정이 되어 있지 않을 수 있습니다. Cross-Account 설정을 확인해주세요.
리소스에 새롭게 적용된 태그는 최대 8시간 후에 Cost Allocation Tags 페이지의 Available Tags 리스트에서 확인할 수 있습니다. 충분히 시간이 지나고 난 후 다시 확인해주세요.
시간이 충분히 지난 후에도 해당 태그가 Available Tags 리스트에 보이지 않는다면, Unavailable Tags 목록에 포함되어 있는지 확인해주세요. Unavailable Tags에 포함된 태그 중 비용이 발생하지 않은 태그는 비용이 발생하면 Available Tags에서 확인할 수 있습니다.
§2-2-4-2 Cost Allocation Tags 페이지에서 비용 할당 태그를 활성화했지만 Tag Explorer 페이지에서 해당 태그의 데이터가 존재하지 않습니다.
비용 할당 태그 활성화는 24시간 이상 소요될 수 있습니다. 충분히 시간이 지나고 난 뒤 다시 시도해주세요.
비용 할당 태그가 적용된 리소스의 비용 및 사용량은 비용 할당 태그로 활성화 시점 이후부터 추적됩니다. 활성화 이전 기간의 데이터인지 확인해주세요.

## RBL-001 — 요금 청구서 (본문 그대로)

[20] 요금 청구서 가이드 및 샘플
요금 청구서
이 페이지에서는 청구 월별로 청구월 별 공급가액, 부가세액, 총액 및 요금 청구서 발행 일자와 같은 요금 청구서에 대한 정보를 확인할 수 있습니다. 또한, 실제 발행된 청구서는 보기 버튼을 클릭하시면 PDF 파일로 열립니다. 이를 통해 발행된 청구서를 쉽게 확인하고 다운로드하실 수 있습니다.
수기 청구된 월의 요금 청구서는 표시되지 않습니다. 해당 내역이 필요하신 경우 담당 영업에게 문의주시기 바랍니다.

## RBL-002 — RI/SP·크레딧 공유와 재계산 (본문 그대로)

[10] RBL-002
[20] the billing platform RI/SP
기본적으로 모든 AWS 계정은 조직에 연결되면, 크레딧(Credit), 예약 인스턴스(RI), 세이빙스 플랜(SP) 공유 옵션이 기본으로 활성화됩니다.
이 공유 옵션이 활성화되면 조직 내 모든 계정의 사용량에 대해 동일하게 적용되므로, 이를 기반으로 AWS 요금을 다시 계산하여 고객에게 청구해야 합니다.
AWS Console 설정
크레딧 공유 옵션
RI, SP 공유 옵션
빌링 플랫폼 Credit, RI, SP공유
빌링 플랫폼에서 Credit 공유 활성화 옵션 기능을 ON/OFF 제공하고 있습니다. RI/SP 적용 공유 활성화에 옵션 정 기능은 따로 제공되고 있지 않습니다.
빌링 플랫폼 Credit 적용 범위
AWS에서는 크레딧 공유 옵션의 활성/비활성 여부에 관계없이 비적격서비스는 크레딧 적용대상에서 제외됩니다.
AWS에서 마켓플레이스 요금은 기본적으로 크레딧 적용 비적격 서비스이므로 크레딧이 적용되지 않습니다.
다만, Activate Credit인 경우 일부 마켓플레이스 서비스(AmazonBedrock 3rd party 제품들)은 적격 서비스로 취급하여 크레딧을 적용합니다.
반면, 빌링 플랫폼 청구에서는 특정 고객사(소속 계정)의 크레딧 공유 옵션(활성화/비활성화)에 따라 크레딧을 다르게 적용합니다. 빌링 플랫폼에서는 특정 고객사의 크레딧 공유 옵션을 활성화하면 모든 AWS 사용금액이 크레딧 적용 대상이 되지만, 크레딧 공유 옵션을 비활성화하면 AWS의 크레딧 적용방식과 마찬가지로 빌링 처리 시 비적격 서비스는 크레딧 적용 대상에서 제외합니다. 또한 AWS와 마찬가지로 Activate Credit인 경우 Amazon Bedrock 3rd party 제품들은 적격 서비스로 취급합니다.
빌링 플랫폼 Credit ON/OFF 동작
크레딧은 “Non-activate credit” ,  “activate credit “로 각각  구분됩니다.
빌링 플랫폼에서 Credit ON 일 경우 고객사별로 공유되어 사용됩니다.
적용 요금 대상은 다음과 같습니다.
Non-activate credit & activate credit 적용 대상:
온디맨드 요금
RI/SP 할인
Private Price 할인
AWS Support 요금
빌링 플랫폼에서 Credit OFF 일 경우 고객사내 AWS 계정별로 공유되어 사용됩니다.
적용 대상은 다음과 같습니다.
Non-activate credit & activate credit 공통 적용 대상:
온디맨드 요금
RI/SP 할인
Private Price 할인
AWS Support 요금
Non-activate credit 일 때 Credit 할인제외 대상:
모든 종류의 선납금 제외 (예: Fee, SavingsPlanUpfrontFee)
MarketPlace 전체 요금 제외
ENT 이상 Support 또는 PLBS 요금 제외
Activate credit 일 때 Credit 할인제외 대상:
모든 종류의 선납금 제외 (예: Fee, SavingsPlanUpfrontFee)
Activate Credit이 적용되는 서비스를 제외한 Marketplace 요금
ENT 이상 Support 또는 PLBS 요금 제외
예시
고객사 A이 계정(AWS Account) 1, 2, 3을 포함하고 있다고 했을 때
크레딧 공유 옵션이 ON일 경우: 계정 1, 2, 3이 보유한 크레딧은 계정 1, 2, 3의 사용량에 구별없이 적용됩니다.
크레딧 공유 옵션이 OFF일 경우: 각 계정이 보유한 크레딧은 크레딧을 소유한 계정에만 적용되며 고객사 A 내의 다른 계정과 공유되지 않습니다.
RI/SP 공유 활성/비활성 옵션
AWS에서 RI/SP의 공유가 활성화되면 조직내 모든 계정에 RI/SP가 공유되며, 비활성화되면 RI/SP를 보유한 계정의 usage에만 RI/SP가 적용됩니다.
빌링 플랫폼에서는 고객사(계정 그룹) 단위에서 RI/SP의 공유 옵션이 제공되며 기본 상태는 활성화이며 비활성화는 지원하지 않습니다.
The settings view for credit and RI/SP sharing status.
[3] RI/SP 재계산
RI/SP 총량과 할인 금액 수집
Usage, DiscountedUsage, SavingsPlanCoveredUsage
RI는 각 AWS Account 에서 구매한 타입, 수량, RIFee을 기준으로 월 사용 가능량을 수집합니다.
CUR에서 구매한 RI DiscountedUSage과 Usage를 모두 수집하여 타입, 수량에 맞게 월 사용 가능량과 사용한 양과 비용을 AWS Price 단가와 곱하여 다시 재계산합니다.
SP는 각 AWS Account에서 구매한 타입, 수량, SavingsPlanCoveredUsage을 기준으로 월 사용 가능 금액을 수집합니다.
RI와 SP가 적용되지 않은 금액을 구하기 위해서 'DiscountedUsage', 'SavingsPlanCoveredUsage', 'Usage' 의 비용을 구합니다.
위에서 계산된 비용들은 각각 구매한 corp_id, account_id, 그리고 usage_type, region 등 맞춰서 정확하게 적용하도록 AWS Price 단가와 곱하여 다시 재계산합니다.
위의 로직대로 구한 할인 금액을 순서"10"에 제하여 RI/SP 적용 금액을 구할 수 있습니다.
[20] 크레딧 적용 방식
크레딧 공유 활성화 옵션에 따른 적용 대상 안내
크레딧 공유 옵션 설정 방법
빌링 플랫폼의 관리자 권한을 가지고 있는 사용자가 접근할 수 있는 고객사 목록 페이지에서 크레딧 공유 옵션을 변경 및 설정하고자 하는 고객사의 정보 수정 버튼을 클릭한 뒤, Additional Settings 탭의 Invoice Settings에서 고객사 단위로 크레딧 공유 옵션 설정을 ON/OFF 할 수 있습니다.
고객사 A이 계정(AWS Account) 1, 2, 3을 포함하고 있다고 했을 때
크레딧 공유 옵션이 ON일 경우: 계정 1, 2, 3이 보유한 크레딧은 계정 1, 2, 3의 사용량에 구별없이 적용됩니다.
크레딧 공유 옵션이 OFF일 경우: 각 계정이 보유한 크레딧은 크레딧을 소유한 계정에만 적용되며 고객사 A 내의 다른 계정과 공유되지 않습니다.
크레딧 공유 옵션 설정 및 크레딧 종류(Activate Credit/Non-Activate Credit)에 따른 크레딧 적용 대상
크레딧 공유 옵션 활성화 시
non-activate credit 적용 대상 = (온디맨드 요금 + RI/SP 할인 + Private Price 할인 + AWS Support 요금)
activate credit 적용 대상 = (온디맨드 요금 + RI/SP 할인 + Private Price 할인 + AWS Support 요금)
크레딧 공유 옵션 비활성화 시
non-activate credit 적용 대상 = (온디맨드 요금 + RI/SP 할인 + Private Price 할인 + AWS Support 요금) – (모든 종류의 선납금 e.g., Fee, SavingsPlanUpfrontFee) - (marketplace 전체 요금) - (ENT 이상 Support 또는 PLBS 요금)
activate credit 적용 대상 = (온디맨드 요금 + RI/SP 할인 + Private Price 할인 + AWS Support 요금) – (모든 종류의 선납금 e.g., Fee, SavingsPlanUpfrontFee) - (Activate Credit이 적용되는 서비스를 제외한 Marketplace 요금) - (ENT 이상 Support 또는 PLBS 요금)

## ACM-009 — 청구비용 재계산 (표의 칸을 줄 단위로 옮김)

[10] ACM-009
[20] 청구비용 재계산
구분
line_item__line_item_type
설명(고객사 기준)
AWS 비용 수집
'Usage'
MSP 회사에서 관리하고 있는 corp_id 기준으로 line_item__usage_amount * AWS Price 단가 금액 (티어링이 있는 경우 적용) 하여 비용 산출
CUR 데이터 중 가격표에 없는 경우 'line_item__unblended_cost' 을 사용합니다.
'RIFee', 'Fee', 'SavingsPlanUpfrontFee', 'SavingsPlanRecurringFee', 'Refund', 'Tax', 'Credit', 'EdpDiscount', 'AWS MarketPlace'
'해당 코드의 경우 CUR 컬럼인 'line_item__unblended_cost' 사용
RI/SP 총량과 할인 금액 수집
Usage, DiscountedUsage, SavingsPlanCoveredUsage
RI는 각 AWS Account 에서 구매한 타입, 수량, RIFee을 기준으로  월 사용 가능량을 수집합니다.
CUR에서 구매한 RI DiscountedUSage과 Usage를 모두 수집하여 타입, 수량에 맞게 월 사용 가능량과 사용한 양과 비용을  AWS Price 단가와 곱하여 다시 재계산합니다.
SP는 각 AWS Account에서 구매한 타입, 수량, SavingsPlanCoveredUsage을 기준으로 월 사용 가능 금액을 수집합니다.
RI와 SP가 적용되지 않은 금액을 구하기 위해서 'DiscountedUsage', 'SavingsPlanCoveredUsage', 'Usage' 의 비용을 구합니다.
위에서 계산된 비용들은 각각 구매한 corp_id, account_id, 그리고 usage_type, region 등 맞춰서 정확하게 적용하도록 AWS Price 단가와 곱하여 다시 재계산합니다.
위의 로직대로 구한 할인 금액을 순서"10"에 제하여 RI/SP 적용 금액을 구할 수 있습니다.
PPA 할인
(CFRC 등 각 계약에 의한 할인 금액)
고객과의 계약에 따라 각 고객에게 해당하는 단가를 따로 MSP 회사에서 관리하는 테이블에 저장하여 계약한 단가를 AWS 서비스의 Product_code, region, line_item__usage_amount와 곱하여 비용을 산출해 제공합니다
AWS Support 요금
고객사 기준으로 AWS에서 제공하는 Support 단가표(티어링 포함)와 Support과금 대상인 AWS Usage와 Fee + RIFee + SavingsPlanUpfrontFee + SavingsPlanRecurringFee 을 활용하여 Support 비용을 산출합니다.
단, AWS Marketplace와 Amazon EKS Anywhere, VMware Cloud on AWS 서비스는 과금 대상에서 제외합니다.
AWS Credit
Credit
line_item__line_item_description값에 표기되어 있는 Account ID 기준으로 AWS 크레딧을 모두 수집합니다. 그리고 MSP 회사에서 크레딧 공유 활성화 여부에 따라 아래와 같이 적용됩니다.
MSP 회사에서 크레딧 공유 활성화시 고객사별로 적용됩니다.
- non-activate credit 적용 대상 = (온디맨드 요금 + RI/SP 할인 + Private Price 할인 + AWS Support 요금)
- activate credit 적용 대상 = (온디맨드 요금 + RI/SP 할인 + Private Price 할인 + AWS Support 요금)
MSP 회사에서 크레딧 공유 비활성화시 고객사내 AWS 계정별로 적용되며 모든 종류의 선납금과 마켓플레이스 비용, ENT이상 Support 또는 PLBS 요금이 크레딧 적용 대상에서 제외됩니다
- non-activate credit 적용 대상 = (온디맨드 요금 + RI/SP 할인 + Private Price 할인 + AWS Support 요금) – (모든 종류의 선납금 e.g., Fee, SavingsPlanUpfrontFee) - (marketplace 전체 요금) - (ENT 이상 Support 또는 PLBS 요금)
- activate credit 적용 대상 = (온디맨드 요금 + RI/SP 할인 + Private Price 할인 + AWS Support 요금) – (모든 종류의 선납금 e.g., Fee, SavingsPlanUpfrontFee) - (Activate Credit이 적용되는 서비스를 제외한 Marketplace 요금) - (ENT 이상 Support 또는 PLBS 요금)
* AWS Price 단가표
아래 링크를 통해 단가표를 만들고 DB에 적재하여 사용하고 있습니다.
https://docs.aws.amazon.com/ko_kr/awsaccountbilling/latest/aboutv2/using-the-aws-price-list-bulk-api-fetching-price-list-files-manually.html

## ACM-010 (첫 문장만)

[10] ACM-010
MSP 회사어서는 자체 리빌링을 통해 SPP  계약상의 할인, EDP 계약상의 할인, AWS 와의 Private Pricing 을 통한 할인, SP/SR/Credit Sharing 등의 할인 내역을 제외하고, 실제 Usage * List Price 만을 재 계산한 후에, 개별 고객사 Tiering / SP / RI / Credit  적용등을 추가하여 합니다. 고객사는 Program related benefits 이 모두 가려진 빌링 데이터를  빌링 플랫폼 웹사이트를 통해 확인 할 수 있습니다.

## SPP-001 — MSP 회사의 모델 (본문 그대로)

[Heading2] MSP 회사의 모델
[Heading3] altware의 모델 개요
MSP 회사가 제공하는 최종 고객 계정 모델(ECAM)과 파트너 주도 지원 제공 모델의 주요 기능과 지원 방식에 대해 설명합니다. 고객은 본 문서를 통해 MSP 회사의 지원 모델을 활용하여 AWS 서비스를 효율적으로 사용할 수 있습니다
[Heading2] MSP 회사 최종 고객 모델
최종 고객 계정 모델 (End Customer Account Model, ECAM) ECAM은 최종 고객이 MSP 회사를 통해 AWS의 다양한 서비스를 직접 이용할 수 있도록 하는 모델입니다. 이 모델의 주요 내용은 다음과 같습니다.
[Heading3] 서비스 접근
최종 고객은 MSP 회사의 ECAM을 통해 AWS의 모든 서비스에 직접 접근하여 사용할 수 있습니다. 수수료, 지불, 가격 및 세금 조건은 계약에 명시된 대로 적용됩니다.
[Heading3] 청구 및 계정 관리
MSP 회사는 통합 청구 조직의 마스터 계정을 운영하며, 최종 고객 계정은 고객의 이메일 도메인으로 설정되어 각종 서비스 이용이 가능하도록 지원됩니다.
예시: <메일>
[Heading3] 재판매 방식
최종 고객이 소유한 AWS 계정을 통해 모든 서비스가 제공되며, MSP 회사는 이를 통해 고객에게 보다 효율적인 사용 및 관리를 지원합니다.
[Heading2] MSP 회사의 파트너 주도 지원 제공 모델 (Partner-Led Support Delivery Model)
파트너 주도 지원 제공 모델은 최종 고객이 AWS에 직접 지원 요청을 하지 않고, MSP 회사를 통해 모든 기술적 및 비기술적 지원을 받도록 하는 방식입니다.
[Heading3] 기술 지원
MSP 회사는 최종 고객이 문의하는 기술적 문제를 직접 해결하며, 필요 시 AWS의 안내를 받아 고객에게 정확한 솔루션을 제공합니다. 이를 통해 고객은 복잡한 문제를 보다 빠르고 간단하게 해결할 수 있습니다.
[Heading3] 비 기술적 지원
기술 외의 결제, 계정 관리 등의 문의도 MSP 회사가 직접 처리하여 고객의 편의를 돕습니다. MSP 회사의 통합된 지원은 고객의 서비스 사용 경험을 최적화하는 데 중점을 둡니다.
[Heading2] MSP 회사의 지원 강점
MSP 회사는 ECAM과 파트너 주도 지원 제공 모델을 통해 고객의 다양한 요구를 충족시킬 수 있는 최적의 AWS 솔루션을 제공합니다.
[Heading3] 통합 관리
MSP 회사의 ECAM 모델은 고객이 AWS 서비스에 쉽게 접근할 수 있도록 통합된 관리 환경을 제공합니다.
[Heading3] 전문 지원
파트너 주도 지원 모델을 통해 고객이 겪는 기술적 문제를 신속히 해결하고, 전문적인 상담과 안내를 받을 수 있도록 지원합니다.
[Heading3] 맞춤형 서비스
MSP 회사는 각 고객의 비즈니스 요구에 맞춘 맞춤형 솔루션을 제공하며, 이를 통해 AWS의 복잡한 서비스 구조를 간소화하여 고객의 업무 효율성을 높입니다.
[Heading2] 결론
MSP 회사의 ECAM 및 파트너 주도 지원 제공 모델은 고객의 다양한 비즈니스 요구를 충족시킬 수 있도록 설계되었습니다. 고객은 MSP 회사와의 협력을 통해 AWS 서비스를 효과적으로 사용하고, 필요한 지원을 원활히 받을 수 있습니다. MSP 회사의 체계적인 지원 모델은 고객의 성공적인 비즈니스 운영을 위한 필수적인 도구입니다.

## SPP-002 (머리 세 문장만 — Payer 목록은 옮기지 않음)

[Heading1] SPP-002
현재 총 3 개의 PLBS Payer Account에  101개의 Business Support Plan Account가 있으며 이 계정들은 PLS2.0 Payer account 전환 대상입니다.
신규 EDP 계약 시 대상이 되는 Payer 의 경우 EDP – ES 또는 EDP - PLS ( apply to every account in the payer ) 적용을 검토하고 있습니다.
모든 payer 관련 정보(Support, PLBS, Credit Sharing 여부, …)들은 payerManagenet.pdf 문서의 내용 대로  share point 상에서 중앙 관리되고 있습니다
