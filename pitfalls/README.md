# Known Traps

Read relevant trap documents before translating a customer procedure into code or making a definitive support claim.

Every card follows `templates/pitfall.md`: when it happened (`observed`), which document or API it was
checked against, on what date and at which version (`sources`), and when it must be re-checked
(`review_by`). `scripts/validate_workspace.py` rejects a card that lacks any of these.

| Trap | Trigger |
|---|---|
| `bedrock-application-inference-profile-not-on-chat-completions.md` | Bedrock application inference profile(AIP)·비용 태깅을 OpenAI 호환 API(Chat Completions, `/openai/v1/chat/completions`)로 쓰려는 문의, `Application inference profiles are not supported by this API` |
| `bedrock-claude-blocked-after-organization-move.md` | AWS Organizations 이동·Payer 변경·신규 링크, Bedrock/Claude 사용 계정, 조직 이동 뒤 Claude 모델 접근 거부(`AccessDeniedException`, `model is not available for this account`) |
| `chime-end-of-support-is-not-chime-sdk.md` | Amazon Chime / Chime SDK 종료·EOL 문의, 2026-02-20 지원 종료 공지, `Chime` namespace, 이름이 비슷한 서비스의 공지 혼동 |
| `ec2-mtu-9001-is-a-guest-os-setting.md` | EC2 MTU 9001·점보 프레임의 배경·기본값 문의, VPN·Transit Gateway 경유 MTU, 비-Amazon Linux(RHEL 계열·Windows) 인스턴스 |
| `fargate-task-retirement-order-is-set-by-maximum-percent.md` | Fargate task retirement·platform version revision 교체 알림(`AWS_ECS_TASK_PATCHING_RETIREMENT`), `minimumHealthyPercent`/`maximumPercent`, 태스크 교체 순서·무중단 여부 문의 |
| `billing-platform-savings-plans-applied-amount-is-not-savings.md` | 빌링 플랫폼 Trend·비용 화면의 Savings Plans 적용 금액(`ApplySavingsPlan*`), SP 할인액·절감액 문의 |
| `nlb-target-reset-count-has-no-target-group-dimension.md` | NLB `TCP_Target_Reset_Count`·리셋 지표로 원인 추정, NLB 뒤 간헐 5xx·연결 끊김, 타깃그룹별 지표 조회 |
| `oracle-onprem-dr-to-aws-rds-dms-and-licensing.md` | 온프렘 Oracle → AWS DR·이행, Data Guard standby 를 RDS 로, DMS CDC 와 TDE(LogMiner·Binary Reader), EC2 Oracle BYOL 라이선스 수량·Core Factor, standby 라이선스·10일 룰 |
| `ses-without-identities-starts-with-verification.md` | Amazon SES 신청·사용 요청, 샌드박스 해제·프로덕션 액세스 요청, 신원(이메일·도메인) 미등록 계정 |

A trap is a routing warning, not standalone proof. Re-verify the active environment and official specification for each ticket.
