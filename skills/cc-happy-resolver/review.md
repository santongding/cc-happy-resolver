Use `review` when the next pass should verify the current head, handle review feedback, or confirm merge readiness.

Review stage duties:
- Verify the current head, required checks, mergeability, and unresolved feedback.
- Update `PROGRESS.md` with the review outcome when the next pass needs that handoff; follow `record.md`.
- Fix small remaining review issues directly when appropriate, and reply to the comments you actually addressed.
- Trigger Codex review when there is no remaining actionable feedback on the current head or after you have resolved the existing review comments.


Commands used mainly in review:
- Trigger Codex review:
`gh pr comment <pr-number> --repo "$REPO" --body "@codex please review this PR."`
- Resolve a review thread after you actually addressed it:
`gh api graphql -f threadId="$THREAD_ID" -f query='
  mutation($threadId: ID!) {
    resolveReviewThread(input: {threadId: $threadId}) {
      thread {
        id
        isResolved
      }
    }
  }'`
