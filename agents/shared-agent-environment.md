# Shared Agent Environment

> **배포 평가 문서다. 티켓 처리 경로에서 로드되지 않는다.** `DISTRIBUTION.md` 가 참조한다.

`as_of: 2026-08-31 KST`

This document defines the proposed distribution boundary for project-scoped Skills, MCP capabilities, and Hooks across Hermes, Claude Code, Codex, and Kiro. It records an assessment and rollout gate; it does not authorize credentials, customer-account access, or automatic customer communication.

## Locked operating direction

- Teammate workspaces follow `upstream/main`.
- Operational backlog creation is deferred while real ticket samples accumulate.
- `pitfalls/` is shared curated knowledge whose entries act as routing warnings and always require ticket-specific re-verification; they are not standalone proof.
- The next environment priority is consistent project-scoped capability, not identical personal agent installations.
- Hook adoption requires measured benefit or a deterministic safety requirement.

## Observed baseline

- The repository has no project-scoped Skill directory for any supported agent.
- Project-scoped MCP **is** committed: `agents/environment/mcp-manifest.json` declares the capability once and `scripts/render_agent_configs.py` generates the Kiro, Claude Code, and Codex host files. The validator rejects drift. Hermes still needs manual profile alignment because it stores MCP configuration outside the repository.
- The repository has no Hook configuration or shared Hook implementation.
- The current Hermes profile has 95 enabled Skills, mixing personal, bundled, and support-related capabilities.
- Hermes reads no repository hook files. Since 2026-09-29 onboarding registers `scripts/hermes_hook.py` as an `on_session_start` shell hook in the user's `~/.hermes/config.yaml` (backup first), and Hermes asks once for approval.
- The include-only MCP boundary is six tools: four AWS documentation tools and two Exa research tools.
- The root entrypoints are already bounded: the validator caps `CLAUDE.md`, `AGENTS.md`, and Kiro steering and enforces selective routing. Kiro also supports conditional steering inclusion when specialized guidance should not load on every interaction.[13]

Rules and MCP capability now reproduce after clone. Skills and Hooks do not.

## Portability boundary

All four target agents support the open Agent Skills format and progressive disclosure.[2][6]
Their automatic project directories differ: Hermes and Codex can discover repository Skills under `.agents/skills/`, while Claude Code uses `.claude/skills/` and Kiro uses `.kiro/skills/`.[9][14]

Use this layout:

```text
.agents/skills/                          canonical project Skill source
.claude/skills/                          generated Claude Code copies
.kiro/skills/                            generated Kiro copies
agents/environment/mcp-manifest.json     secret-free capability manifest (in place)
scripts/render_agent_configs.py          host MCP config generator (in place)
scripts/verify_mcp_servers.py            MCP reachability and boundary check (in place)
scripts/agent-environment/               Skill sync and Hook scripts
.claude/settings.json                    Claude Hook adapter and MCP tool denial
.codex/hooks.json                        Codex Hook adapter
.kiro/hooks/                             Kiro Hook adapters
```

Skill directories and Hook adapters are not built yet. The MCP rows exist.

Do not maintain three independent Skill implementations. A deterministic sync script must copy the canonical Skill into product directories and the workspace validator must reject drift. Copies are preferred over Git symlinks so clones remain portable across operating systems and Git configurations.

Hermes project Skill discovery requires explicit repository trust. Onboarding must run `hermes skills trust` for the workspace rather than silently modifying global trust state.

## Do not duplicate the ticket workflow as a Skill

Do not add a `tiket-ticket-workflow` Skill. The workflow is already divided across repository contracts:

- `agents/task-router.md` classifies the task and controls selective loading.
- `playbooks/evidence-verification.md` implements the portable `answer-quality-gate` capability.
- Claude Code maps that capability to its existing `maintainer-skills:seonbi` Skill. It is a
  plugin skill, so it lives under `plugins/marketplaces/`, not in the plain skills directory.
- Hermes, Codex, and Kiro apply the same repository playbook directly.
- `playbooks/ticket-outputs.md` decides the artifact; evidence grades carry sources before prose.

This is an intentional capability mapping, not a missing shared Skill. A host-specific Skill name does not need to be identical when the repository capability contract and output semantics are the same. Add a new Skill only when repeated samples reveal a procedure that is not already supplied by the router, playbooks, templates, or an existing approved Skill.

## MCP distribution

MCP is the shared external-capability boundary, but configuration syntax and trust are host-specific. Claude Code supports project-scoped `.mcp.json`; Codex supports project-scoped `.codex/config.toml`; Kiro supports workspace MCP configuration at `.kiro/settings/mcp.json`; Hermes stores native MCP configuration in its profile.[10][12][15]

`agents/environment/mcp-manifest.json` is that one secret-free manifest. It declares:

- capability ID and server name
- pinned package version or remote URL
- allowed transport
- exact include-only tool list, and a blocked list with a reason per tool
- required environment-variable names, never values
- read/write classification
- authentication mode
- smoke test
- observed evidence, with the date and method

JSON rather than YAML because the validator and generator must run on a clean Python install with no third-party parser.

Tool control is not equally expressive across hosts. Codex accepts `enabled_tools`, a true allow list. Kiro and Claude Code accept deny lists only. Relying on per-host denial alone would let a newly added upstream tool appear, so the AWS proxy also runs with `--read-only`, which drops every tool not annotated `readOnlyHint=true`. Enforce at the server first, then deny per host.

