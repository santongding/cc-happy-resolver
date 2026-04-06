Use `review` when the next pass should close out actionable review comments, resolve merge conflicts, and clear CI failures on the current head.

Review stage duties:
- Gather the exact unresolved review comments, mergeability problems, and failing checks that block the PR.
- Make the required code, test, config, or conflict-resolution changes instead of writing review ideas or broad review summaries.
- Run the relevant verification needed to confirm the fix.
- Update `PROGRESS.md` when the next pass needs that handoff; follow `record.md`.
- Reply only to the review comments you actually addressed, and resolve only the threads you actually fixed.
- If a comment should not be implemented, reply with concrete reasoning.
- Trigger a fresh Codex review only after the current actionable feedback, conflicts, and CI failures have been handled.

Commands used mainly in review:
- Trigger Codex review after the branch is ready for another pass:
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
