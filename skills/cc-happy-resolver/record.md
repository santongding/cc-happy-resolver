Recording and persistence rules:
- The default transient status artifact is repo-root `PROGRESS.md`. Keep it concise and include the stage, work completed, tests run, and blockers or next steps.
- Update `PROGRESS.md` whenever the next pass would benefit from a clean handoff. It is optional only when it would add no value.
- You may modify normal repo files for experiments or implementation, but persist only intentional changes.
- If you change code or `PROGRESS.md` and want the next pass or PR readers to rely on that state, `git add`, `git commit`, and run the prompt-provided push command before posting summary comments or recording the next stage.
- Before moving to `finished`, remove transient bot-owned status artifacts such as `PROGRESS.md` from the branch head.
- Record handled comments only after the related GitHub comments already exist.
- Treat `statectl.sh` as a narrow handoff channel, not a general state API. It is only for recording which comments you addressed in this pass and the final next-stage decision.

State recording order:
1. Record each addressed issue comment via `statectl.sh`.
2. Record each addressed review comment or review reply via `statectl.sh`.
3. Record the chosen next stage via `statectl.sh` last.

State update commands:
- Record an addressed issue comment after the comment exists:
`<statectl-path> mark-comment <id>`
- Record an addressed review comment or review reply after the comment exists:
`<statectl-path> mark-sub-comment <id>`
- Record the next stage at the very end:
`<statectl-path> set-next-stage impl`
