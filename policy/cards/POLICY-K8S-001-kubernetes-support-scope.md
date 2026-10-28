---
id: POLICY-K8S-001
title: Kubernetes technical support scope and escalation
status: active
applies_to: [kubernetes, eks, support-scope, escalation, customer-reply]
triggers: [kubernetes, k8s, eks, kubectl, helm, pod, node-group, container, kubernetes-center, 쿠버네티스, 쿠버네티스센터]
source_document: SRC-K8S-001
source_location: "저장소 주인이 2026-10-08 에 적은 팀 규칙; 문서 원본 없음"
applicability: "[team: MSP] Applies when a ticket asks for Kubernetes technical support or a reply would explain Kubernetes"
source_owner: repository owner (MSP engineer); the rule is set verbally within the MSP team
source_version: "no written original; written down and date fixed as 2026-10-08 by the repository owner"
effective_from: 2026-10-08
reviewed_at: 2026-10-08
reviewed_by: Claude Code
review_by: 2027-01-08
authority_verified_at: "2026-10-08"
approved_by: repository owner
approved_at: "2026-10-08"
activation_blocker: ""
retired_at: ""
retirement_reason: ""
replacement: ""
supersedes: ""
---

# Kubernetes technical support scope and escalation

## Control statement

Kubernetes technical support is not provided through tickets under the ordinary support relationship — not on Basic Support, and not at Enterprise level either. It is available only under the separate 쿠버네티스센터 contract and relationship. When a reply has to explain Kubernetes, escalate to the container part (타이거 파트) or to the MSP engineer designated for Kubernetes and get their support before drafting. To the customer, call it a separate technical contract (별도 기술 계약); never use the internal name.

## Scope

- Applies when: a ticket asks for Kubernetes technical support, or answering it would require explaining Kubernetes behavior or configuration.
- Does not apply when: the customer has the separate 쿠버네티스센터 contract — that contract governs, and this card does not describe its terms.
- The line between Kubernetes and the AWS service around it:

| Ordinary ticket support — the AWS service | Separate technical contract — inside the cluster |
|---|---|
| EKS control-plane fault or AWS-side event | Pod behavior: crashes, restarts, scheduling, resource requests and limits |
| Node group and instance capacity, launch failures | Manifests, Helm charts, operators |
| IAM for the cluster: roles, access entries, IRSA / Pod Identity permissions | Autoscaling inside the cluster: HPA, VPA, autoscaler tuning |
| EKS version support dates, add-on versions offered by AWS | Ingress, service mesh, in-cluster networking and DNS |
| VPC, subnets, security groups, load balancers as AWS resources | Application deployment and configuration |

A ticket that has both: answer the AWS-service part as ordinary support, and escalate the in-cluster part.

## Required behavior

1. When a ticket touches Kubernetes, check whether the customer has the 쿠버네티스센터 contract before treating the question as in scope. The check is internal: the MSP engineer designated for Kubernetes holds this entirely for now, so ask that engineer. Do not ask the customer.
2. Without that contract, do not answer the Kubernetes question as ordinary ticket support, whatever the customer's AWS Support Level or MSP grade is.
3. If an explanation of Kubernetes has to go out, escalate first: the container part (타이거 파트), or the MSP engineer designated for Kubernetes (the repository owner as of 2026-10-08). Draft only with their support.
4. In a customer reply, say that Kubernetes technical support is provided under a separate technical contract ("별도 기술 계약"), and that the request has been passed to the team in charge. Say nothing more about that contract.
5. Record who was asked and what they answered in the ticket history using role references.

## Prohibited behavior

- Do not draft Kubernetes troubleshooting or configuration guidance as routine ticket support.
- Do not infer that a higher Support Level (Business, Enterprise) puts Kubernetes support in scope.
- Do not write the name 쿠버네티스센터 in a customer reply, and do not ask the customer whether they hold that contract.
- Do not promise the customer that Kubernetes support will be provided — including "we will follow up with the limit and HPA guidance once confirmed". Whether guidance goes out is decided after the escalation.
  Allowed: saying the request was passed on and you will get back to them ("담당 팀에 전달했고 다시 안내드리겠다"), and a one-line caution not to restart or scale before the cause is known. Neither promises guidance.
- Do not describe the contract's terms, price, or how to sign up; this card does not hold them.
- Do not send a Kubernetes explanation that the container part or the designated engineer has not supported.

## Exceptions and escalation

- The table in Scope is the repository owner's line, not the source's wording. An item that is in neither column, or that needs in-cluster knowledge to answer the AWS-side question, goes to the container part or the designated engineer first.
- There is no list to look the contract up in. For now one person — the designated engineer — handles all of it and is the only way to confirm. If that engineer is unavailable, state the contract status as unknown.
- The source opens with "Basic Support" and then says Enterprise does not change it. This card reads it as: no Support Level puts Kubernetes in scope. Confirmed by the repository owner's wording, not by a contract text.
- `POLICY-SUPPORT-001` says service scope depends on the contract; this card is the Kubernetes case of that. `GUIDE-ROLE-001` covers routing between teams in general.
- The FTR-PLS 2.0 Support Operations document (2024-11, `POLICY-ESC-001`) lists Container (ECS, EKS) under the DevOps team as an ordinary internal escalation. This card is newer and narrower and governs Kubernetes questions. That DevOps team was dissolved in a reorganization; its container work remains in the container part (타이거 파트), held by one engineer. The two escalation targets in this card can therefore be the same person.
- The rule has no written original. It is set verbally within the MSP team and was written down by the repository owner.

## Evidence

- Source document: `SRC-K8S-001` (no written original; excerpt in `policy/excerpts/`)
- Page/section: whole excerpt
- Verbatim source excerpt, one engineer name replaced by a role:

> 베이직 서포트는 쿠버네티스관련 기술지원 및 티켓으로 안내를 하지못함 엔터프라이즈급이라고 해도 안됨 정확히는 쿠버네티스센터라는 별도 계약 및 관계에서만 가능한 조건임 쿠버네티스 설명을 나가야할 경우 컨테이너 파트(타이거파트) 또는 [MSP 의 쿠버네티스 담당 엔지니어 — 이름 생략] 한테 에스컬레이션해서 서포팅 받아야함

- Supplement (same day), on saying the name to the customer:

> 안된다 별도 기술계약이라고 말해야함

## Change history

- 2026-10-08 — Created and activated. The repository owner (final approver for these cards) wrote the rule down and confirmed it is an actual rule set verbally each time. The escalation target is recorded by role at the owner's choice.
