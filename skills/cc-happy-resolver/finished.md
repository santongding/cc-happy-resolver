Only move to `finished` when all of the following are true on the current head:
- There are no more Codex review opinions on the current head.
- Required checks are green on the current head.
- The PR merge state is mergeable.

Before changing the next stage to `finished`:
- Confirm the current head still matches the state you reviewed.
- Remove transient bot-owned status artifacts such as `PROGRESS.md` from the branch head.
- Make sure the branch head is committed, pushed, and clean after that cleanup.
- If any finished criterion is false, do not move to `finished`.

If and only if all finished criteria are satisfied, end with exactly:
`RESULT_STAGE=finished`
