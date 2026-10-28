---
id: POLICY-ACCESS-001
title: Employee offboarding and customer-access revocation
status: active
applies_to: [employee-offboarding, customer-access, account-revocation, data-handover]
triggers: [employee-exit, resignation, offboarding, access-revoke, account-disable, device-return, customer-data-delete]
source_document: SRC-EMPLOYEE-LIFECYCLE-001
source_location: "lines 300-321, 353-361, 419-437, 460-461"
source_owner: "HR Team (source footer)"
source_version: "last updated 2026-02-10"
effective_from: 2026-10-01
applicability: "All MSP ticket work and repository metadata touched when an employee leaves or changes role"
reviewed_at: 2026-10-01
reviewed_by: Claude Code
review_by: 2027-03-31
authority_verified_at: "2026-10-01 KST"
approved_by: maintainer
approved_at: "2026-10-01 KST"
activation_blocker: ""
retired_at: ""
retirement_reason: ""
replacement: ""
supersedes: ""
---

# Employee offboarding and customer-access revocation

## Control statement

When an employee leaves, customer security data, AWS credentials, local copies, shared documents, company accounts, VPN access, devices, and assigned work must be explicitly handed over, removed, disabled, or verified by the responsible human teams. Agents may prepare checklists and evidence but must not disable accounts, delete data, or access employee records.

## Scope

- Applies when a customer's primary/secondary engineer, ticket owner, or repository user leaves or changes role.
- Applies to account access, customer data, devices, project/ticket handoff, and ownership metadata.

## Required behavior

1. Identify affected customers, tickets, repositories, credentials, documents, and active work.
2. Prepare a human-owned revocation and handoff checklist.
3. Update customer ownership and alias/contact records only from verified organizational information.
4. Verify account disablement, VPN removal, device return, and customer-data disposition through human-provided evidence.
5. Preserve ticket decision history while removing access and unnecessary personal information.

## Prohibited behavior

- Disabling accounts, removing access, deleting customer data, or wiping devices from an agent session
- Copying employee/customer contact lists into policy cards
- Assuming departure based on stale role documents or Slack status
- Deleting ticket history as part of access cleanup

## Exceptions and escalation

- HR owns personnel status; IT owns account/device actions; the manager owns operational handoff. Confirm the responsible human before changing repository metadata.

## Evidence

- `SRC-EMPLOYEE-LIFECYCLE-001:300-306` — checklist includes customer security information, AWS Access Keys, local customer data, shared files, email/Slack, and VPN removal.
- `SRC-EMPLOYEE-LIFECYCLE-001:316-321` — handoff includes active work, projects, customer contacts, documents, and materials.
- `SRC-EMPLOYEE-LIFECYCLE-001:353-361` — account disablement and handoff completion are assigned to the exit timeline.
- `SRC-EMPLOYEE-LIFECYCLE-001:419-437` — IT responsibility includes account creation on onboarding and account disablement, device recovery, access removal, and optional backup on offboarding.
- `SRC-EMPLOYEE-LIFECYCLE-001:460-461` — source updated 2026-02-10 and attributed to HR Team.

## Change history

- 2026-10-01 — Re-read every cited range against the source (SHA-256 matches `sources.json`); activated by the maintainer. The source is an HR guideline last updated 2026-02-10; HR/IT approval of the current version was not independently verified, so the review date is six months out.
