#!/usr/bin/env bash

if [[ -n "${PR_LOOP_GH_SH_LOADED:-}" ]]; then
  return 0
fi
PR_LOOP_GH_SH_LOADED=1

PR_LOOP_GH_LIB_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$PR_LOOP_GH_LIB_DIR/core.sh"

readonly PR_LOOP_STAGE_PREFIX='[pr-loop-bot] PR-LOOP:STAGE:'
readonly PR_LOOP_STAGE_SUFFIX=':DO-NOT-EDIT'
readonly PR_LOOP_STAGE_REGEX='^[[:space:]]*\[pr-loop-bot\][[:space:]]*(PR-LOOP:STAGE:(plan|impl|review|finished):DO-NOT-EDIT|<!--[[:space:]]*PR-LOOP:STAGE:(plan|impl|review|finished):DO-NOT-EDIT[[:space:]]*-->)[[:space:]]*$'
readonly PR_LOOP_BOT_COMMENT_PREFIX='[pr-loop-bot]'
readonly PR_LOOP_GH_PR_FIELDS_JQ='
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

gh_api_with_retry() {
  local max_attempts=${PR_LOOP_GH_API_RETRY_MAX_ATTEMPTS:-3}
  local delay_seconds=${PR_LOOP_GH_API_RETRY_DELAY_SECONDS:-1}
  local attempt=1
  local status=0
  local response=

  while (( attempt <= max_attempts )); do
    if response=$(gh api "$@"); then
      printf '%s\n' "$response"
      return 0
    fi
    status=$?

    if (( attempt >= max_attempts )); then
      log_warn "gh api failed after $attempt attempt(s): gh api $*"
      return "$status"
    fi

    log_warn "gh api attempt $attempt/$max_attempts failed: gh api $*; retrying in ${delay_seconds}s"
    sleep "$delay_seconds"
    attempt=$((attempt + 1))
  done

  return "$status"
}

gh_stage_marker() {
  local stage=$1
  printf '%s%s%s\n' "$PR_LOOP_STAGE_PREFIX" "$stage" "$PR_LOOP_STAGE_SUFFIX"
}

gh_list_open_prs() {
  local slug
  slug=$(repo_slug) || return 1
  log_info "listing open PRs for $slug"

  gh_api_with_retry --paginate --slurp "repos/$slug/pulls?state=open&per_page=100" | jq -c "[.[][]? | $PR_LOOP_GH_PR_FIELDS_JQ]"
}

gh_list_all_prs() {
  local slug
  slug=$(repo_slug) || return 1
  log_info "listing all PRs for $slug"

  gh_api_with_retry --paginate --slurp "repos/$slug/pulls?state=all&per_page=100" | jq -c "[.[][]? | $PR_LOOP_GH_PR_FIELDS_JQ]"
}

