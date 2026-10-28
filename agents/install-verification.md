# Agent Installation and Capability Verification

> **설치·점검 문서다. 티켓 처리 경로에서 로드되지 않는다.** 온보딩과 드리프트 점검이 참조한다.

Use this procedure to verify local installation state. Never print live credential values.

## Installation path contract

`aws-customer-account-ops` lives in this repository (0040). Its version is the workspace release tag (`git describe --tags --abbrev=0`); the client reports it to the broker as `tiket-<tag>`.

| Location | Role |
|---|---|
| `skills/aws-customer-account-ops/` | Source. Scripts execute from here |
| `.claude/skills/`, `.kiro/skills/`, `.agents/skills/` (Codex and Hermes) | Generated `SKILL.md` per host by `scripts/render_agent_configs.py`; no scripts |

The `csg-login` marker in the machine-wide `~/.aws/config` points at `skills/aws-customer-account-ops/get-sts-token.sh` (Windows: `pwsh -NoProfile -File "<path>\get-sts-token.ps1"`) in the **main clone** — never a linked worktree or an evaluation copy. Onboarding step 5 (`scripts/skill_setup.py`) writes the marker and `~/.config/msp/credential-broker.conf`. On a PC that used the old installer, session start (`scripts/skill_migration.py`) repoints `csg-*` profiles here and moves the old `$HOME` copies to `~/.config/msp/skill-home-copies-<time>/`.

## Safe presence check

```bash
python3 scripts/skill_setup.py                    # marker, broker conf, the billing platform key, aws CLI — changes nothing
python3 scripts/render_agent_configs.py --check   # per-host SKILL.md copies match the source
```

`skill_setup.py` exits 0 and prints `쓸 수 있다` when ready; otherwise it names each gap. It never prints values.

## `customer-aws-readonly` readiness

Run this readiness check before customer-account work, and again after any skill install or upgrade.

Check the following without exposing values:

1. `bash`, `aws`, `jq`, `python3`, and `curl` are executable.
2. The `bash` resolved from the agent process's `PATH` is Bash 4.3 or newer. That is the syntax floor the skill's shell client actually uses (`local -n` namerefs, `${var,,}`, `;;&`).

   It is the **agent process's** `PATH` at runtime that matters. A GUI-launched agent that resolves `/bin/bash` 3.2 cannot execute the client even when installation succeeded. `scripts/test_aws_customer_skill.py` reports that as a warning, exits 0, and marks the customer-account capability unusable in that environment.
3. The `csg-login` marker profile exists.
4. Its script path is inside this workspace's `skills/aws-customer-account-ops/`, or — only until session start migrates it — a legacy `$HOME` agent skill directory.
5. Check only whether the broker config file exists.
6. Check only whether the billing platform API key is configured.
7. Run the STS `--check-only` path before any customer AWS request.
8. If expired, perform Slack authentication only with the user's awareness.

Verify the selected Bash without executing the skill. Note that `(( ... ))` arithmetic
must not compare a two-part version as a single number:

```bash
command -v bash
bash -c '(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3) ))' \
  && echo "Bash requirement: pass" \
  || echo "Bash requirement: warn (skill unusable here)"
```

Run this check from the same environment that launches the agent. An interactive terminal and a GUI-launched agent can resolve different `PATH` values.

### Offline skill conformance

After installing the skill, run the repository-owned synthetic test from the workspace root:

```bash
python3 scripts/test_aws_customer_skill.py
```

Without `--skill-dir` it tests the copy the `csg-login` marker resolves to, falling back to this workspace's `skills/`. The test uses temporary homes, synthetic tokens, stubbed `curl`, and a stubbed `aws`; it must not contact Slack, the billing platform, the credential broker, or a customer account. It verifies:

- Bash 4.3+ selection and shell syntax
- fail-fast behavior without a login token
- fail-closed behavior without a billing platform API key
- synthetic billing-platform Bearer forwarding
- the broker `/customer-credentials` path and request scope
- exact five-key `credential_process` output projection
- absence of a local `aws sts assume-role` execution path

A passing offline test is necessary but not sufficient. Broker-side read-only enforcement and the zero-guidance synthetic ticket smoke test are separate gates; see the evidence provenance section of `agents/runtime-status.md` for which of them currently have a recorded artifact.

