# 회사 규정 Raw 수신함

회사 규정 PDF, 이미지, DOCX, XLSX 등 정리 전 원본을 이 폴더에 그대로 넣어주세요.

## 사용 방법

1. 파일명이나 폴더 구조를 억지로 정리하지 않고 원본 그대로 넣습니다.
2. 파일 안의 자격증명, token, password, private key 여부는 가능하면 먼저 확인합니다.
3. 투입이 끝나면 어떤 묶음을 넣었는지만 알려주세요.
4. 에이전트가 문서 목록화 → text/OCR 추출 → 중복·버전 관계 확인 → policy card 생성 → routing 등록 순서로 정리합니다.

## Git 정책

이 폴더의 Raw 내용물은 `.gitignore`로 기본 제외됩니다. 이 `README.md`만 Git에 올라갑니다. 원본을 GitHub에도 보관해야 한다면 민감도·용량·Git LFS 사용 여부를 별도로 결정한 뒤 선택적으로 추적합니다.

## 주의

- API key, token, password, session credential, private key는 넣지 않습니다.
- 원본은 수정하지 않습니다. OCR·요약·정규화 결과는 다른 경로에 생성합니다.
- 동일 문서의 여러 버전이 있으면 모두 넣어도 됩니다. 임의로 최신본을 고르지 않습니다.
