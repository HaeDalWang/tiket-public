# Agent Capability Catalog

This document defines required **business capabilities**, not product-specific slash commands. Skill, MCP, and tool names are implementation details. If an implementation is unavailable, use an approved equivalent or report the capability as unavailable.

## Shared rules

1. Repository rules and the target customer's ITSM notes override every generic skill.
2. A skill never grants permission to send, mutate, or expose prohibited billing data.
3. A skill file without its required CLI, MCP server, and authentication is not an installed capability.
4. Never store credential values or live API keys in this repository.
5. Verify installation on this PC with `python3 scripts/local_capabilities.py` (team-level status: `agents/runtime-status.md`); do not infer it from memory.
6. Check `agents/runtime-status.md` for temporary blocks and observed readiness before selecting a capability.
7. Resolve the target account reference and check `agents/customer-access-locks.md` before using `customer-aws-readonly`. A hard lock overrides runtime readiness, broker capability, ticket scope, and read-only status.

## Capability mapping

| Capability | Trigger | Claude Code | Hermes | Codex | Kiro | Repository constraint |
|---|---|---|---|---|---|---|
| `customer-aws-readonly` | Inspect or troubleshoot customer AWS resources | `aws-customer-account-ops` | Same skill | Same skill | Same skill | Read-only enforced server-side by the broker; whitelisted read prefixes only; multi-account work passes the scope gate first |
| `customer-notes` | Known `corpId`, before customer-account work | `python3 scripts/customer_notes.py <corpId>` | Same script | Same script | Same script | Read-only, one customer per call, engineer's own ITSM token; exit 2 stops that customer's account work; exit 3 (no token set up) proceeds with `특이사항 미확인` in the record. Writes only items a human said "예" to — not implemented |
| `billing-platform` | Customer cost, invoice, or savings analysis | `billing-api.sh` wrapper | Same wrapper | Same wrapper | Same wrapper | Customer-facing figures stay billing-platform-curated; never surface raw AWS billing output |
| `answer-quality-gate` | Technical claim, action recommendation, or reply draft | `maintainer-skills:seonbi` (plugin) | `playbooks/evidence-verification.md` | Same playbook | Same playbook | Separate verified evidence from recall; hard-stop irreversible action |
| `aws-official-research` | AWS specification or support boundary | Project `.mcp.json` `aws-docs` | Same server, Hermes profile | Project `.codex/config.toml` `aws-docs` | Project `.kiro/settings/mcp.json` `aws-docs` | Documentation lookup only; `--read-only` and `--skip-auth`; no customer-account execution |
| `current-web-research` | Release, issue, CVE, or current information | Project `.mcp.json` `exa` | Same server, Hermes profile | Project `.codex/config.toml` `exa` | Project `.kiro/settings/mcp.json` `exa` | Public de-identified technical queries only; cite fetched source content |
| `diagramming` | Visualize architecture or procedure | Available artifact/diagram tool | `architecture-diagram` or `excalidraw` | Mermaid/repository template | Available diagram tool | Preserve an editable source artifact and its evidence |
| `document-extraction` | Ingest PDF, scan, image, or policy material | Available PDF/OCR tools | `ocr-and-documents`/`vision_analyze` | Available OCR tool | Available OCR tool | Extracted text must trace back to source and page |

## AWS skill restrictions

Generic skills such as `aws-core:*` are reference knowledge and do not expand repository permissions.

- Use only `customer-aws-readonly` for customer-account inspection.
- Do not call mutating APIs with prefixes such as `Create`, `Put`, `Update`, `Modify`, `Delete`, `Start`, `Stop`, or `Invoke`.
- Do not assume an AWS MCP connection inherits the credential broker's read-only enforcement.
- The project MCP servers are declared in `agents/environment/mcp-manifest.json`. Do not add a server or enable a tool outside that manifest, and do not edit a generated host config by hand.
- Never use or mention raw AWS billing output from `aws-billing-and-cost-management` in a customer reply.
- CloudFormation, CDK, and Terraform skills may produce code, plans, and reviews only; never deploy.
- For Hermes `aws-docs`, allow only `search_documentation`, `read_documentation`, `list_regions`, and `get_regional_availability`. Keep `call_aws`, `run_script`, `get_tasks`, `get_presigned_url`, and `retrieve_skill` disabled.
- For Hermes `exa`, allow only `web_search_exa` and `web_fetch_exa`. Do not enable agent/advanced/enrichment features or use people/company categories. Never send customer-identifying or confidential information in a search query.

## Missing capability procedure

1. Check the current agent's installation state.
2. Look for an approved tool that provides the same shared capability.
3. If none exists, report `unsupported` or `not installed`.
4. Never fabricate a result from recall or bypass a repository boundary.
