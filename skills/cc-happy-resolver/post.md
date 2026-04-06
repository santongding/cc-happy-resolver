Comment and persistence rules:
- Any machine-written business comment must start with: `[pr-loop-bot]`
- Stage-marker comments are worker-owned. Your top-level summary comments are separate business comments and must not mimic the stage-marker format.
- Every stage must leave behind a pushed commit. Local-only progress does not count as persisted state.
- The default transient status artifact is repo-root `PROGRESS.md`. It should contain the stage, work completed, tests run, blockers or next steps, and the intent for the next pass.
- You may modify normal repo files for experiments or implementation, but transient bot-owned progress artifacts must be removed before the final finished path.
- If you change code or the progress artifact, you must `git add`, `git commit`, and run the prompt-provided push command before posting summary comments or emitting a stage result.
- If push fails or the worktree remains dirty, keep the current stage.

Commands for posting and state updates:
- Post the top-level PR summary comment and capture the new comment id:
`SUMMARY_ID=$(gh api repos/$REPO/issues/<pr-number>/comments -f body="[pr-loop-bot] <summary>" --jq '.id')`
- Reply to a review comment:
`REPLY_ID=$(gh api repos/$REPO/pulls/<pr-number>/comments/$COMMENT_ID/replies --field body="[pr-loop-bot] <response>" --jq '.id')`
- Clear per-pass bot comment ids before recording new ones:
`<statectl-path> clear-recent-bot-comments`
- Record the new top-level bot summary comment id after the comment exists:
`<statectl-path> add-bot-comment "$SUMMARY_ID"`
- Record the new bot review reply id after the reply exists:
`<statectl-path> add-bot-comment "$REPLY_ID"`
- Record addressed external review comments after bot comments are already recorded:
`<statectl-path> add-solved-comment <id>`
- Update the next-pass hint when useful:
`<statectl-path> set-hint "..."`
- Record the processed head sha if needed:
`<statectl-path> set-last-head-sha <sha>`
- Touch state without changing other fields:
`<statectl-path> mark-updated`

Required action order for every pass:
1. Commit and push the current pass.
2. Post the top-level PR summary comment.
3. Post any review replies for addressed feedback.
4. Record the new bot comment ids via `statectl.sh`.
5. Record solved external comment ids via `statectl.sh`.
6. Resolve only the threads you actually addressed.
7. Emit `RESULT_STAGE=...`

Final line requirements:
- The final line must be exactly one of:
`RESULT_STAGE=plan`
`RESULT_STAGE=impl`
`RESULT_STAGE=review`
`RESULT_STAGE=finished`
