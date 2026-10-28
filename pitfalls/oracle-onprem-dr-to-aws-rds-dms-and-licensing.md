---
observed:
  - 2026-10-07 | ticket 100017
sources:
  - 2026-10-19 | aws-doc | https://docs.aws.amazon.com/prescriptive-guidance/latest/replatform-oracle-database-options/migration-tools.html | 표기 없음
  - 2026-10-19 | aws-doc | https://aws.amazon.com/rds/oracle/faqs/ | 표기 없음
  - 2026-10-19 | aws-doc | https://docs.aws.amazon.com/dms/latest/userguide/CHAP_Source.Oracle.html | 표기 없음
  - 2026-10-19 | vendor-doc | https://www.oracle.com/us/corporate/pricing/cloud-licensing-070579.pdf | policies in effect as of September 4, 2026
  - 2026-10-19 | vendor-doc | https://www.oracle.com/us/corporate/pricing/data-recovery-licensing-070587.pdf | policies in effect as of December 15th, 2024
review_by: 2027-04-17
---

# 온프렘 Oracle 을 AWS 로 DR·이행할 때 RDS 를 Data Guard standby 로 붙이고, DMS·라이선스 제약을 온프렘이나 RDS 한쪽 기준으로 일반화하기 쉽다

## 무엇을 하면 틀리는가

- 온프렘 Oracle 을 primary 로 두고 **RDS for Oracle 을 Data Guard standby** 로 붙일 수 있다고 안내한다.
- DMS 의 "컬럼 레벨 TDE 는 LogMiner CDC 불가" 를 **소스가 어디든** 적용한다 — 온프렘 소스에도 안 된다고 답한다.
- EC2 BYOL 라이선스를 온프렘처럼 **코어 수 × Core Factor(0.5 등)** 로 센다.
- DR standby 는 **실행할 때만**, 또는 **10일 룰** 안이면 라이선스가 필요 없다고 답한다.

한 문의(온프렘 → AWS 연속 DR, 이후 이행) 안에서 셋이 같이 나왔다.

## 실제로 있었던 일

- 2026-10-07(후보 등록일): 온프렘 Oracle 의 AWS DR·이행 문의에서 세 가지가 교훈 후보로 올라왔다 — RDS 를 standby 로 붙일 수
  없다는 것, DMS TDE 제약이 RDS 소스에만 해당한다는 것, EC2 BYOL 라이선스 세는 법. 2026-10-19 유지보수자가 문서로 다시 확인하며
  standby 라이선스 표현을 고쳤다(변경 이력).

## 확인된 사실

**RDS 는 온프렘 primary 의 Data Guard standby 가 될 수 없다**

