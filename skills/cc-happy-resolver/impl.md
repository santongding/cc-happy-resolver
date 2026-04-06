Use `impl` when the next pass should make code, config, or test changes.

Impl stage duties:
- Fetch the specific current-head comments or CI failures that drive the implementation work.
- Make the required code or experiment changes.
- Update `PROGRESS.md` when the next pass needs a handoff; follow `record.md`.
- Run the relevant tests.
- Commit and push before any summary comment or review reply when you intend to persist the work from this pass.
- If the requested implementation is ambiguous or you are not confident in the fix, explain the blocker in the summary comment and choose the next stage accordingly instead of guessing.
- Resolve only the review threads you actually addressed.
- If a comment should not be implemented, reply with concrete reasoning instead of ignoring it.
