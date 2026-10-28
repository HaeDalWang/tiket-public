# 0035. Kiro 는 쓰기 호출을 deny 로 막고, 이미 설치된 PC 의 규칙은 세션 시작이 새 것으로 맞춘다

- **언제**: 2026-10-04
- **정한 것** (유지보수자 — 자기 평가의 2번, [[2026-10-04-hardening]]):
  - `scripts/kiro_permissions.py` 가 넣는 규칙에 **deny** 를 더한다: `aws` 쓰기 동사·`s3` 쓰기, `curl` 의 쓰기 호출
    (`-X POST|PUT|PATCH|DELETE`, `-d`·`--data`·`--json`·`-F`·`-T`), AWS 를 실행하는 MCP 도구 다섯(`.claude/settings.json` 의 deny 와 같은 이름).
  - `aws * start-query*`·`stop-query*` 는 deny 에서 뺀다 — Logs Insights·Athena 조회다. 비밀을 돌려주는 읽기와 `>` 는 지금처럼 묻는다.
  - 이미 우리 블록이 든 PC 는 세션 시작(`local_capabilities.py`)이 지금 규칙으로 다시 쓴다(백업 포함, 바꾼 날만 한 줄).
    블록이 없는 PC 에는 넣지 않는다 — 설치는 본인이 온보딩으로 한다(0030 그대로).
- **왜**: `CLAUDE.md` 의 "고객 계정 쓰기 API 를 부르지 않는다" 가 Kiro 에서는 글뿐이었다. 0030 의 규칙은 허용과 "도로 묻기" 만 했고,
  Kiro 를 Trust All Tools 로 쓰면 묻기는 그냥 통과한다. 동료 다수가 Kiro 다.
- **확인한 것** (2026-10-04, 진짜 Kiro 0.66.22, `--trust-all-tools`, 임시 폴더에 이 규칙을 넣고 무해한 탐침 명령으로):
  - Trust All 이어도 deny 는 막는다 — `aws ec2 delete-…`, `aws --profile x s3 rm …`, `curl -X POST`, `curl -d` 전부 차단.
  - deny 규칙의 `exclude` 가 먹는다 — `aws logs start-query…` 는 실행됐다. 공식 문서는 allow 의 예만 든다.
  - MCP 의 서버 자리 와일드카드가 먹는다 — `*/aws___retrieve_skill` 이 `@aws-mcp/aws___retrieve_skill` 을 막았고 `aws___list_regions` 는 실행됐다.
  - `curl` GET 은 실행됐다.
- **한계**:
  - 벽이 아니라 문턱이다. glob 은 `python -c`·스크립트 파일·변수 치환으로 우회된다. 벽은 토큰 범위와 브로커다.
  - 읽기 호출의 인자에 ` delete-` 같은 문자열이 있으면 막힌다(거짓 양성).
  - Windows 는 Kiro 의 폴더 해시를 몰라 규칙을 못 넣는다(0030 의 한계 그대로). 규칙을 안 넣은 PC 에는 deny 도 없다.
  - Zendesk 쓰기는 `curl` deny 가 문턱일 뿐이다 — 토큰은 여전히 쓸 수 있다. OAuth `read` 범위 이전은 보류했다([[2026-10-04-hardening]]).
