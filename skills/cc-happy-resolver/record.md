Recording and persistence rules:
- The default transient status artifact is repo-root `PROGRESS.md`. Keep it concise and include the stage, work completed, tests run, and blockers or next steps.
- Update `PROGRESS.md` whenever the next pass would benefit from a clean handoff. It is optional only when it would add no value.
- You may modify normal repo files for experiments or implementation, but persist only intentional changes.
- If you change code or `PROGRESS.md` and want the next pass or PR readers to rely on that state, `git add`, `git commit`, and run the prompt-provided push command before posting summary comments or emitting a stage result.
- Before moving to `finished`, remove transient bot-owned status artifacts such as `PROGRESS.md` from the branch head.
- Record bot comments and solved external comments only after the related GitHub comments already exist.

State recording order:
1. Clear per-pass bot comment ids before recording new ones.
2. Record the new bot comment ids via `statectl.sh`.
3. Record solved external comment ids via `statectl.sh`.

State update commands:
- Clear per-pass bot comment ids before recording new ones:
`<statectl-path> clear-recent-bot-comments`
- Record the new top-level bot summary comment id after the comment exists:
`<statectl-path> add-bot-issue-comment "$SUMMARY_ID"`
- Record the new bot review reply id after the reply exists:
`<statectl-path> add-bot-review-reply "$REPLY_ID"`
- Record addressed external review comments after bot comments are already recorded:
`<statectl-path> add-solved-comment <id>`
- Update the next-pass hint when useful:
`<statectl-path> set-hint "..."`
- Record the processed head sha if needed:
`<statectl-path> set-last-head-sha <sha>`
- Touch state without changing other fields:
`<statectl-path> mark-updated`
