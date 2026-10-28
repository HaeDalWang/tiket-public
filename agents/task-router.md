# Task Router

Classify first, then load only the listed modules. Never load every policy, playbook, ticket, or skill by default.

Scope is the customer, not the subject. Security, compliance, contract-scope, and billing
questions route here the same as AWS technical ones — the ticket corpus already holds them.

Classification is not the deliverable. Finish the routed output — work order, investigation, or reply — before handing back.

## Universal

- Customer work — **ticket or not**: record it in `tickets/<id>.md`. A request that arrives by email, chat, or a colleague's question is still customer work; assign a local number when there is no ticket number. Customer profiles (`customers/`) are suspended: do not read or create them (`development/decisions/0031`).
- Customer AWS work: identify the target account as the ticket states it (account ID or name) and check `agents/customer-access-locks.md` before authentication, profile registration, or any API call. A hard-locked account cannot be read or written. Once the `corpId` is known, and before profile registration or any customer-account API call, run `python3 scripts/customer_notes.py <corpId>`. Exit 2: stop that customer's account work and tell the engineer why. Exit 3 (no ITSM token set up): proceed, write `특이사항 미확인` in the record, and point the engineer to onboarding. Follow every `금지` item; carry every `주의` item into the record. Reading ITSM notes is an internal-system read with the engineer's own token, not customer-account access; a hard-lock does not block it.
- Policy: search `policy/_routing.md`; read only matching cards. A `draft` card cannot create a commitment or authorize action.
- Capability: select through `agents/capability-catalog.md`; verify runtime state before use.
- Use official/current evidence for load-bearing claims. Prior replies are history, not proof.
- Reuse confirmed evidence already recorded in the same ticket when claim, target, and source remain applicable and no conflict exists. Re-fetch only for a new claim, missing support, conflict, changed target/version, or explicit freshness requirement.
- Record the work in `tickets/<id>.md` from `templates/ticket-intake.md`. Decide the output first (`playbooks/ticket-outputs.md`), grade every claim `[확인]`/`[추측]`/`[모름]` with a source on each `[확인]`, and pass `## 발송 전 점검` before the draft goes out. Fill `## 교훈 후보` only from what actually happened in this record (T1–T4 in the template); `- 없음` is the usual answer.
- Before saying the work is done, run `python3 scripts/check_ticket_record.py <ticket-id>`. It checks the record's shape, not its quality — but a FAIL means the procedure was not finished, whatever the summary claims.

## Route

Decide the tier top-down: the first row whose trigger matches is the tier. Between two rows, take the higher one.

| Tier | Trigger | Load |
|---|---|---|
| `high-risk` | Any one of: (a) the customer asks us to **make a change** in their environment — whoever will run it, and even when questions come with the request (a question about how to configure something, or a request to review what could be changed, is not a change request); (b) an **incident in progress**: service down or degraded now, or a suspected security compromise (unknown login, leaked key) — a past slowdown that has recovered and is asked about for its cause is `standard`; (c) the reply would **commit to** an exact cost figure or contract term (a customer asking about prices, discounts, or credits is not this when the reply explains how the bill is built and states no figure — declining to give a number is not committing to one); (d) credentials or PII are sent or requested; (e) an irreversible action | `standard` inputs plus the relevant specialized playbook. For changes use `playbooks/infra-change-process.md`. Stop at the human approval boundary **after** delivering the artifact and evidence — stopping with nothing produced is not compliance. |
| `standard` | About a specific customer's account, resources, configuration, bill, or support scope, with none of the above: troubleshooting, recommendation, cost structure without a figure, scope or escalation | `quick` inputs plus matching policy cards, similar tickets, and the full `playbooks/evidence-verification.md`. |
| `quick` | A general specification or documentation question that needs no customer state | Capability catalog; official source. Apply the compact checks in `playbooks/evidence-verification.md` sections 0, 2, 4, and 7. |

## Not customer work

- Weekly diary ("일기", 주간회고): `playbooks/weekly-diary.md`. No ticket record, no policy search. Print the draft; save it to the site as a draft only after the user says so (`scripts/weekly_diary_save.py`); never submit it or write it to a file.

## Output modules

- Ticket outputs (decide this first): `playbooks/ticket-outputs.md`
- Reply shape and content: `playbooks/reply-templates.md` (팀 템플릿 00~11 — 유형 하나를 고른다; 내용 규칙 포함)
- Ticket record and pre-send gate: `templates/ticket-intake.md`
- Multi-agent handoff: `agents/compatibility.md`
- Known traps: search `pitfalls/`

Load a local skill only when its trigger directly matches the task and it adds procedure not already supplied by these repository modules. Do not load a broad or merely adjacent skill.
