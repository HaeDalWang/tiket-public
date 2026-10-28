# Policy Source Inventory

Raw source files are local and gitignored under `policy/inbox/`. This inventory contains no personal phone numbers, credentials, or customer account examples. A source hash identifies the exact reviewed text even if its filename is later normalized.

`Authority/applicability` describes what the text appears to be; it is not approval. Until a human owner confirms authority, all derived cards remain `draft`.

| Source ID | Document title | Type | Source metadata | Authority/applicability | Lines | SHA-256 | Derived card(s) |
|---|---|---|---|---|---:|---|---|
| `SRC-CUSTOMER-SECURITY-001` | 고객 보안 정보 보관 및 공유 관련 주의사항 | mandatory security guide | updated 2026-02-10 | states mandatory; security-owner approval not recorded | 288 | `6402c546d616cbb0109d8dc37fc16d520139c3710ab25f0f5c6612d26eb0670e` | `POLICY-SEC-001` |
| `SRC-EMPLOYEE-LIFECYCLE-001` | 직원 온·오프보딩 가이드라인 | HR lifecycle guide | updated 2026-02-10; HR Team | HR/IT workflow; current approval unconfirmed | 465 | `873d7d805d2a2274d2d47c0d59764dec581756df9a3807f0745a45b31d6077eb` | `POLICY-ACCESS-001` |
| `SRC-CSG-JD-001` | CSG Job Description | aggregate role reference | no version/date | aggregate role reference; precedence unconfirmed | 239 | `8d0d865d91084c53676d019b0ed3ab8c8e0b3cd08f9cf02956d5cb9ef40190e6` | `GUIDE-ROLE-001` |
| `SRC-CSG-RISK-001` | CSG 리스크 관리 | risk register/checklist | v1.0; updated 2026-02-12; review due 2026-05-12; marked CSG Leadership approved | review overdue; customer-contract precedence required | 458 | `489a06cc86ffba7084c3a25b70b360942a8f1b51d8c0617048fd161032e8aadc` | `POLICY-RISK-001` |
| `SRC-CUSTOMER-OFFBOARD-001` | 고객 Offboarding 프로세스 및 데이터 관리 | operational process | v1.0; updated 2026-02-12; review due 2026-05-12; marked CSG Leadership approved | review overdue; contract/legal precedence required | 670 | `e31efb255394305a70cbd615b97b34dd7e44e3bf804b4a7bdb45d3b7baf68d60` | none (`POLICY-OFFBOARD-001` deleted 2026-10-01); conflict input to `POLICY-SEC-001` |
| `SRC-STANDALONE-PAYER-001` | 단독 Payer 관리 방안 | service-model guide/roadmap | updated 2026-02-20; CSG Team; reviewed by CSG leadership | mixes current process, fees, targets, and roadmap | 766 | `7aa9991598ae354011137184c0c2dc536835e16972bb905be585ddb4a6aee256` | `POLICY-PAYER-001` |
| `SRC-CUSTOMER-ONBOARD-001` | 고객 Onboarding 체크리스트 | implementation checklist | v1.0; updated 2026-02-12; review after retrospective | blank approvals; checklist is not execution authority | 468 | `ca56fd9e3bbe1df0f5f8def4d02dace1ca72d0e1163777639264319fb90dcecf` | `GUIDE-ONBOARD-001` |
| `SRC-MIGRATION-MEETING-001` | 클라우드 마이그레이션 첫 비즈니스 미팅 가이드 | discovery guide | updated 2026-02-10; SA Team | guidance; contains contract-dependent marketing claims | 304 | `60093dd2294135dc67972708fa4f8a84a62c8eb0dd94075d402db16a1685597b` | none (`GUIDE-MIGRATION-001` deleted 2026-10-01) |
| `SRC-BILLING-TERMS-001` | 빌링 플랫폼 MSP 서비스 표준 약관 | standard contract terms | effective 2025-04-02 | applies only when accepted and subject to customer-specific SLA/SOW | 251 | `8ad61b05dc3513085aaf1d45c5728e0b8798b86246ca9cd57e69d0074c0c6ad2` | `POLICY-SUPPORT-001`, `POLICY-DATA-001` |
| `SRC-SA-JD-001` | SA Team Job Description | team role reference | no version/date | richer variant; precedence versus aggregate unconfirmed | 97 | `5e3260629e88927b97b647d732de2859937d8342bdbe96cfa39aaace5c25b69e` | `GUIDE-ROLE-001` |
| `SRC-MSP-JD-001` | MSP Team Job Description | team role reference | no version/date | richer variant; precedence versus aggregate unconfirmed | 87 | `0a72207ca78c5071da389eda5e34cbe61529c79e49794b740d84e659e56301d7` | `GUIDE-ROLE-001` |
| `SRC-TS-JD-001` | TS Team Job Description | team role reference | no version/date | richer variant; precedence versus aggregate unconfirmed | 79 | `14827e3068c50aefbc1f0e55c5afd3290cd724422d16292355add7fe1fecbea1` | `GUIDE-ROLE-001` |
| `SRC-AI-JD-001` | AI Team Job Description | team role reference | no version/date | richer variant; precedence versus aggregate unconfirmed | 71 | `df09e1932cf13a5edc4dfd1a518163d3f4f2e447bcb5cca1af2a8efa984b3166` | `GUIDE-ROLE-001` |
| `SRC-COP-JD-001` | COP Team Job Description | team role reference | no version/date | richer variant; precedence versus aggregate unconfirmed | 69 | `5164ad0a34b86598bb9303e6fb7a24df6b554caaef99c6af69182ecd875fce4a` | `GUIDE-ROLE-001` |
| `SRC-HR-STRUCTURE-001` | HR 체계 | organization/level notes | no version/date | incomplete reference; no ticket control promoted | 106 | `4b0e81248c94e9c22c3762e92e896475ee3409225a77d78d2ecc0a8c6484e92e` | none |
| `SRC-COC-GUIDE-001` | COC 노티 가이드 | live operational notes/roster | mixed updates 2024-2026; contains PII | current roster and procedure must be verified live | 270 | `96fd63751e5f8e872a4cfd40a6ef4dfbf77d7f6dbaf97653d0fe779f53d1c5f9` | none (`POLICY-INCIDENT-001` deleted 2026-10-01) |
| `SRC-TS-NOTES-001` | TS 주요 사항 | internal working notes | no version/date; contains access hints and PII | supporting reference only; shared remote-support procedure retired | 119 | `3787dd65ffad1917b6e9165403f70ea22a100f5bc721f4ae67685d2e6f9ce14d` | none (`POLICY-REMOTE-001` deleted 2026-10-23) |
| `SRC-COP-QA-001` | COP Q&A / CMP팀 질문 정리 | internal Q&A and examples | no version/date; contains customer/account examples | implementation details require live COP verification | 96 | `f777d44a47e579a4c8235e6c672b08f4bc4676ecd061d16c5af6d10fe03c4a14` | `GUIDE-BILLING-001`; sensitive examples excluded |
| `SRC-COST-ESC-001` | 비용 문의 CSR 인계 절차 | de-identified live Slack announcement excerpt | announced 2026-08-26 10:05 KST; MSP team lead; MSP 주요 사항 updated | active operational handoff process; exact icon and hour interpretation require live entry | 41 | `d71860a14dcc83ab67e8bd555ec5c49be5cf79e01698a03ac048fe7e45a75b6e` | `POLICY-COST-ESC-001` |

