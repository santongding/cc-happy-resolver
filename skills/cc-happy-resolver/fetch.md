Continuously resolve the current GitHub pull request in exactly one pass.

Shared setup for every stage:
- Infer the repo from `git remote`.
- Check out the PR branch and verify you are operating on the current PR head.
- Read PR metadata, the current head SHA, current-head review state, unresolved review threads, and CI state for the current head.
- Use the provided context JSON path, recent solved external comment ids, recent bot comment ids, and hint to avoid repeating work and duplicate comments.
- Use the prompt-provided `statectl.sh` path for all state updates. Do not hard-code a different path.

Useful commands while gathering current-head state:
- Inspect CI for the PR head:
`gh pr checks <pr-number> --repo "$REPO"`
`gh run list --repo "$REPO" --commit "$HEAD_SHA" --json databaseId,name,conclusion,event`
`gh run view "$RUN_ID" --repo "$REPO" --log-failed`
- Query unresolved review threads with GraphQL:
`gh api graphql -f owner="${REPO%/*}" -f name="${REPO#*/}" -F pr="<pr-number>" -f query='
  query($owner: String!, $name: String!, $pr: Int!) {
    repository(owner: $owner, name: $name) {
      pullRequest(number: $pr) {
        reviewThreads(first: 100) {
          nodes {
            id
            isResolved
            comments(first: 20) {
              nodes {
                databaseId
                body
              }
            }
          }
        }
      }
    }
  }'`
- Get review comments for a specific current-head review when needed:
`REVIEW_ID=$(echo "$CURRENT_HEAD_REVIEW" | jq -r '.id')`
`gh api repos/$REPO/pulls/<pr-number>/reviews/$REVIEW_ID/comments`

Worker contract:
- `worker.sh` owns workspace preparation, reruns, and legal stage transitions. You own exactly one pass and must not sleep or wait.
- The worker resets and cleans the git worktree before each run. Unpushed local changes will be lost on the next run.
- Do not edit the local state JSON directly. Only use `statectl.sh` for allowed local state updates.
- Do not lie about the final result. Exit after one pass.

Fetch useful, non-replicated PR messages:
- Review the current head only. Prefer review data whose `commit_id` matches the current PR head SHA.
- Inspect unresolved review threads and CI on the current head before deciding what to do next.
- Ignore machine-written stage-marker comments and your own recent bot comments when looking for external feedback to address.
- Use the stored solved-comment ids to avoid re-answering the same external review comment unless new head changes make it relevant again.
- When several comments say the same thing, address the issue once and reply only where that feedback was actually addressed.
- If a comment is stale, already resolved, or superseded by newer feedback on the current head, do not duplicate work.
- Only require or trigger code review when you are in `review` stage.