Read the final line, not just the exit code:

| Final line | Meaning |
|---|---|
| `PASS` | The skill copy conforms and the environment can run it. |
| `PASS WITH WARNINGS` | The repository side is fine, but this environment's bash cannot run the skill. Treat `customer-aws-readonly` and `billing-platform` as `blocked` and DM the skill owner. |
| `FAIL` | A local install problem: missing files, wrong skill directory, or a conformance violation. Fix it before customer work. |

Never print:

- `credential_process` output
- API key values
- access key, secret key, or session token
- broker config contents

## Project-scoped MCP readiness

MCP capability ships with the repository. `agents/environment/mcp-manifest.json` is the
only declaration; `.kiro/settings/mcp.json`, `.mcp.json`, `.claude/settings.json`, and
`.codex/config.toml` are generated from it. Hermes keeps its configuration in its own
profile and must be aligned to the same manifest by hand.

```bash
brew install uv                                  # prerequisite for the AWS proxy
python3 scripts/render_agent_configs.py --check   # host configs match the manifest
python3 scripts/verify_mcp_servers.py             # servers reachable and correctly bounded
```

`verify_mcp_servers.py` exits 0 on PASS, 1 when a boundary is violated or a routed tool is
missing, and 2 when the check could not run because `uv` is absent or the endpoint is
unreachable. A transient network failure is not a configuration error; retry before
concluding. The check redirects AWS configuration to a nonexistent path so it can never
invoke the customer credential broker.

Never edit a generated host file directly. The validator rejects drift and prints the
render command. Personal MCP servers belong in user-level configuration
(`~/.kiro/settings/mcp.json` and equivalents), never in the project files.

## `aws-official-research` readiness

- Server: pinned `mcp-proxy-for-aws@1.6.4` against the managed AWS MCP endpoint, from `aws/agent-toolkit-for-aws`.
- Required enabled tools: `aws___search_documentation`, `aws___read_documentation`, `aws___list_regions`, `aws___get_regional_availability`.
- Required disabled tools: `aws___call_aws`, `aws___run_script`, `aws___get_presigned_url`, `aws___get_tasks`, `aws___retrieve_skill`.
- Two enforcement layers, because neither is sufficient alone:
  - `--read-only` on the proxy drops every tool not annotated `readOnlyHint=true`. Observed 2026-09-03: 9 tools without the flag, 6 with it; `call_aws`, `run_script`, and `get_presigned_url` are the three dropped.
  - Host configuration denies the remaining unrouted tools. Codex expresses an exact allow list; Kiro and Claude Code express deny lists, so the proxy flag is what protects against a newly added upstream write tool.
- `--skip-auth` and no AWS credential. Documentation access never grants customer-account execution.
- Do not enable the toolkit's full tool catalog or its generic skill packs to satisfy this capability. Generic AWS knowledge does not expand repository authority, and a larger catalog increases selection noise.

## `current-web-research` readiness

- Server: official hosted Exa MCP at `https://mcp.exa.ai/mcp` in anonymous rate-limited mode. Observed 2026-09-03: `exa-search-server 3.2.1` exposing exactly 2 tools.
- Required enabled tools: `web_search_exa`, `web_fetch_exa`.
- Keep `agent_run`, advanced search, people/company categories, enrichment, and personal-profile lookup unavailable for this workflow.
- Do not send customer names, contacts, Account/Payer IDs, IPs, CIDRs, confidential ticket text, credentials, or other customer security information to Exa.
- Do not treat search highlights as sufficient support for a load-bearing claim; fetch and inspect the source page.
- Anonymous mode needs no API key. If rate limits become insufficient, prefer OAuth and never send an API key through chat.

## Smoke test

Use synthetic, non-customer data when onboarding an agent.

1. It reads repository rules and explains the no-send boundary.
2. It selects a capability from `agents/capability-catalog.md`.
3. It does not invent an unavailable tool name.
4. It rejects an AWS write request and identifies the read-only path.
5. It applies the billing-platform-only rule to a customer cost question.
6. It records evidence and certainty for a technical answer.

Do not use the agent as the sole investigator for a customer ticket until all checks pass.