The existing six-tool include-only MCP boundary is good. Do not add an entire server tool catalog when a routed capability needs only a small subset. Larger or poorly described MCP tool catalogs increase selection noise; Kiro explicitly warns that very large tool descriptions can affect agent performance.[15]

The AWS toolkit also distributes plugins and generic skill packs. Do not adopt them to satisfy a routed capability. They carry the full tool catalog, including customer-account execution, and generic AWS knowledge does not expand repository authority.

## Hook portability

Hermes and Claude Code expose lifecycle Hooks, including command-based interception around tool use or turn completion.[1][5]
Codex and Kiro expose comparable lifecycle events, but all four hosts differ in event payloads, matcher names, trust mechanisms, and configuration locations.[7][11]

Therefore:

- Put deterministic logic in shared scripts under `scripts/agent-environment/hooks/`.
- Keep product-specific files as thin event and payload adapters.
- Never encode business policy separately in four Hook configurations.
- Never log prompts, customer text, tool inputs, tool outputs, identifiers, credentials, or source documents.
- Treat Hook trust as local human state; a cloned repository must not grant itself execution trust.

## Performance and token assessment

Hooks do not inherently reduce token cost. They help only when deterministic work replaces an avoidable model/tool loop, prevents a known failure, or keeps irrelevant context out of the prompt. Hooks also add process latency, and prompt- or agent-based Hooks can add another model call.[5][7][11]

| Candidate | Expected effect | Decision |
|---|---|---|
| Silent final validator; return output only on failure | May prevent a failed completion and one correction turn | Pilot after baseline |
| Pre-tool guard for prohibited sends, customer-account writes, and `terraform apply` | Strong deterministic safety; may avoid correction loops | Design after common script contract |
| Run full validator after every file edit | Repeated process cost and noisy feedback | Reject |
| Inject router or policy text on every prompt | Repeats input tokens and may reduce prompt-cache stability | Reject |
| LLM/prompt Hook for routine classification | Adds model cost and is not portable because Codex currently executes command handlers only | Reject |
| Metadata-only Stop Hook for measurements | Provides evidence without model-visible content | Pilot candidate |

For Hermes specifically, Skills are already progressively disclosed, while their metadata index is part of the stable prompt. Official documentation describes the default Skill index as roughly 3,000 tokens and advises cache-stable prompt construction.[2][3][4] The current 94-Skill personal catalog is therefore a more credible immediate token target than adding a Hook.

A dedicated `tiket` Hermes profile should eventually load only the project core pack and genuinely required support Skills. This must not delete or alter the user's personal default profile. Claude Code and Codex also disclose Skill metadata before loading full Skill bodies, so concise descriptions and a small project pack matter across hosts.[6][8][9]

## Measurement gate

Preserve zero-guidance testing. Use the same de-identified raw ticket intake and no steering prompt for baseline and candidate runs.

Record only numeric or categorical metadata:

- host and model
- input, cached-input, and output tokens when exposed
- wall-clock duration
- model-call and tool-call counts
- files and modules loaded by count, not customer-bearing path text
- validator result and correction-turn count
- safety violation attempts
- human review outcome

Do not record prompt bodies, customer content, model output, tool payloads, or credentials in Hook telemetry.

Do not claim savings from one successful run. Promote a Hook only after repeated paired samples show one of:

- fewer correction turns
- fewer irrelevant file/tool loads
- lower uncached input tokens
- lower total token use without quality regression
- a deterministic safety block that justifies neutral or higher cost

## Recommended rollout order

1. **Done.** Capability-to-host mapping recorded in `agents/environment/mcp-manifest.json`.
2. Add deterministic cross-host presence and readiness verification for Skills; verify `maintainer-skills:seonbi` for Claude Code and the repository playbook path for the other hosts.
3. **Done.** The MCP contract lives in the same manifest, host configs are generated from it, and `scripts/verify_mcp_servers.py` compares the declaration to what the servers actually expose.
4. Accumulate zero-guidance baseline samples with no Hook and no new ticket workflow Skill.
5. Promote a new shared Skill only after samples show a repeated procedural gap.
6. Pilot one silent, metadata-only measurement Hook.
7. Pilot final validation only if baseline runs commonly omit or fail validation.
8. Add pre-tool safety guards only after payload adapters are tested on every supported host.

Do not deploy several Hooks together; that would prevent attribution of any performance or cost change.

## Sources

[1] https://hermes-agent.nousresearch.com/docs/user-guide/features/hooks
[2] https://hermes-agent.nousresearch.com/docs/user-guide/features/skills
[3] https://hermes-agent.nousresearch.com/docs/developer-guide/prompt-assembly
[4] https://hermes-agent.nousresearch.com/docs/developer-guide/context-compression-and-caching
[5] https://code.claude.com/docs/en/hooks
[6] https://code.claude.com/docs/en/skills
[7] https://developers.openai.com/codex/hooks
[8] https://developers.openai.com/codex/concepts/customization
[9] https://developers.openai.com/codex/skills
[10] https://developers.openai.com/codex/mcp
[11] https://kiro.dev/docs/hooks
[12] https://kiro.dev/docs/how-kiro-works
[13] https://kiro.dev/docs/steering
[14] https://kiro.dev/docs/skills
[15] https://kiro.dev/docs/mcp
