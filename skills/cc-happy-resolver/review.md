Use `review` when the next pass should verify the current head, handle review feedback, or confirm merge readiness.

Review stage duties:
- Verify the current head, required checks, mergeability, and unresolved feedback.
- Update the progress artifact with the review outcome.
- Commit and push before posting the top-level PR summary comment and any needed review replies.
- Record returned bot comment ids only after the comments exist on GitHub.
- If you intend to move to `finished`, remove transient status artifacts such as `PROGRESS.md` from the branch head before the final push so repo-unrelated tracking files do not remain.

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
