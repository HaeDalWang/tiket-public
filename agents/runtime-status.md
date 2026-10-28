# Agent Runtime Capability Status

`as_of: 2026-09-11 KST` (customer-skill rows and their evidence: 2026-10-20)

This file records observed runtime readiness. Re-run the checks before relying on it; it is status, not permanent policy.

## This PC

Tables are team-level status, not this PC's. A feature named in the session-start line
`이 PC 에서 아직 안 되는 것: …` (or by `python3 scripts/local_capabilities.py`; Hermes discards
hook output, so run it there) is `not installed` on this PC whatever the tables say: follow the
missing-capability procedure in `agents/capability-catalog.md`. Without Zendesk, ask the engineer
to paste the thread.

## Capability status

| Capability | Status | Basis | Re-check trigger |
|---|---|---|---|
| `customer-aws-readonly` | enabled | Skill runs from this workspace (`skills/aws-customer-account-ops/`); see Evidence provenance | New release touching `skills/`, broker change, `csg-login` marker repoint, or any failed conformance run |
| `billing-platform` | enabled | Same workspace wrapper and API-key resolution path | Same as above |

Read-only is enforced **server-side by the broker**, not by the client. The action whitelist inside the skill is a second filter, not the control.

### Evidence provenance

The status above rests on two classes of evidence. Do not cite the second as if it were the first.

**Observed in this workspace on 2026-10-20** — re-runnable via `agents/install-verification.md`:

- `python3 scripts/test_aws_customer_skill.py` returned PASS 8/8 against `skills/aws-customer-account-ops/`; `python3 scripts/skill_setup.py` reported ready; all four hosts load the workspace `SKILL.md`.
- `bash` resolved from `PATH` was Homebrew 5.3.9. This is a property of **this** workspace, not of the framework: the skill's shell client needs Bash 4.3+, and a machine whose `PATH` resolves macOS `/bin/bash` 3.2 cannot run it. There the conformance test reports `PASS WITH WARNINGS` and both customer-account capabilities are `blocked`.

**Operator-attested on 2026-09-03, not independently observed here**:

- Broker-side read-only enforcement against a live session.
- The zero-guidance synthetic ticket smoke test.

Neither attested item has a recorded artifact in this repository. Do not describe broker-side read-only enforcement as workspace-verified in an audit or customer-facing context.

## AWS official-research capability

Project-scoped as of 2026-09-03 (`agents/environment/mcp-manifest.json`).

| Item | Status | Verified configuration |
|---|---|---|
| MCP server | enabled | `aws-docs` via `uvx mcp-proxy-for-aws@1.6.4` and the managed AWS MCP endpoint |
| Authentication | documentation-only | `--skip-auth`; no AWS credential passed to the MCP proxy |
| Server-side guard | verified | `--read-only`; observed 9 tools without the flag and 6 with it |

Enabled: `aws___search_documentation`, `aws___read_documentation`, `aws___list_regions`, `aws___get_regional_availability`.

Not routed: `aws___call_aws`, `aws___run_script`, `aws___get_presigned_url` (write-capable; removed at the server by `--read-only`), `aws___get_tasks`, `aws___retrieve_skill` (read-only but unrouted; denied by host configuration).

## Exa current-web capability

Project-scoped as of 2026-09-03.

| Item | Status | Verified configuration |
|---|---|---|
| MCP server | enabled | Hosted official endpoint `https://mcp.exa.ai/mcp` |
| Authentication | anonymous | Works with rate limits; no API key stored or passed |

### Enabled Exa tools

- `web_search_exa`
- `web_fetch_exa`

### Excluded Exa capabilities

- `agent_run`
- `web_search_advanced_exa`
- people/company category searches, lead generation, enrichment, and personal-profile lookup

Do not put customer names, contacts, Account/Payer IDs, IPs, CIDRs, credentials, confidential ticket text, or other customer security information into an Exa query. Search public technical topics using de-identified terms only.

Re-run checks: `agents/install-verification.md`.
