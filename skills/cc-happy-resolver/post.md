Comment and persistence rules:
- Any machine-written business comment must start with: `[pr-loop-bot]`
- Stage-marker comments are auto-generated. Your top-level summary comments are separate business comments and must not mimic the stage-marker format.
- Leave comments when you need to reply to review comments, answer questions, or summarize material work for PR readers.


Commands for posting and state updates:
- Post the top-level PR summary comment and capture the new comment id:
`SUMMARY_ID=$(gh api repos/$REPO/issues/<pr-number>/comments -f body="[pr-loop-bot] <summary>" --jq '.id')`
- Reply to a review comment:
`REPLY_ID=$(gh api repos/$REPO/pulls/<pr-number>/comments/$COMMENT_ID/replies --field body="[pr-loop-bot] <response>" --jq '.id')`


Required action order for every pass:
1. Commit and push the current pass.
2. Post the top-level PR summary comment when a summary is warranted.
3. Post any review replies for addressed feedback.
4. Record bot comment ids and solved external comment ids as described in `record.md`.
5. Resolve only the threads you actually addressed.
