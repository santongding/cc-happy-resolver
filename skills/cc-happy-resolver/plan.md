Use `plan` when the next pass still needs investigation, scoping, or a refreshed action plan.

Plan stage duties:
- Inspect current-head review and CI state.
- Write repo-root `PROGRESS.md` with at least the stage, current head SHA, work completed, tests run, blockers or next steps, and the intended next pass.
- Commit and push that progress snapshot before posting a top-level PR summary comment.
- After the summary comment succeeds, clear the recent bot comment ids for this pass, record the new bot comment id, and only then update any solved-comment state.
