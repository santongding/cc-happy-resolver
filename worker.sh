#!/usr/bin/env bash
set -euo pipefail

PR_LOOP_WORKER_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$PR_LOOP_WORKER_DIR/lib/core.sh"
source "$PR_LOOP_WORKER_DIR/lib/gh.sh"
PR_LOOP_CLAUDE_PROMPT_TEMPLATE="${PR_LOOP_CLAUDE_PROMPT_TEMPLATE:-$PR_LOOP_WORKER_DIR/prompts/claude-pr-worker.prompt.tmpl}"

PR_LOOP_LOG_MODULE=worker

LOCK_ACQUIRED=0
STATE_FILE=
LOCK_FILE=
CTX_FILE=
PROMPT_FILE=
CLAUDE_STDOUT_FILE=
CLAUDE_STDERR_FILE=

cleanup() {
  local status=$?

  [[ -n "${PROMPT_FILE:-}" && -f "${PROMPT_FILE:-}" ]] && rm -f "$PROMPT_FILE"
  [[ -n "${CLAUDE_STDOUT_FILE:-}" && -f "${CLAUDE_STDOUT_FILE:-}" ]] && rm -f "$CLAUDE_STDOUT_FILE"
  [[ -n "${CLAUDE_STDERR_FILE:-}" && -f "${CLAUDE_STDERR_FILE:-}" ]] && rm -f "$CLAUDE_STDERR_FILE"
  [[ -n "${CTX_FILE:-}" && -f "${CTX_FILE:-}" ]] && rm -f "$CTX_FILE"

  if [[ "${LOCK_ACQUIRED:-0}" == "1" && -n "${LOCK_FILE:-}" ]]; then
    log_info "releasing lock $LOCK_FILE"
    release_lock "$LOCK_FILE" || true
    LOCK_ACQUIRED=0
  fi

  if [[ $status -ne 0 ]]; then
    log_error "worker exited with status $status"
  fi

  return "$status"
}

should_skip_pr() {
  local meta_json=$1
  local state_json=$2
  local current_updated_at last_updated_at

  current_updated_at=$(printf '%s\n' "$meta_json" | jq -r '.updatedAt // ""')
  last_updated_at=$(printf '%s\n' "$state_json" | jq -r '.last_pr_updated_at // ""')

  if [[ -z "$last_updated_at" ]]; then
    return 1
  fi

  [[ "$current_updated_at" < "$last_updated_at" || "$current_updated_at" == "$last_updated_at" ]]
}

git_worktree_dirty() {
  [[ -n "$(git status --porcelain --untracked-files=normal)" ]]
}

