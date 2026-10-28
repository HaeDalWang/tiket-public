# Multi-Agent Compatibility

## Concurrent work

- Do not let two agents modify the same ticket file concurrently.
- Default to sequential handoff: investigation is appended before a reviewer reads it.
- Use a ticket-specific branch or worktree only when true concurrent work is needed.

## Minimum handoff state

- Customer and ticket path
- Current status and last completed stage
- The ticket record `tickets/<ticket-id>.md` with graded evidence and the pre-send gate
- Verified evidence and unresolved items
- Tools used and observation time
- One clearly scoped next task

Transfer verified repository state, not an entire session transcript.
