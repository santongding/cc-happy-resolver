#!/usr/bin/env bash

if [[ -n "${PR_LOOP_GH_SH_LOADED:-}" ]]; then
  return 0
fi
PR_LOOP_GH_SH_LOADED=1

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/core.sh"

readonly PR_LOOP_STAGE_PREFIX='[pr-loop-bot] <!-- PR-LOOP:STAGE:'
readonly PR_LOOP_STAGE_SUFFIX=':DO-NOT-EDIT -->'
readonly PR_LOOP_STAGE_REGEX='^[[:space:]]*\[pr-loop-bot\][[:space:]]*<!--[[:space:]]*PR-LOOP:STAGE:(plan|impl|review|finished):DO-NOT-EDIT[[:space:]]*-->[[:space:]]*$'

gh_stage_marker() {
  local stage=$1
  printf '%s%s%s\n' "$PR_LOOP_STAGE_PREFIX" "$stage" "$PR_LOOP_STAGE_SUFFIX"
}

gh_list_open_prs() {
  local slug
  slug=$(repo_slug) || return 1
  log_info "listing open PRs for $slug"

  gh api --paginate --slurp "repos/$slug/pulls?state=open&per_page=100" | jq -c '
    [
      .[][]? | {
        number,
        state: ((.state // "") | ascii_upcase),
        updatedAt: (.updated_at // ""),
        headRefOid: (.head.sha // ""),
        headRefName: (.head.ref // ""),
        headRepositoryName: (.head.repo.name // ""),
        headRepositoryOwner: (.head.repo.owner.login // ""),
        headRepositoryCloneUrl: (.head.repo.clone_url // ""),
        baseRepositoryName: (.base.repo.name // ""),
        baseRepositoryOwner: (.base.repo.owner.login // ""),
        maintainerCanModify: (.maintainer_can_modify // false),
        isCrossRepository: ((.head.repo.full_name // "") != (.base.repo.full_name // "")),
        title: (.title // ""),
        htmlUrl: (.html_url // "")
      }
    ]
  '
}

gh_pr_meta() {
  local pr_number=$1
  local slug
  slug=$(repo_slug) || return 1
  log_info "fetching lightweight metadata for PR #$pr_number"

  gh api "repos/$slug/pulls/$pr_number" | jq -c '
    {
      number,
      state: ((.state // "") | ascii_upcase),
      updatedAt: (.updated_at // ""),
      headRefOid: (.head.sha // ""),
      headRefName: (.head.ref // ""),
      headRepositoryName: (.head.repo.name // ""),
      headRepositoryOwner: (.head.repo.owner.login // ""),
      headRepositoryCloneUrl: (.head.repo.clone_url // ""),
      baseRepositoryName: (.base.repo.name // ""),
      baseRepositoryOwner: (.base.repo.owner.login // ""),
      maintainerCanModify: (.maintainer_can_modify // false),
      isCrossRepository: ((.head.repo.full_name // "") != (.base.repo.full_name // "")),
      title: (.title // ""),
      body: (.body // ""),
      htmlUrl: (.html_url // "")
    }
  '
}

gh_pr_is_open() {
  local pr_number=$1
  [[ "$(gh_pr_meta "$pr_number" | jq -r '.state')" == "OPEN" ]]
}

gh_collect_context() {
  local pr_number=$1
  local slug meta_json issue_json review_json reviews_json
  local issue_count review_count reviews_count

  slug=$(repo_slug) || return 1
  log_info "collecting full context for PR #$pr_number"
  meta_json=$(gh_pr_meta "$pr_number") || return 1
  issue_json=$(gh api --paginate --slurp "repos/$slug/issues/$pr_number/comments?per_page=100" | jq -c '
    [
      .[][]? | {
        id,
        body: (.body // ""),
        createdAt: (.created_at // ""),
        updatedAt: (.updated_at // ""),
        authorLogin: (.user.login // ""),
        authorAssociation: (.author_association // ""),
        url: (.html_url // .url // "")
      }
    ]
  ') || return 1
  review_json=$(gh api --paginate --slurp "repos/$slug/pulls/$pr_number/comments?per_page=100" | jq -c '
    [
      .[][]? | {
        id,
        body: (.body // ""),
        createdAt: (.created_at // ""),
        updatedAt: (.updated_at // ""),
        inReplyToId: (.in_reply_to_id // null),
        reviewId: (.pull_request_review_id // null),
        path: (.path // ""),
        commitId: (.commit_id // ""),
        originalCommitId: (.original_commit_id // ""),
        authorLogin: (.user.login // ""),
        authorAssociation: (.author_association // ""),
        url: (.html_url // .url // "")
      }
    ]
  ') || return 1
  reviews_json=$(gh api --paginate --slurp "repos/$slug/pulls/$pr_number/reviews?per_page=100" | jq -c '
    [
      .[][]? | {
        id,
        state: (.state // ""),
        body: (.body // ""),
        submittedAt: (.submitted_at // ""),
        authorLogin: (.user.login // ""),
        authorAssociation: (.author_association // ""),
        url: (.html_url // .url // "")
      }
    ]
  ') || return 1

  issue_count=$(jq 'length' <<<"$issue_json")
  review_count=$(jq 'length' <<<"$review_json")
  reviews_count=$(jq 'length' <<<"$reviews_json")
  log_info "context fetched for PR #$pr_number: issue_comments=$issue_count review_comments=$review_count reviews=$reviews_count"

  jq -cn \
    --argjson meta "$meta_json" \
    --argjson issueComments "$issue_json" \
    --argjson reviewComments "$review_json" \
    --argjson reviews "$reviews_json" \
    '{
      meta: $meta,
      issueComments: $issueComments,
      reviewComments: $reviewComments,
      reviews: $reviews
    }'
}

gh_write_context_cache() {
  local ctx_json=$1
  local ctx_file=$2
  log_info "writing context cache to $ctx_file"
  printf '%s\n' "$ctx_json" | jq -cS . | atomic_write "$ctx_file"
}

gh_pr_stage() {
  local ctx_file=$1

  jq -r --arg re "$PR_LOOP_STAGE_REGEX" '
    [
      .issueComments[]?
      | select((.body // "") | test($re))
      | {
          createdAt: (.createdAt // .updatedAt // ""),
          stage: (
            (.body // "")
            | capture("PR-LOOP:STAGE:(?<stage>plan|impl|review|finished):DO-NOT-EDIT")
            | .stage
          )
        }
    ]
    | sort_by(.createdAt)
    | if length == 0 then "plan" else .[-1].stage end
  ' "$ctx_file"
}

gh_pr_snapshot() {
  local ctx_file=$1
  local normalized
  local stage

  stage=$(gh_pr_stage "$ctx_file") || return 1
  normalized=$(jq -cS --arg stage "$stage" '
    {
      state: (.meta.state // ""),
      headRefOid: (.meta.headRefOid // ""),
      stage: $stage,
      issueComments: (
        [.issueComments[]? | {id, updatedAt: (.updatedAt // "")}]
        | sort_by(.id)
      ),
      reviewComments: (
        [.reviewComments[]? | {id, updatedAt: (.updatedAt // ""), inReplyToId: (.inReplyToId // null)}]
        | sort_by(.id)
      )
    }
  ' "$ctx_file") || return 1
  printf '%s\n' "$normalized" | sha256_stream
}

gh_prepare_pr_workspace() {
  local pr_number=$1
  local meta_json=${2:-}
  local push_remote push_ref remote_name clone_url

  if [[ -z "$meta_json" ]]; then
    meta_json=$(gh_pr_meta "$pr_number") || return 1
  fi

  log_info "preparing git workspace for PR #$pr_number"

  git fetch origin "pull/$pr_number/head:refs/remotes/origin/pr-loop/$pr_number"
  git checkout -B "pr-loop/$pr_number" "refs/remotes/origin/pr-loop/$pr_number"
  git reset --hard
  git clean -ffd

  push_ref=$(printf '%s\n' "$meta_json" | jq -r '.headRefName // ""')
  clone_url=$(printf '%s\n' "$meta_json" | jq -r '.headRepositoryCloneUrl // ""')
  push_remote=origin

  if [[ "$(printf '%s\n' "$meta_json" | jq -r '.isCrossRepository // false')" == "true" && -n "$clone_url" ]]; then
    remote_name="pr-loop-head-$pr_number"
    if git remote get-url "$remote_name" >/dev/null 2>&1; then
      git remote set-url "$remote_name" "$clone_url"
    else
      git remote add "$remote_name" "$clone_url"
    fi
    push_remote=$remote_name
  fi

  export PR_LOOP_PUSH_REMOTE="$push_remote"
  export PR_LOOP_PUSH_REF="$push_ref"
  log_info "workspace ready for PR #$pr_number on branch pr-loop/$pr_number push_target=$push_remote HEAD:$push_ref"
}

gh_post_stage_marker() {
  local pr_number=$1
  local stage=$2
  local slug body

  slug=$(repo_slug) || return 1
  body=$(gh_stage_marker "$stage")
  log_info "posting stage marker stage=$stage to PR #$pr_number"
  gh api "repos/$slug/issues/$pr_number/comments" -f body="$body"
}