gh_list_open_issues() {
  local slug
  slug=$(repo_slug) || return 1
  log_info "listing open issues for $slug"

  gh_api_with_retry --paginate --slurp "repos/$slug/issues?state=open&per_page=100" | jq -c '
    [
      .[][]?
      | select(has("pull_request") | not)
      | {
          number,
          title: (.title // ""),
          body: (.body // ""),
          updatedAt: (.updated_at // ""),
          htmlUrl: (.html_url // "")
        }
    ]
  '
}

gh_repo_default_branch() {
  local slug
  slug=$(repo_slug) || return 1
  log_info "fetching default branch for $slug"
  gh_api_with_retry "repos/$slug" | jq -r '.default_branch // empty'
}

gh_issue_branch_name() {
  local issue_number=$1
  printf 'cc-happy/issue-%s\n' "$issue_number"
}

gh_find_related_pr_number() {
  local issue_number=$1
  local prs_json=$2
  local branch_name issue_ref_regex

  branch_name=$(gh_issue_branch_name "$issue_number")
  issue_ref_regex="(^|[^0-9])#${issue_number}([^0-9]|$)"

  printf '%s\n' "$prs_json" | jq -r \
    --arg branch_name "$branch_name" \
    --arg issue_ref_regex "$issue_ref_regex" '
      [
        .[]?
        | select(
            (.headRefName // "") == $branch_name
            or ((.title // "") | test($issue_ref_regex))
            or ((.body // "") | test($issue_ref_regex))
          )
      ]
      | if length == 0 then "" else (.[0].number | tostring) end
    '
}

gh_remote_branch_exists() {
  local branch_name=$1
  git ls-remote --exit-code --heads origin "$branch_name" >/dev/null 2>&1
}

gh_seed_issue_branch() {
  local issue_number=$1
  local default_branch=$2
  local branch_name=${3:-}
  local worktree_dir=

  if [[ -z "$branch_name" ]]; then
    branch_name=$(gh_issue_branch_name "$issue_number")
  fi

  if gh_remote_branch_exists "$branch_name"; then
    log_info "remote branch $branch_name already exists for issue #$issue_number"
    return 0
  fi

  log_info "seeding branch $branch_name from origin/$default_branch for issue #$issue_number"
  worktree_dir=$(mktemp -d "${TMPDIR:-/tmp}/pr-loop.issue-branch.XXXXXX")

  (
    set -euo pipefail
    trap 'git worktree remove --force "$worktree_dir" >/dev/null 2>&1 || true; rm -rf "$worktree_dir"' EXIT INT TERM

    git fetch origin "refs/heads/$default_branch:refs/remotes/origin/$default_branch"
    git worktree add --force --detach "$worktree_dir" "origin/$default_branch" >/dev/null

    cd "$worktree_dir"
    git checkout -B "$branch_name" >/dev/null
    : > PROGRESS.md
    git add PROGRESS.md

    if git diff --cached --quiet; then
      log_warn "seed branch $branch_name has no diff against $default_branch; expected PROGRESS.md to create a diff"
      return 1
    fi

    git -c user.name="${PR_LOOP_GIT_USER_NAME:-pr-loop-bot}" \
      -c user.email="${PR_LOOP_GIT_USER_EMAIL:-pr-loop-bot@example.invalid}" \
      commit -m "chore: seed issue #$issue_number" >/dev/null
    git push -u origin "$branch_name" >/dev/null
  )
}

gh_create_issue_pr() {
  local issue_number=$1
  local issue_title=$2
  local issue_body=$3
  local default_branch=$4
  local branch_name=${5:-}
  local pr_title pr_body sanitized_title

  if [[ -z "$branch_name" ]]; then
    branch_name=$(gh_issue_branch_name "$issue_number")
  fi

  sanitized_title=$(printf '%s' "$issue_title" | tr '\r\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')
  pr_title=${sanitized_title:-Issue #$issue_number}
  pr_body=${issue_body-}

  log_info "creating PR for issue #$issue_number base=$default_branch head=$branch_name"
  gh pr create --base "$default_branch" --head "$branch_name" --title "$pr_title" --body "$pr_body"
}

gh_pr_meta() {
  local pr_number=$1
  local slug
  slug=$(repo_slug) || return 1
  log_info "fetching lightweight metadata for PR #$pr_number"

  gh_api_with_retry "repos/$slug/pulls/$pr_number" | jq -c "$PR_LOOP_GH_PR_FIELDS_JQ"
}

gh_collect_context() {
  local pr_number=$1
  local slug meta_json issue_json review_json reviews_json
  local issue_count review_count reviews_count

  slug=$(repo_slug) || return 1
  log_info "collecting full context for PR #$pr_number"
  meta_json=$(gh_pr_meta "$pr_number") || return 1
  issue_json=$(gh_api_with_retry --paginate --slurp "repos/$slug/issues/$pr_number/comments?per_page=100" | jq -c '
    [
      .[][]? | {
        id,
        body: (.body // ""),
        createdAt: (.created_at // ""),
        updatedAt: (.updated_at // ""),
        authorLogin: (.user.login // ""),
        authorAssociation: (.author_association // ""),
        reactions: (.reactions // {}),
        url: (.html_url // .url // "")
      }
    ]
  ') || return 1
  review_json=$(gh_api_with_retry --paginate --slurp "repos/$slug/pulls/$pr_number/comments?per_page=100" | jq -c '
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
        reactions: (.reactions // {}),
        url: (.html_url // .url // "")
      }
    ]
  ') || return 1
  reviews_json=$(gh_api_with_retry --paginate --slurp "repos/$slug/pulls/$pr_number/reviews?per_page=100" | jq -c '
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

gh_pr_has_unresolved_hooray_comments() {
  local ctx_file=$1

  [[ "$(gh_pr_pending_comment_ids_json "$ctx_file" | jq '(.issueCommentIds | length) + (.reviewCommentIds | length)')" != "0" ]]
}

gh_pr_pending_comment_ids_json() {
  local ctx_file=$1

  jq -e --arg bot_prefix "$PR_LOOP_BOT_COMMENT_PREFIX" '
    def has_hooray: ((.reactions.hooray // 0) | tonumber) > 0;
    def special_bot_comment: ((.body // "") | startswith($bot_prefix));
    . as $ctx
    | {
        issueCommentIds: [
          $ctx.issueComments[]?
          | select((has_hooray | not) and (special_bot_comment | not))
          | .id
        ],
        reviewCommentIds: [
          $ctx.reviewComments[]?
          | select(
              (((.commitId // "") == "") or ((.commitId // "") == ($ctx.meta.headRefOid // "")))
              and (has_hooray | not)
              and (special_bot_comment | not)
            )
          | .id
        ]
      }
  ' "$ctx_file"
}

gh_add_issue_comment_hooray() {
  local comment_id=$1
  gh_add_comment_reaction "issues/comments" "$comment_id" "issue"
}

gh_add_review_comment_hooray() {
  local comment_id=$1
  gh_add_comment_reaction "pulls/comments" "$comment_id" "review"
}

gh_add_comment_reaction() {
  local api_path=$1
  local comment_id=$2
  local comment_type=$3
  local slug

  slug=$(repo_slug) || return 1
  log_info "adding hooray reaction to $comment_type comment id=$comment_id"
  gh_api_with_retry --method POST "repos/$slug/$api_path/$comment_id/reactions" -f content='hooray' >/dev/null
}

gh_prepare_pr_workspace() {
  local pr_number=$1
  local meta_json=${2:-}
  local push_remote push_ref remote_name clone_url branch_name tracking_ref

  if [[ -z "$meta_json" ]]; then
    meta_json=$(gh_pr_meta "$pr_number") || return 1
  fi

  push_ref=$(printf '%s\n' "$meta_json" | jq -r '.headRefName // ""')
  clone_url=$(printf '%s\n' "$meta_json" | jq -r '.headRepositoryCloneUrl // ""')
  branch_name=$push_ref
  push_remote=origin
  tracking_ref="refs/remotes/origin/$branch_name"

  [[ -n "$branch_name" ]] || die "missing headRefName for PR #$pr_number"

  log_info "preparing git workspace for PR #$pr_number branch=$branch_name"

  if [[ "$(printf '%s\n' "$meta_json" | jq -r '.isCrossRepository // false')" == "true" && -n "$clone_url" ]]; then
    remote_name="pr-loop-head-$pr_number"
    if git remote get-url "$remote_name" >/dev/null 2>&1; then
      git remote set-url "$remote_name" "$clone_url"
    else
      git remote add "$remote_name" "$clone_url"
    fi
    push_remote=$remote_name
    tracking_ref="refs/remotes/$remote_name/$branch_name"
  elif [[ "$(printf '%s\n' "$meta_json" | jq -r '.isCrossRepository // false')" == "true" ]]; then
    die "missing head repository clone URL for cross-repository PR #$pr_number"
    return 1
  fi

  git fetch "$push_remote" "refs/heads/$branch_name:$tracking_ref"
  git checkout -B "$branch_name" "$tracking_ref"
  git reset --hard
  git clean -ffd

  export PR_LOOP_PUSH_REMOTE="$push_remote"
  export PR_LOOP_PUSH_REF="$push_ref"
  log_info "workspace ready for PR #$pr_number on branch $branch_name push_target=$push_remote HEAD:$push_ref"
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
