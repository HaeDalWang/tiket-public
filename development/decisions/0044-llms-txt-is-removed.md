# 0044. `llms.txt` 를 없앤다 — AI 온보딩 안내 파일은 필요 없다

- **언제**: 2026-10-24
- **정한 것** (유지보수자 — "키는 어차피 사람이 넣는다, AI 온보딩 안내 파일은 필요 없다"):
  - `llms.txt` 를 지운다.
  - 진입 파일 목록에서 뺀다 — `scripts/check-freshness.sh`·`.ps1` 의 `ENTRY_FILES`, `scripts/export_framework_snapshot.py` 의 `ROOT_FILES`.
  - README 빠른 시작 2단계의 "AI에게 부탁" 은 **확인과 해석만** 맡긴다 — `bash scripts/onboarding.sh --check` 를 돌리고 결과를 설명해 달라고.
    키 입력은 사람이 터미널에서 한다.
- **왜**:
  - 온보딩의 핵심은 키·자격증명 입력이고, 그건 사람만 할 수 있다. `onboarding.sh` 가 터미널에서 대화형으로 묻는다. AI 가 대신할 수 있는 일은 `--check` 를 돌려 읽어 주는 것뿐이다.
  - 파일이 이미 낡았다. 4단계가 옛 `install.sh` 를 가리키고, ITSM 토큰 단계(7단계)가 없다. 고칠 거리가 있는 파일을 계속 두면 동료의 AI 가 낡은 절차를 따른다.
  - AI 온보딩이 대화형 실행을 막아 지표가 조용히 빠진 전례가 있다([[0026-ticket-lessons-flow-to-a-candidate-table]] 2026-09-29 덧붙임).
  - 2026-09-11 검토에서도 "네 번째 진입점, 재검토" 였다([[2026-09-11-framework-review]]).
- **잃는 것 없음**: 지표 고지는 `onboarding.sh --check` 가 AI 가 돌려도 항상 출력한다(`usage_notice`). `llms.txt` 가 따로 전해 줄 필요가 없었다.
  AI 가 `--check` 결과를 사용자에게 옮기는 일은 README 의 해석 요청이 맡는다.
- **대체 경로**: README 빠른 시작 2단계의 `--check` 해석 요청. 단계별 읽는 법은 `ONBOARDING.md` 에 있다.
- **버린 선택지**: `llms.txt` 를 고쳐서 두는 것 — 키 입력은 어차피 사람이 하고 `--check` 출력이 이미 사람이 읽을 수 있는 말이라, 고칠 이유가 없다.
- **근거**: `git grep -n llms`, `development/backlog.md` (이 항목을 지웠다), `scripts/onboarding.sh` (`usage_notice`)
