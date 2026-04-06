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
