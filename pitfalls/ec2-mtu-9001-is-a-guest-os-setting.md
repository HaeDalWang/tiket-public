---
observed:
  - 2026-10-07 | ticket 100021
sources:
  - 2026-10-26 | aws-doc | https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-mtu.html | 표기 없음
  - 2026-10-26 | aws-doc | https://aws.amazon.com/blogs/networking-and-content-delivery/performance-and-metrics-enhancements-for-aws-transit-gateway-and-aws-cloud-wan/ | 표기 없음
review_by: 2027-04-24
---

# EC2 의 MTU 9001 을 "AWS 기본값" 이나 "Amazon Linux AMI 기본값" 으로 설명하면 비-Amazon Linux 인스턴스에서는 틀린다 — MTU 는 게스트 OS 설정이다

## 무엇을 하면 틀리는가

- 인스턴스 MTU 가 9001 인 이유를 "AWS 기본 설정" 이나 "Amazon Linux AMI 기본값" 으로 답한다. 고객 서버가 RHEL 계열·Ubuntu·Windows 여도 그렇게 답한다.
- 그 전제로 "AWS 가 정한 값이니 바꾸지 않아도 된다" 거나 "바꾸면 안 된다" 고 안내한다.

## 실제로 있었던 일

- 2026-10-07: VPN 경유 연결 문의에서 MTU 9001 의 배경을 물었다. Amazon Linux 기본값이라는 근거를 들었다가, 대상 서버가 Rocky Linux 라 그 근거가 적용되지 않는다는 것이 드러나 고쳤다.

## 확인된 사실

- 모든 EC2 인스턴스가 MTU 1500 을 지원하고 모든 현행 세대 인스턴스 타입이 점보 프레임(9001)을 지원한다. "일부 인스턴스는 점보 프레임으로, 일부는 표준 프레임으로 설정되어 있다" —
  값은 OS 안에서 `ip link`(Linux)·드라이버 속성(Windows)으로 보고 바꾼다. Windows 는 드라이버별로 **점보 프레임이 기본 꺼져 있다**
  (https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-mtu.html).
- "기본 Amazon Linux AMI 는 MTU 9001 을 쓴다" 는 문장은 AWS 네트워킹 블로그에 있다
  (https://aws.amazon.com/blogs/networking-and-content-delivery/performance-and-metrics-enhancements-for-aws-transit-gateway-and-aws-cloud-wan/).
  EC2 레퍼런스 문서에는 AMI 별 기본 MTU 가 없다. 다른 배포판의 기본값은 그 배포판·이미지 쪽 설정이다.

## 해야 할 것

1. MTU 값의 배경을 답하기 전에 OS·AMI 를 확인한다. Amazon Linux 가 아니면 "Amazon Linux 기본값" 근거를 쓰지 않는다.
2. "MTU 는 인스턴스 안의 OS 네트워크 설정이고, 현행 인스턴스는 1500 과 9001 을 모두 지원한다" 로 답한다. 9001 이 된 경위는 이미지·OS 설정·배포 스크립트 쪽이라고 적는다.
3. VPN·인터넷처럼 1500 이하 경로가 섞이면 path MTU 를 `tracepath`(Linux)·`mturoute`(Windows)로 확인하게 한다.

## 다시 쓰기 전에 확인할 것

- 고객 인스턴스의 OS·AMI 와 `ip link` 로 본 실제 MTU.

## 변경 이력

- 2026-10-26: 작성. 교훈 후보에서 옮겼다(후보 한 줄이 줄바꿈에서 잘려 와 문장을 다시 썼다).
