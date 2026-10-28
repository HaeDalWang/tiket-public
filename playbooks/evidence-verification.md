# Evidence and Reply Quality Gate

Apply this gate before making a technical claim or recommending customer action. Its purpose is to make the boundary between **evidence verified in the current task and recalled knowledge** explicit.

## 0. Lock the question scope

- Restate the customer's actual question in one or two sentences.
- If two interpretations are possible, do not choose the easier one; prepare a clarification question.
- If the target changes during investigation, record the change and its reason.

## 1. Temporal and version fit

- Establish the target service, version, region, account, and date.
- Verify that each source applies to that target and time.
- When a newer source describes historical behavior, cite it as change history rather than current behavior.

## 2. Evidence ladder

### Behavior claims

1. Read-only observation of the customer environment, actual config, logs, and metrics
2. Official documentation for the target version
3. Official source, release, issue, or PR
4. Credible third-party material

### Specification and support claims

1. Official documentation for the target version
2. Official source, release, issue, or PR
3. Credible third-party material

- Stop at the highest authoritative rung that answers the question.
- If live behavior and documentation differ, live evidence wins for a behavior claim and the discrepancy must be reported.
- Never say `according to the official documentation` unless that source was fetched in the current task.

## 3. Design intent

- Do not present undocumented behavior or accidental side effects as the supported path.
- If only a workaround is available, present the intended path and trade-off alongside it.
- Before translating a customer procedure into code, verify that the API supports the exact resource type.

## 4. Calibrated certainty

| Level | Meaning | Required treatment |
|---|---|---|
| confirmed | Verified against evidence in this task | State directly and record evidence |
| hypothesis | Reasoned but not verified | Label it and provide one or two checks |
| unknown | No sufficient basis | State what would resolve it |

Do not hide missing evidence behind vague hedges such as `probably`, `usually`, or `should work`.

An honest record does not protect the customer by itself. A claim recorded as `[추측]` must stay
hedged in the draft. Restating it there as a plain assertion delivers a false certainty to the
customer even though the record was correct — and the record is not what gets sent.

When this task did not find a feature, a case, or a supported path, write `확인되지 않았습니다`.
Never settle it as `없습니다`. Absence of evidence in this task is not evidence of absence.

## 5. Optimality and blast radius

- Consider alternatives to the first plausible approach.
- Include cost, operational burden, adjacent environments, and maintenance impact.
- A change recommendation must state blast radius, rollback, and whether it is temporary.
- Do not proceed beyond verification for an irreversible action without live evidence.

## 6. Company and customer policy

- When `policy/_routing.md` routes an active standard-terms card for this ticket, use it as the default baseline unless the engineer confirms a separate SLA/SOW/addendum, exception, or non-applicability. Record the exception source and scope.
- Escalate disputes, damages, termination, legal retention, and other legally consequential interpretation to CSR/legal for actual-contract verification.
- For retention/deletion, verify and apply law/legal obligation → customer-specific contract/SLA/SOW → active standard terms. A conflict or unknown legal basis is a hard stop for selecting a period or proposing deletion.
- Record applied policy ID, source, and observation date in `조사·실측`.
- If policies conflict, do not invent precedence; escalate to a human.

## 7. Separate the customer reply

- Make the customer's next action and requested information explicit.
- Explain why a clarification is needed before asking it.
- Treat the reply as a draft until a human reviews and sends it.

## When a gate cannot pass

```text
Blocked gate: <scope|time|evidence|intent|certainty|impact|policy>
Why: <missing information or conflict>
Best current hypothesis: <only when applicable>
To verify: <one or two observations or questions>
```

For an irreversible action, stop hypothesis-based recommendations and provide verification steps only.

## Evidence record format

```text
source: <URL, read-only command, or file path>
target: <version, region, account, resource>
observed_at: YYYY-MM-DD HH:MM KST
evidence_tier: live | official-doc | official-repo | third-party
certainty: confirmed | hypothesis | unknown
```
