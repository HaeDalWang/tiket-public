---
id: GUIDE-MONITOR-001
title: SLT baseline: recovery targets, alarm codes, and backup defaults
status: active
applies_to: [monitoring, slt, rto, rpo, cloudwatch-alarm, backup, guardduty]
triggers: [slt, rto, rpo, cloudwatch, alarm, threshold, 임계치, 관제, monitoring, backup, 백업, alarm-level, L1, L2, L3]
source_location: "SPT-008 (8.1.3 RTO·RPO, 8.1.4 자산 별 복구 Level·알람 적용 코드, 8.1.5 백업 정책)"
applicability: "[team: MSP] Reference baseline when a ticket concerns monitoring setup, alarm thresholds, recovery targets, or backup for a customer with the monitoring service"
source_document: SRC-FTR-SPT-001
source_owner: "The MSP — document submitted to AWS for the Partner-Led Support FTR"
source_version: "[MSP 회사] Support Operations(SPT).docx, FTR-PLS 2.0 (deck NEW_PLS_FTR_MSP_202411, 2024-11)"
effective_from: 2026-10-08
reviewed_at: 2026-10-08
reviewed_by: Claude Code
review_by: 2027-04-08
authority_verified_at: "2026-10-08"
approved_by: repository owner
approved_at: "2026-10-08"
activation_blocker: ""
retired_at: ""
retirement_reason: ""
replacement: ""
supersedes: ""
---

# SLT baseline: recovery targets, alarm codes, and backup defaults

## Control statement

Monitoring is set up from a Service Level Target (SLT) document agreed with each customer. This card holds the standard baseline that agreement starts from — recovery targets by business class, the alarm codes with their thresholds, and the default backup rules. It describes the template, not what a given customer agreed to.

## Scope

- Applies when: a ticket asks what the MSP monitors, why an alarm fired, which threshold or level applies, or what the standard recovery or backup target is.
- Does not apply as: a commitment to a specific customer. The customer's own SLT document governs.

## Required behavior

1. Before quoting any value to a customer, check that customer's SLT document. If it is not available, say the value is the standard baseline and ask the engineer to confirm.
2. Describe recovery values as targets (`POLICY-SUPPORT-001`).

Business classes and recovery targets:

| Class | Meaning | RTO | RPO |
|---|---|---|---|
| 핵심업무 | Core external business; immediate response on failure | within 2 hours | within 1 hour |
| 주요업무 | External business; continuity can be kept another way | within 6 hours | within 24 hours |
| 일반업무 | Everything else, or low importance | within 24 hours | within 24 hours |

Per-service targets in the sample: 핵심업무 — EC2 and EBS RPO 24h / RTO 2h, RDS and ALB RPO 1h / RTO 2h. 주요업무 — EC2, EBS, RDS RPO 24h / RTO 6h, ALB RPO 1h / RTO 6h. The base backup is daily with 30-day retention, with more by service.

