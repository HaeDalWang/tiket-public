---
observed:
  - 2026-10-07 | ticket 100018
sources:
  - 2026-10-07 | aws-doc | https://docs.aws.amazon.com/chime/latest/ag/doc-history.html | End of support notice 2025-02-19
  - 2026-10-07 | aws-doc | https://docs.aws.amazon.com/chime-sdk/latest/dg/migrate-from-chm-namespace.html | 표기 없음
review_by: 2027-03-31
---

# 고객이 "Chime SDK 종료" 라고 물으면 그대로 받아 종료 대응을 안내하기 쉬운데, 2026-02-20 에 지원이 끝난 것은 Amazon Chime 애플리케이션이고 Chime SDK 는 아니다

## 무엇을 하면 틀리는가

- 고객이 쓴 서비스 이름을 확인하지 않고 "Chime SDK 가 종료되니 이전하셔야 한다" 는 전제로 답한다.
- "Amazon Chime" 종료 공지를 근거로 Chime SDK 리소스(회의, 메시징, Voice Connector 등)의 정리·이전을 권한다.
- 반대로, 고객이 실제로 Amazon Chime 애플리케이션을 쓰는데 "SDK 는 영향 없다" 고만 답한다.

이름이 비슷한 서비스·기능의 공지를 서로 바꿔 읽는 유형의 첫 사례다.

## 실제로 있었던 일

- 2026-10-07(후보 등록일 — 티켓이 들어온 날은 받지 못했다): 고객이 "Chime SDK 종료" 로 알고 문의했다. 확인해 보니 2026-02-20 종료
  대상은 Amazon Chime 애플리케이션이었고 Chime SDK 는 해당이 없어, 전제를 정정해야 했다.

## 확인된 사실

- 2026-02-20 에 AWS 는 **Amazon Chime 서비스** 지원을 끝냈다. 그 뒤로 Amazon Chime 콘솔과 Amazon Chime 애플리케이션 리소스에
  접근할 수 없다. 같은 공지가 **"Amazon Chime SDK 서비스의 가용성에는 영향이 없다"** 고 적는다. 공지는 2025-02-19 에 문서 이력에 올랐다
  (https://docs.aws.amazon.com/chime/latest/ag/doc-history.html).
- Chime SDK 는 처음에 Amazon Chime 애플리케이션과 **엔드포인트 하나를 같이 썼고**, 그래서 AWS SDK 의 `Chime` namespace 로 두 쪽 API 를
  다 불렀다. 지금은 `ChimeSDKMeetings`, `ChimeSDKVoice` 등 전용 namespace 가 있고 AWS 는 그쪽으로 옮기기를 권한다
  (https://docs.aws.amazon.com/chime-sdk/latest/dg/migrate-from-chm-namespace.html).

`unknown` — 고객 코드가 옛 `Chime` namespace 로 Chime SDK API 를 부르고 있을 때 2026-02-20 이후에도 그대로 동작하는지는 위 문서에
없다. AWS Support 확인이나 실제 호출 결과가 있어야 답할 수 있다.

## 해야 할 것

1. 고객이 말한 이름을 그대로 쓰지 않는다. **무엇을 쓰는지**부터 가른다 — 회의·채팅 앱(Amazon Chime 애플리케이션)인지, 자사 앱에 넣은
   API(Chime SDK)인지. 고객이 받은 공지 원문과 쓰고 있는 API·콘솔 화면을 받는다.
2. Chime SDK 만 쓰면 전제를 정정한다 — 종료 대상이 아니다. 근거로 위 공지의 "does not impact" 문장을 든다.
3. 옛 `Chime` namespace 를 쓰는지 묻는다. 쓰고 있으면 "영향 없다" 고 단정하지 않고, 전용 namespace 이전 안내와 함께 확인이 필요하다고 적는다.
4. Amazon Chime 애플리케이션을 쓰고 있었다면 이미 지원이 끝난 것이다 — 남은 리소스·과금이 있는지는 사람이 확인한다.

## 다시 쓰기 전에 확인할 것

- 공지 문구가 그대로인지 — 특히 Chime SDK 에 대한 "영향 없음" 문장.
- 고객이 쓰는 namespace(`Chime` 인지 `ChimeSDK*` 인지)와 리전.
- Chime SDK 쪽에 따로 나온 종료·변경 공지가 없는지 — AWS 문서 검색과 고객 계정의 AWS Health 알림으로 본다.

## 변경 이력

- 2026-10-07: 작성. 승인된 교훈 후보에서 옮겼다. 승인 때 후보의 근거가 지워져, 티켓 쪽 경위는 후보 요약 한 줄에서만 가져왔다.
