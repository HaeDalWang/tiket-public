# Kiro Repository Entry Point

Before the first response of every session, read root `CLAUDE.md` — whatever the first message is. Then route customer work through `agents/task-router.md`. Load only matched modules.

A message that is only a number is a Zendesk ticket number: run `bash scripts/fetch-ticket.sh <number>` and start `CLAUDE.md` "Start and route".

A request for a "일기" (주간회고) is this team's weekly review, not a personal journal: run `python3 scripts/weekly_diary.py` and follow `playbooks/weekly-diary.md`.

## Hard stops

- Draft only; never send customer email or post Zendesk comments.
- Customer AWS/billing platform inspection is read-only and broker-mediated; check `agents/runtime-status.md` before use.
- Never call customer-account write APIs or change infrastructure.
- Never expose or commit secrets. Commit only de-identified customer context; real customer content stays in local-only `tickets/`.
- Customer-facing cost figures must be billing-platform-curated; never mention raw AWS billing figures.

For customer work, route policy through `policy/_routing.md`, and select capabilities through `agents/capability-catalog.md`. Human-facing ticket content and drafts are Korean.