- AWS Prescriptive Guidance: Oracle Data Guard 는 RDS for Oracle·RDS Custom for Oracle 로의 이행에 **직접 쓸 수 없다**. 대신 EC2 에
  physical standby 를 만들고 DMS·Data Pump 로 RDS 에 옮기는 식으로 쓴다
  (https://docs.aws.amazon.com/prescriptive-guidance/latest/replatform-oracle-database-options/migration-tools.html).
- RDS for Oracle read replica 는 **RDS primary 와 replica 사이에** Oracle Active Data Guard 를 구성한다(https://aws.amazon.com/rds/oracle/faqs/).
  → 온프렘에서 이어지는 DR 은 EC2 self-managed Data Guard 가 맞고, RDS 는 클라우드로 옮긴 뒤의 선택지다.

**DMS 의 TDE 제약은 RDS 소스일 때 이야기다**

- DMS Oracle source 문서의 LogMiner·Binary Reader 비교 표: LogMiner 는 "does not support TDE encryption on column level for **Amazon RDS
  for Oracle**", Binary Reader 는 "supports TDE only for **self-managed** Oracle databases".
- 같은 문서의 암호화 표는 LogMiner·Binary Reader 모두 TDE tablespace·TDE column 을 Yes 로 적고, Binary Reader 는 엔드포인트에 TDE
  키·암호를 지정해 쓴다고 설명한다 (https://docs.aws.amazon.com/dms/latest/userguide/CHAP_Source.Oracle.html).

`unknown` — 후보가 적은 "온프렘 소스에서 LogMiner 로 컬럼 TDE 를 읽으려면 wallet 이 열려 있어야 한다" 는 AWS 문서에서 확인하지 못했다.
쓰려면 Oracle 문서를 찾아 `sources` 에 더한다.

**EC2 BYOL 은 vCPU 로 세고 Core Factor 는 없다**

- Oracle *Licensing Oracle Software in the Cloud Computing Environment*: Amazon EC2·RDS 는 multi-threading 이 켜져 있으면 **vCPU 2개 = Processor
  라이선스 1개**, 꺼져 있으면 vCPU 1개 = 1개. "the Oracle Processor Core Factor Table is not applicable"
  (https://www.oracle.com/us/corporate/pricing/cloud-licensing-070579.pdf).

**DR standby 는 설치만 해도 라이선스 대상이고, 10일 룰은 Data Guard 에 해당하지 않는다**

- Oracle *Licensing Data Recovery Environments*: 복사·동기화·미러링(Standby, Remote Mirroring) 방식의 DR 은 설치되었거나 실행 중인
  Oracle 프로그램을 **모두** 라이선스해야 하고, DR 시나리오 테스트를 위한 설치도 포함한다. 운영과 DR 의 라이선스 메트릭·옵션은 같아야
  한다(RAC 등 예외 둘).
- 10일 룰은 **한 데이터센터 안에서 디스크 하나를 같이 쓰는 클러스터의 failover 노드**에만 적용된다
  (https://www.oracle.com/us/corporate/pricing/data-recovery-licensing-070587.pdf). 데이터를 복사하는 Data Guard standby 는 처음부터 대상이 아니다.

## 해야 할 것

1. 온프렘 primary 의 AWS DR 은 EC2 self-managed Data Guard 로 안내한다. RDS 를 standby 로 붙일 수 있다고 쓰지 않는다.
2. DMS CDC 제약을 말하기 전에 **소스가 RDS 인지 self-managed(온프렘·EC2)인지** 먼저 적는다. self-managed 면 Binary Reader + 엔드포인트
   TDE 키 지정이 길이다.
3. EC2 BYOL 수량은 instance 의 vCPU 와 multi-threading 설정으로 센다. Optimize CPU(코어 수·threads per core)로 줄일 수 있다고 함께 적는다.
4. standby 라이선스는 "설치·실행되면 운영과 같은 메트릭으로 필요" 로 쓰고, 10일 룰을 근거로 면제된다고 쓰지 않는다.
5. 라이선스는 Oracle 계약이 최종 기준이다 — 고객 계약·Oracle 확인이 필요하다는 한 줄을 남긴다. 금액은 쓰지 않는다.

## 다시 쓰기 전에 확인할 것

- 두 Oracle 정책 PDF 하단의 "policies in effect as of" 날짜가 바뀌었는지. 바뀌었으면 해당 문장을 다시 읽는다.
- DMS 비교 표의 TDE 행 문구 — RDS 와 self-managed 를 가르는 표현이 그대로인지.
- RDS for Oracle 에 외부 primary 를 받는 기능이 새로 나왔는지 — AWS 문서 검색으로 본다.

## 변경 이력

- 2026-10-19: 작성. 같은 티켓에서 승인된 교훈 후보 셋(Data Guard·DMS TDE·BYOL)을 한 장으로 합쳤다. 승인 때 후보의 근거가 지워져
  경위는 후보 요약에서만 가져왔다. 후보의 "standby 도 running 이면 라이선스" 를 Oracle 문서대로 "설치·실행되면" 으로, "10일 룰은 클라우드
  standby 미적용" 을 "공유 스토리지 클러스터 failover 에만 적용" 으로 고쳤다.
