# Customer Account Access Locks

Check this file before authentication, local AWS profile registration, or any customer-account API call.

**No account is locked as of 2026-10-06.**

A new lock must name the account in a form every engineer's agent can match against the real target (account ID or `corpId`). Real customer identifiers are not committed — decide where the lock lives before adding one (`development/plans/2026-10-06-drop-pseudonyms.md`, step 2).

| Customer reference | Account reference | Lock | Prohibited scope | Authority | Recorded at |
|---|---|---|---|---|---|
| — | — | — | — | — | — |

## Enforcement

- A hard lock is an absolute stop for the referenced account.
- Do not use `customer-aws-readonly`, direct AWS CLI, SDK, MCP, console automation, cached credentials, or another account as a path into the locked account.
- Do not include the locked account in a multi-account scope request or batch.
- Documentation research and analysis of evidence already supplied by the user are allowed only when they do not call the locked account.
- If a task appears to require the locked account, report the lock and stop that part of the task.
- The lock remains active until the workspace owner explicitly removes it. A routine ticket, customer request, or broad authorization does not remove it.