persist_system_state() {
  local snapshot=$1
  local meta_json=$2
  local latest_state_json head_sha pr_updated_at next_json

  latest_state_json=$(load_state_json "$STATE_FILE")
  head_sha=$(printf '%s\n' "$meta_json" | jq -r '.headRefOid // ""')
  pr_updated_at=$(printf '%s\n' "$meta_json" | jq -r '.updatedAt // ""')

  next_json=$(printf '%s\n' "$latest_state_json" | jq -c \
    --arg snapshot "$snapshot" \
    --arg head_sha "$head_sha" \
    --arg pr_updated_at "$pr_updated_at" \
    --arg updated_at "$(now_utc)" '
      .last_snapshot = $snapshot
      | .last_head_sha = $head_sha
      | .last_pr_updated_at = $pr_updated_at
      | .updated_at = $updated_at
    ')

  state_write_json "$STATE_FILE" "$next_json"
  log_info "persisted state file=$STATE_FILE updatedAt=$pr_updated_at head=${head_sha:0:12} snapshot=${snapshot:0:12}"
}

build_claude_prompt() {
  local pr_number=$1
  local stage=$2
  local head_sha=$3
  local state_json=$4
  local ctx_file=$5
  local meta_json=$6
  local solved_comment_ids recent_bot_comment_ids
  local hint title url push_remote push_ref
  local template_file prompt

  solved_comment_ids=$(printf '%s\n' "$state_json" | jq -r '[.last_solved_comment_ids[]? | tostring] | join(",")')
  recent_bot_comment_ids=$(printf '%s\n' "$state_json" | jq -r '[.recent_bot_comment_ids[]? | tostring] | join(",")')
  hint=$(printf '%s\n' "$state_json" | jq -r '.hint // ""')
  title=$(printf '%s\n' "$meta_json" | jq -r '.title // ""')
  url=$(printf '%s\n' "$meta_json" | jq -r '.htmlUrl // ""')
  push_remote=${PR_LOOP_PUSH_REMOTE:-origin}
  push_ref=${PR_LOOP_PUSH_REF:-$(printf '%s\n' "$meta_json" | jq -r '.headRefName // ""')}

  template_file=$PR_LOOP_CLAUDE_PROMPT_TEMPLATE
  [[ -f "$template_file" ]] || die "missing prompt template: $template_file"

  prompt=$(<"$template_file")
  prompt=${prompt//__PR_NUMBER__/$pr_number}
  prompt=${prompt//__TITLE__/$title}
  prompt=${prompt//__URL__/$url}
  prompt=${prompt//__STAGE__/$stage}
  prompt=${prompt//__HEAD_SHA__/$head_sha}
  prompt=${prompt//__CONTEXT_JSON__/$ctx_file}
  prompt=${prompt//__LAST_SOLVED_COMMENT_IDS__/${solved_comment_ids:-<none>}}
  prompt=${prompt//__RECENT_BOT_COMMENT_IDS__/${recent_bot_comment_ids:-<none>}}
  prompt=${prompt//__HINT__/${hint:-<none>}}
  prompt=${prompt//__PUSH_REMOTE__/$push_remote}
  prompt=${prompt//__PUSH_REF__/$push_ref}
  prompt=${prompt//__WORKER_DIR__/$PR_LOOP_WORKER_DIR}

  printf '%s\n' "$prompt"
}

run_claude_for_pr() {
  local pr_number=$1
  local stage=$2
  local head_sha=$3
  local state_json=$4
  local ctx_file=$5
  local meta_json=$6
  local claude_cmd exit_code result_line

  PROMPT_FILE=$(mktemp "${TMPDIR:-/tmp}/pr-loop.prompt.XXXXXX")
  CLAUDE_STDOUT_FILE=$(mktemp "${TMPDIR:-/tmp}/pr-loop.stdout.XXXXXX")
  CLAUDE_STDERR_FILE=$(mktemp "${TMPDIR:-/tmp}/pr-loop.stderr.XXXXXX")

  build_claude_prompt "$pr_number" "$stage" "$head_sha" "$state_json" "$ctx_file" "$meta_json" >"$PROMPT_FILE"

  claude_cmd=${PR_LOOP_CLAUDE_CMD:-claude -p}
  export PR_LOOP_PR_NUMBER="$pr_number"
  export PR_LOOP_LOCK_FILE="$LOCK_FILE"
  export PR_LOOP_WORKER_PID="$$"
  export PR_LOOP_CONTEXT_FILE="$ctx_file"
  export PR_LOOP_REPO_ROOT="$(pwd -P)"

  log_info "starting Claude runner command=${claude_cmd} prompt_file=$PROMPT_FILE"

  set +e
  bash -lc "$claude_cmd" <"$PROMPT_FILE" > >(tee "$CLAUDE_STDOUT_FILE") 2> >(tee "$CLAUDE_STDERR_FILE" >&2)
  exit_code=$?
  set -e

  result_line=$(awk 'NF { line = $0 } END { print line }' "$CLAUDE_STDOUT_FILE")
  if [[ $exit_code -ne 0 ]]; then
    log_warn "Claude runner exited with status $exit_code"
  fi

  if [[ "$result_line" =~ ^RESULT_STAGE=(plan|impl|review|finished)$ ]]; then
    log_info "Claude requested stage ${BASH_REMATCH[1]}"
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  log_warn "Claude did not emit a valid RESULT_STAGE line; keeping current stage"
  printf '%s\n' "$stage"
}

validate_stage_transition() {
  local current_stage=$1
  local requested_stage=$2
  local dirty_flag=${3:-0}

  if [[ "$current_stage" == "$requested_stage" ]]; then
    printf '%s\n' "$current_stage"
    return 0
  fi

  if [[ "$dirty_flag" == "1" ]]; then
    log_warn "worktree is dirty after Claude run; refusing to advance stage"
    printf '%s\n' "$current_stage"
    return 0
  fi

  case "$current_stage:$requested_stage" in
    plan:impl|impl:review|review:finished)
      printf '%s\n' "$requested_stage"
      ;;
    *)
      log_warn "invalid stage transition $current_stage -> $requested_stage; keeping current stage"
      printf '%s\n' "$current_stage"
      ;;
  esac
}

process_pr() {
  local pr_number=$1
  local state_json meta_json current_stage pre_snapshot last_snapshot head_sha
  local requested_stage next_stage dirty_flag github_changed=0
  local refreshed_meta_json refreshed_ctx_json final_snapshot final_meta_json

  export PR_LOOP_LOG_PR="$pr_number"
  STATE_FILE=$(pr_state_file "$pr_number")
  LOCK_FILE=$(pr_lock_file "$pr_number")
  CTX_FILE="$(repo_state_dir)/pr-${pr_number}.ctx.json"
  log_info "starting processing state_file=$STATE_FILE lock_file=$LOCK_FILE"

  if ! acquire_lock "$LOCK_FILE"; then
    log_info "lock busy, skipping"
    return 0
  fi
  LOCK_ACQUIRED=1
  log_info "acquired lock $LOCK_FILE"

  meta_json=$(gh_pr_meta "$pr_number")
  log_info "meta state=$(printf '%s\n' "$meta_json" | jq -r '.state // ""') updatedAt=$(printf '%s\n' "$meta_json" | jq -r '.updatedAt // ""') head=$(printf '%s\n' "$meta_json" | jq -r '.headRefOid // ""' | cut -c1-12)"
  if [[ "$(printf '%s\n' "$meta_json" | jq -r '.state // ""')" != "OPEN" ]]; then
    log_info "PR is no longer open"
    return 0
  fi

  state_json=$(load_state_json "$STATE_FILE")
  log_info "loaded state last_pr_updated_at=$(printf '%s\n' "$state_json" | jq -r '.last_pr_updated_at // ""') last_snapshot=$(printf '%s\n' "$state_json" | jq -r '.last_snapshot // ""' | cut -c1-12)"
  if should_skip_pr "$meta_json" "$state_json"; then
    log_info "updatedAt has not advanced; skipping deep processing"
    return 0
  fi

  gh_write_context_cache "$(gh_collect_context "$pr_number")" "$CTX_FILE"
  current_stage=$(gh_pr_stage "$CTX_FILE")
  pre_snapshot=$(gh_pr_snapshot "$CTX_FILE")
  log_info "current stage=$current_stage pre_snapshot=${pre_snapshot:0:12}"

  if [[ "$current_stage" == "finished" ]]; then
    persist_system_state "$pre_snapshot" "$meta_json"
    log_info "PR is already finished"
    return 0
  fi

  last_snapshot=$(printf '%s\n' "$state_json" | jq -r '.last_snapshot // ""')
  if [[ -n "$last_snapshot" && "$last_snapshot" == "$pre_snapshot" ]]; then
    persist_system_state "$pre_snapshot" "$meta_json"
    log_info "snapshot unchanged; skipping (snapshot=${pre_snapshot:0:12})"
    return 0
  fi

  gh_prepare_pr_workspace "$pr_number" "$meta_json"
  head_sha=$(printf '%s\n' "$meta_json" | jq -r '.headRefOid // ""')
  requested_stage=$(run_claude_for_pr "$pr_number" "$current_stage" "$head_sha" "$state_json" "$CTX_FILE" "$meta_json")

  dirty_flag=0
  if git_worktree_dirty; then
    dirty_flag=1
    log_warn "git worktree is dirty after Claude run"
  else
    log_info "git worktree is clean after Claude run"
  fi
  next_stage=$(validate_stage_transition "$current_stage" "$requested_stage" "$dirty_flag")
  log_info "stage decision current=$current_stage requested=$requested_stage next=$next_stage"

  if [[ "$next_stage" != "$current_stage" ]]; then
    if gh_post_stage_marker "$pr_number" "$next_stage" >/dev/null; then
      github_changed=1
      log_info "posted stage marker for $next_stage"
    else
      log_warn "failed to post stage marker; keeping current stage"
      next_stage=$current_stage
    fi
  fi

  refreshed_meta_json=$(gh_pr_meta "$pr_number")
  final_meta_json=$meta_json
  final_snapshot=$pre_snapshot

  if [[ "$github_changed" == "1" ]] \
    || [[ "$(printf '%s\n' "$refreshed_meta_json" | jq -r '.updatedAt // ""')" != "$(printf '%s\n' "$meta_json" | jq -r '.updatedAt // ""')" ]] \
    || [[ "$(printf '%s\n' "$refreshed_meta_json" | jq -r '.headRefOid // ""')" != "$(printf '%s\n' "$meta_json" | jq -r '.headRefOid // ""')" ]]; then
    log_info "reloading context for final snapshot because GitHub-visible state changed"
    refreshed_ctx_json=$(gh_collect_context "$pr_number")
    gh_write_context_cache "$refreshed_ctx_json" "$CTX_FILE"
    final_snapshot=$(gh_pr_snapshot "$CTX_FILE")
    final_meta_json=$(printf '%s\n' "$refreshed_ctx_json" | jq -c '.meta')
  else
    log_info "reusing pre_snapshot as final snapshot"
  fi

  log_info "final snapshot=${final_snapshot:0:12}"
  persist_system_state "$final_snapshot" "$final_meta_json"
  log_info "completed processing"
}

main() {
  local pr_number=${1:-}

  require_cmd bash git jq gh tee awk mktemp
  assert_repo_root
  ensure_repo_state_dir >/dev/null
  export PR_LOOP_LOG_REPO="$(repo_key)"
  log_info "worker starting in repo $(pwd -P)"
  trap cleanup EXIT INT TERM

  [[ -n "$pr_number" && "$pr_number" =~ ^[0-9]+$ ]] || die "usage: worker.sh <pr-number>"
  process_pr "$pr_number"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