## Ingestion result
| `SRC-SUPPORT-PLAN-001` | 빌링 플랫폼 기준 AWS Support Plan 설명 | de-identified pasted reference + table screenshot | captured 2026-10-01; table column dated 202603; no owner or version | senior-executive (경영진) instruction to activate, relayed by repository owner; not independently verified | 43 | `b2e595de77b89f34d336151983244eaabea56b9bf6e0af6469b480305348570e` | `GUIDE-SUPPORT-PLAN-001` |
| `SRC-TAM-001` | MSP 팀 내부 사항 — AWS TAM 요청 조건 | de-identified Slack message excerpt | Slack; channel and date not recorded; no owner or version | repository owner confirmed the text on 2026-10-01 | 22 | `3b28dc76fc6fe1077ac187074985e0e2e40b879d11293b9cad71f7f206019514` | `POLICY-TAM-001` |
| `SRC-OT-001` | 야간 및 공휴일 긴급 대응시 티켓 관리 (2025.4.10) | de-identified Slack message excerpt | Slack; channel and date not recorded; no owner or version | repository owner confirmed the text on 2026-10-01 | 20 | `b760843586342ed11307b325befce84ac2d549de548f2c758830df8517ab6508` | `POLICY-OT-001` |
| `SRC-CASE-001` | AWS Support Case 를 여는 계정 안내 | de-identified Slack message excerpt | Slack; channel and date not recorded; no owner or version | repository owner confirmed the text on 2026-10-01 | 25 | `8497a7fbaafeddf227eff887c7e26a486b38f8f3665f42afc19bfb5d10f68bf5` | `POLICY-CASE-001` |
| `SRC-CASE-002` | Basic Support 계정의 기술 케이스 | de-identified verbal-rule excerpt | no written original; set verbally within the MSP team | repository owner wrote it down and confirmed it on 2026-10-08 | 20 | `ed769a3d7e79df5e990e885c056075764d1f19994d094eb213a49583b015bbe1` | `POLICY-CASE-002` |
| `SRC-K8S-001` | 쿠버네티스 기술지원 범위와 에스컬레이션 | de-identified verbal-rule excerpt | no written original; set verbally within the MSP team | repository owner wrote it down and confirmed it on 2026-10-08 | 20 | `d359ca42e61d145467e942f0d2631443abffdd75b72f023ee0feea1c8f2880aa` | `POLICY-K8S-001` |
| `SRC-FTR-SPT-001` | Support Operations (SPT) — FTR-PLS 2.0 | de-identified internal document excerpt | submitted to AWS for the PLS FTR, 2024-11; original local only | repository owner stated on 2026-10-08 that it is the document defined between the MSP and AWS and in force | 384 | `96f132406e13688df71242d1a834372518e85c1aadce4f45257ef395c4a0275e` | `POLICY-ESC-001`, `POLICY-COC-001`, `GUIDE-MONITOR-001`, `GUIDE-HEALTH-001`, `POLICY-SUPPORT-001`, `POLICY-CASE-002` |
| `SRC-FTR-ACM-001` | AWS Account Management (ACM) — FTR-PLS 2.0, ACM-003·004·006·007 | de-identified internal document excerpt | submitted to AWS for the PLS FTR, 2024-11; original local only | repository owner stated on 2026-10-08 that it is the document defined between the MSP and AWS and in force | 385 | `6756c8bee846ec1d904fc4bfbcdb2144ee4dee946a554f8a3390c7528b7a5d39` | `POLICY-ACCESS-002`, `GUIDE-ONBOARD-001`, `POLICY-DATA-001` |
| `SRC-FTR-BILL-001` | Billing and rebilling — FTR-PLS 2.0, BIL-001·002, RBL-001·002, ACM-009·010, SPP-001·002 | de-identified internal document excerpt | submitted to AWS for the PLS FTR, 2024-11; original local only; Payer list and customer names left out | repository owner stated on 2026-10-08 that it is the document defined between the MSP and AWS and in force | 269 | `a92d7cf0e6596d31dae448d00e5c7d4386b6625a1e84569be8e656814bbc11dd` | `POLICY-BILL-001`, `GUIDE-BILLING-001`, `POLICY-PAYER-001` |
| `SRC-FTR-STD-001` | Root, IAM, CloudTrail standards — FTR-PLS 2.0, ARC-001~004, IAM-001~005, CTL-001~004 | de-identified internal document excerpt | submitted to AWS for the PLS FTR, 2024-11; original local only; standard statements only | repository owner stated on 2026-10-08 that it is the document defined between the MSP and AWS and in force | 238 | `35d3edf67e3449c6149fb541d904343bb7d5e8e30a57b8859efcea5dad77c2a0` | `POLICY-ROOT-001`, `GUIDE-IAM-001`, `GUIDE-CTL-001` |

- Raw text files inventoried: 18
- Tracked de-identified source excerpts: 5
- Exact duplicate hashes: 0
- Credential signature scan: clear
- Raw personal contacts/customer examples: present in some files and intentionally not copied into tracked cards
- Review date: 2026-08-24 KST

## Status rules

- `active`: human owner confirmed both authority and current applicability
- `draft`: extracted control awaiting owner confirmation
- `superseded`: retained for historical interpretation and linked to its replacement
- `retired`: no longer applicable and has no direct replacement
- `unknown`: authority, version, or applicability has not been verified
