Helper commands:

Substitute `<pr-number>` with the PR number from the worker prompt.
Substitute `<statectl-path>` with the `statectl.sh` path from the worker prompt.

- Infer repo from git remote:
`REPO=$(git remote get-url origin | sed 's|.*github\.com[/:]||' | sed 's|\.git$||')`

- Read PR metadata:
`gh pr view <pr-number> --repo "$REPO" --json headRefOid,reviewDecision,mergeStateStatus,statusCheckRollup`

- Read the current head SHA:
`HEAD_SHA=$(gh api repos/$REPO/pulls/<pr-number> --jq '.head.sha')`

- Get the latest review on the current head only:
`CURRENT_HEAD_REVIEW=$(gh api repos/$REPO/pulls/<pr-number>/reviews --jq 'map(select(.commit_id == "'"$HEAD_SHA"'")) | sort_by(.submitted_at) | reverse | .[0]')`

- Trigger Codex review:
`gh pr comment <pr-number> --repo "$REPO" --body "@codex please review this PR."`

- Get review comments for a specific review:
`REVIEW_ID=$(echo "$CURRENT_HEAD_REVIEW" | jq -r '.id')`
`gh api repos/$REPO/pulls/<pr-number>/reviews/$REVIEW_ID/comments`

- Post the top-level PR summary comment and capture the new comment id:
`SUMMARY_ID=$(gh api repos/$REPO/issues/<pr-number>/comments -f body="[pr-loop-bot] <summary>" --jq '.id')`

- Reply to a review comment:
`REPLY_ID=$(gh api repos/$REPO/pulls/<pr-number>/comments/$COMMENT_ID/replies --field body="[pr-loop-bot] <response>" --jq '.id')`

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

- Resolve a review thread:
`gh api graphql -f threadId="$THREAD_ID" -f query='
  mutation($threadId: ID!) {
    resolveReviewThread(input: {threadId: $threadId}) {
      thread {
        id
        isResolved
      }
    }
  }'`

- Inspect CI for the PR head:
`gh pr checks <pr-number> --repo "$REPO"`
`gh run list --repo "$REPO" --commit "$HEAD_SHA" --json databaseId,name,conclusion,event`
`gh run view "$RUN_ID" --repo "$REPO" --log-failed`

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
