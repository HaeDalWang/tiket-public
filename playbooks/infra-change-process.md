# Infrastructure Work Process

This repository may prepare an implementation plan or script, but agents must not execute customer infrastructure changes.

## Mandatory scope

Apply this playbook whenever a ticket includes deployment, replacement, migration, restart, restore, deletion, traffic switching, permission change, or any other state mutation.

## Procedure

1. **Lock the requested outcome** — separate investigation, preparation, execution, and verification.
2. **Ask the engineer** (customer profiles are suspended) — identify access model, maintenance window, approver, and prohibited actions.
3. **Inspect live state read-only** — record version, region, resource identifiers, dependencies, and current health.
4. **Verify API/resource compatibility** — check the exact resource type and version against official documentation and, when safe, a PoC.
5. **Map blast radius** — services, traffic, data, credentials, monitoring, and dependent teams.
6. **Design rollback first** — define rollback trigger, owner, command/procedure, and maximum decision time.
7. **Prepare artifacts** — code, commands, validation, and rollback steps. Default scripts to dry-run or no-op where supported.
8. **Stop at the human gate** — provide the artifact and evidence; do not execute the change.
9. **After human execution** — append actual results, deviations, and customer response without rewriting the plan history.

## Required handoff

- Target environment and exact resource
- Preconditions
- Step-by-step commands or code
- Expected result per step
- Verification command per step
- Rollback trigger and procedure
- Known unsupported behavior
- Human approval and execution owner

## Hard stops

- No live evidence for an irreversible action
- No tested rollback for a production-impacting change
- Resource/API support inferred only from a similar resource type
- Credentials or write access would need to be copied into this repository
- Customer approval or maintenance window is unclear
- Data retention/deletion sources conflict or the legal basis and approved period are unverified

Actual infrastructure code remains in the appropriate `~/work/<customer>/` or designated project repository.