Alarm codes (measured every minute; levels are the source's 알람 레벨 column, with the top step corrected to 3 — see Exceptions):

| Code | Metric | Threshold → level | Evaluation |
|---|---|---|---|
| `EC2-C` | CPUUtilization | 70 → 1, 80 → 2, 95 → 3 | 3 times in 5 min (80: 5 times) |
| `EC2-M` | mem_used_percent (CWAgent) | 70 → 1, 80 → 2, 95 → 3 | 3 times in 5 min (80: 5 times) |
| `EC2-F` | CWAgent data missing | 1 → 3 | 3 times in 3 min |
| `EC2-D` | disk_used_percent (CWAgent) | 70 → 1, 80 → 2, 95 → 3 | 3 times in 5 min (80: 5 times) |
| `EC2-S` | StatusCheckFailed | above 0 → 3 | 2 times in 2 min |
| `EC2-O` / `EC2-I` | ASG CPUUtilization | 70 scale-out → 1 / 49 or below scale-in → 1 | 3 in 3 min / 15 in 15 min |
| `EBS-Q` | VolumeQueueLength | 1 → 1, 3 → 2 | 3 / 5 times in 5 min |
| `ELB-H` | HealthyHostCount | 0 → 3 | 2 times in 2 min |
| `ELB-E5` | HTTPCode_ELB_5XX_Count | 1 → 1 | 3 times in 5 min |
| `RDS-C` | CPUUtilization | 70 → 1, 80 → 2, 95 → 3 | 3 / 5 / 5 times in 5 min |
| `RDS-M` | FreeableMemory | 30% or less → 1, 20% → 2, 5% → 3 | 3 / 5 / 5 times in 5 min |
| `RDS-D` | free storage | 30% or less → 1, 20% → 2, 5% → 3 | 3 / 5 / 5 times in 5 min |
| `RDS-Q` | DiskQueueDepth | 1 → 1, 3 → 2 | 3 / 5 times in 5 min |
| `R53-H` | Health Check Status | 0 → 3 | 2 times in 2 min |
| `CF-E5` | TotalErrorRate | 20% → 1, 50% → 2 | 3 times in 5 min |
| `GD-F` | GuardDuty finding | medium severity or higher → 3 | on event |

What each level sets off — **for customers with a 24x7 contract only**. For every other customer no phone call or wake-up follows from an alarm level:

| Level | What happens |
|---|---|
| 1 | Nothing further |
| 2 | Keeps sounding at the COC. When it has sounded three times or more, the COC phones the customer |
| 3 | The COC phones the customer on the first occurrence |

After the call: if the customer recognizes the situation and it is urgent, the COC wakes the assigned MSP engineer (`POLICY-COC-001`).

Default backup rules: production EC2 — daily, and on install or upgrade, kept 3 years; development EC2 — the same, kept 1 year; DB data — continuous backup kept 30 days, monthly backup kept 3 years, and on request; general files — on request, retention per object. Cloud backup runs daily at 03:00 with AWS Backup.

## Prohibited behavior

- Do not present a baseline value as what the customer agreed to.
- Do not change an alarm, a threshold, or a backup rule; this repository does not change infrastructure.
- Do not describe a recovery target as a guarantee or a compensation-bearing commitment.

## Exceptions and escalation

- In the source the top step of each three-step alarm (95% for CPU, memory, and disk; 5% free for RDS memory and storage) is written as level 2, the same as the middle step. The repository owner confirmed on 2026-10-08 that this is a typo and the top step is level 3; the table above carries the correction and the excerpt keeps the source as written. Two-step alarms (`EBS-Q`, `RDS-Q`, `CF-E5`) are left as the source has them.
- The level table above is the working practice as the repository owner described it; the source only says alarms are passed on in L1, L2, L3 steps "as agreed with the customer". A customer's own SLT document can set something different.
- The source's availability-goal cells for the sample business units are blank. No availability figure is given here.
- The standard terms say a monitoring alarm is acknowledged within 15 minutes (`SRC-BILLING-TERMS-001`, cited by `POLICY-SUPPORT-001`); this document does not repeat that figure.

## Evidence

- Source document: `SRC-FTR-SPT-001` (excerpt in `policy/excerpts/`)
- Page/section: SPT-008 — 업무 평가 우선순위에 따른 RTO·RPO 기준, 자산 별 복구 Level 및 평가, 알람 적용 코드, 백업 대상 선정
- Verbatim source excerpt (table rows, cells joined by ` | `):

> 장애 복구를 위한 목표 시간(RTO) | - 2시간 이내 | 핵심업무
> 장애 발생 시 유실 데이터의 규모(RPO) | - 1시간 이내 | 핵심업무
> EC2 | CPU | CPUUtilization | EC2 | 70 | EC2-C | 1 | 5분간 3회 이상 | 1 | CPU 사용률 70% 이상
> DB 데이터 | 자동 연속 백업을 통하여 지속적인 데이터(RDS DB) 전체 백업 수행 월 1회 정기적인 백업 수행 백업 요청에 따른 비정기 백업 수행 | 연속 백업 30 일 월 백업 3년

## Change history

- 2026-10-08 — Created and activated from the FTR-PLS 2.0 Support Operations document. The repository owner (final approver for these cards) stated the document is the one defined between the MSP and AWS and is in force.
