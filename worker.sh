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
CLAUDE_REQUESTED_STAGE=

read_requested_stage_from_state() {
  state_read_json "$STATE_FILE" '.current_stage // ""' ""
}

cleanup() {
  local status=$?

  [[ -n "${PROMPT_FILE:-}" && -f "${PROMPT_FILE:-}" ]] && rm -f "$PROMPT_FILE"
  [[ -n "${CLAUDE_STDOUT_FILE:-}" && -f "${CLAUDE_STDOUT_FILE:-}" ]] && rm -f "$CLAUDE_STDOUT_FILE"
  [[ -n "${CLAUDE_STDERR_FILE:-}" && -f "${CLAUDE_STDERR_FILE:-}" ]] && rm -f "$CLAUDE_STDERR_FILE"
  [[ -n "${CTX_FILE:-}" && -f "${CTX_FILE:-}" ]] && rm -f "$CTX_FILE"

  if git rev-parse --show-toplevel >/dev/null 2>&1; then
    git_checkout_detached_head || true
  fi

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

persist_system_state() {
  local last_stage=$1
  local current_stage=$2
  local latest_state_json next_json

  latest_state_json=$(load_state_json "$STATE_FILE")

  next_json=$(printf '%s\n' "$latest_state_json" | jq -c \
    --arg last_stage "$last_stage" \
    --arg current_stage "$current_stage" '
      .last_stage = $last_stage
      | .current_stage = $current_stage
    ')

  state_write_json "$STATE_FILE" "$next_json"
  log_info "persisted state file=$STATE_FILE last_stage=$last_stage current_stage=$current_stage"
}

build_claude_prompt() {
  local pr_number=$1
  local stage=$2
  local head_sha=$3
  local meta_json=$4
  local pending_ids_json=$5
  local title url push_remote push_ref pending_issue_comment_ids pending_review_comment_ids
  local template_file prompt

  title=$(printf '%s\n' "$meta_json" | jq -r '.title // ""')
  url=$(printf '%s\n' "$meta_json" | jq -r '.htmlUrl // ""')
  push_remote=${PR_LOOP_PUSH_REMOTE:-origin}
  push_ref=${PR_LOOP_PUSH_REF:-$(printf '%s\n' "$meta_json" | jq -r '.headRefName // ""')}
  pending_issue_comment_ids=$(printf '%s\n' "$pending_ids_json" | jq -r '[.issueCommentIds[]? | tostring] | join(",")')
  pending_review_comment_ids=$(printf '%s\n' "$pending_ids_json" | jq -r '[.reviewCommentIds[]? | tostring] | join(",")')

  template_file=$PR_LOOP_CLAUDE_PROMPT_TEMPLATE
  [[ -f "$template_file" ]] || die "missing prompt template: $template_file"

  prompt=$(<"$template_file")
  prompt=${prompt//__PR_NUMBER__/$pr_number}
  prompt=${prompt//__TITLE__/$title}
  prompt=${prompt//__URL__/$url}
  prompt=${prompt//__STAGE__/$stage}
  prompt=${prompt//__HEAD_SHA__/$head_sha}
  prompt=${prompt//__PENDING_ISSUE_COMMENT_IDS__/${pending_issue_comment_ids:-<none>}}
  prompt=${prompt//__PENDING_REVIEW_COMMENT_IDS__/${pending_review_comment_ids:-<none>}}
  prompt=${prompt//__PUSH_REMOTE__/$push_remote}
  prompt=${prompt//__PUSH_REF__/$push_ref}
  prompt=${prompt//__WORKER_DIR__/$PR_LOOP_WORKER_DIR}

  printf '%s\n' "$prompt"
}

run_claude_for_pr() {
  local pr_number=$1
  local stage=$2
  local head_sha=$3
  local meta_json=$4
  local pending_ids_json=$5
  local claude_cmd claude_filter exit_code filter_exit
  local requested_stage raw_stdout_pipe stdout_pipe stderr_pipe
  local stdout_tee_pid stderr_tee_pid filter_pid stdout_tee_exit stderr_tee_exit

  PROMPT_FILE=$(mktemp "${TMPDIR:-/tmp}/pr-loop.prompt.XXXXXX")
  CLAUDE_STDOUT_FILE=$(mktemp "${TMPDIR:-/tmp}/pr-loop.stdout.XXXXXX")
  CLAUDE_STDERR_FILE=$(mktemp "${TMPDIR:-/tmp}/pr-loop.stderr.XXXXXX")
  raw_stdout_pipe=$(mktemp "${TMPDIR:-/tmp}/pr-loop.stdout.raw.pipe.XXXXXX")
  stdout_pipe=$(mktemp "${TMPDIR:-/tmp}/pr-loop.stdout.pipe.XXXXXX")
  stderr_pipe=$(mktemp "${TMPDIR:-/tmp}/pr-loop.stderr.pipe.XXXXXX")
  rm -f "$raw_stdout_pipe" "$stdout_pipe" "$stderr_pipe"
  mkfifo "$raw_stdout_pipe" "$stdout_pipe" "$stderr_pipe"

  build_claude_prompt "$pr_number" "$stage" "$head_sha" "$meta_json" "$pending_ids_json" >"$PROMPT_FILE"

  claude_cmd=${PR_LOOP_CLAUDE_CMD:-claude -p --verbose --output-format stream-json --dangerously-skip-permissions}
  claude_filter=${PR_LOOP_CLAUDE_OUTPUT_FILTER:-$PR_LOOP_WORKER_DIR/claude-output-filter.sh}
  [[ -x "$claude_filter" ]] || die "missing Claude output filter: $claude_filter"
  CLAUDE_REQUESTED_STAGE=$stage
  export PR_LOOP_PR_NUMBER="$pr_number"
  export PR_LOOP_STATE_FILE="$STATE_FILE"
  export PR_LOOP_LOCK_FILE="$LOCK_FILE"
  export PR_LOOP_WORKER_PID="$$"
  export PR_LOOP_REPO_ROOT="$(pwd -P)"

  log_info "starting Claude runner command=${claude_cmd} filter=$claude_filter prompt_file=$PROMPT_FILE"

  tee "$CLAUDE_STDOUT_FILE" <"$stdout_pipe" &
  stdout_tee_pid=$!
  tee "$CLAUDE_STDERR_FILE" <"$stderr_pipe" &
  stderr_tee_pid=$!
  "$claude_filter" <"$raw_stdout_pipe" >"$stdout_pipe" 2>"$stderr_pipe" &
  filter_pid=$!

  set +e
  bash -lc "$claude_cmd" <"$PROMPT_FILE" >"$raw_stdout_pipe" 2>"$stderr_pipe"
  exit_code=$?
  wait "$filter_pid"
  filter_exit=$?
  wait "$stdout_tee_pid"
  stdout_tee_exit=$?
  wait "$stderr_tee_pid"
  stderr_tee_exit=$?
  set -e
  rm -f "$raw_stdout_pipe" "$stdout_pipe" "$stderr_pipe"

  if [[ $exit_code -eq 0 && $filter_exit -ne 0 ]]; then
    exit_code=$filter_exit
  fi
  if [[ $stdout_tee_exit -ne 0 || $stderr_tee_exit -ne 0 ]]; then
    log_warn "tee exited unexpectedly stdout=$stdout_tee_exit stderr=$stderr_tee_exit"
  fi

  if [[ $exit_code -ne 0 ]]; then
    log_warn "Claude runner exited with status $exit_code"
  fi

  requested_stage=$(read_requested_stage_from_state)
  if [[ "$requested_stage" =~ ^(plan|impl|review|finished)$ ]]; then
    log_info "Claude requested stage $requested_stage via statectl"
    CLAUDE_REQUESTED_STAGE=$requested_stage
  else
    log_warn "Claude did not record a valid next stage via statectl; keeping current stage"
    CLAUDE_REQUESTED_STAGE=$stage
  fi
}

queue_ids_from_file() {
  local file=$1
  local line
  local -a ids=()
  local seen_lines=$'\n'

  [[ -f "$file" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[0-9]+$ ]] || continue
    if [[ "$seen_lines" != *$'\n'"$line"$'\n'* ]]; then
      ids+=("$line")
      seen_lines+="$line"$'\n'
    fi
  done <"$file"

  if ((${#ids[@]} == 0)); then
    return 0
  fi

  printf '%s\n' "${ids[@]}"
}

apply_queue_reactions() {
  local file=$1
  local reaction_fn=$2
  local comment_type=$3
  local comment_id
  local -a ids=()

  while IFS= read -r comment_id; do
    [[ -n "$comment_id" ]] || continue
    ids+=("$comment_id")
  done < <(queue_ids_from_file "$file")

  if ((${#ids[@]} == 0)); then
    return 0
  fi

  for comment_id in "${ids[@]}"; do
    if "$reaction_fn" "$comment_id"; then
      log_info "applied hooray to $comment_type comment id=$comment_id"
    else
      log_warn "failed to apply hooray to $comment_type comment id=$comment_id"
    fi
  done

  rm -f "$file"
}

flush_mark_queues() {
  local pr_number=$1
  local issue_queue review_queue

  issue_queue=$(pr_mark_queue_file "$pr_number" "mark-comment.ids")
  review_queue=$(pr_mark_queue_file "$pr_number" "mark-sub-comment.ids")

  apply_queue_reactions "$issue_queue" gh_add_issue_comment_hooray issue
  apply_queue_reactions "$review_queue" gh_add_review_comment_hooray review
}

should_run_pr() {
  local ctx_file=$1
  local state_json=$2
  local github_stage=$3
  local stored_last_stage stored_current_stage

  stored_last_stage=$(printf '%s\n' "$state_json" | jq -r '.last_stage // ""')
  stored_current_stage=$(printf '%s\n' "$state_json" | jq -r '.current_stage // ""')

  if [[ -z "$stored_current_stage" ]]; then
    return 0
  fi

  if [[ "$stored_current_stage" != "$stored_last_stage" ]]; then
    return 0
  fi

  if [[ "$stored_current_stage" != "$github_stage" ]]; then
    return 0
  fi

  gh_pr_has_unresolved_hooray_comments "$ctx_file" && return 0
  return 1
}

validate_stage_transition() {
  local current_stage=$1
  local requested_stage=$2

  case "$requested_stage" in
    plan|impl|review|finished)
      ;;
    *)
      log_warn "invalid requested stage $requested_stage; keeping current stage"
      printf '%s\n' "$current_stage"
      return 0
      ;;
  esac

  if [[ "$current_stage" == "$requested_stage" ]]; then
    printf '%s\n' "$current_stage"
    return 0
  fi

  printf '%s\n' "$requested_stage"
}

process_pr() {
  local pr_number=$1
  local state_json meta_json current_stage head_sha
  local requested_stage next_stage pending_ids_json

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
  log_info "loaded state last_stage=$(printf '%s\n' "$state_json" | jq -r '.last_stage // ""') current_stage=$(printf '%s\n' "$state_json" | jq -r '.current_stage // ""')"

  gh_write_context_cache "$(gh_collect_context "$pr_number")" "$CTX_FILE"
  current_stage=$(gh_pr_stage "$CTX_FILE")
  log_info "current stage=$current_stage"

  if [[ "$current_stage" == "finished" ]]; then
    persist_system_state "$current_stage" "$current_stage"
    log_info "PR is already finished"
    return 0
  fi

  if ! should_run_pr "$CTX_FILE" "$state_json" "$current_stage"; then
    persist_system_state "$current_stage" "$current_stage"
    log_info "no pending stage change or unresolved hooray-gated comments; skipping"
    return 0
  fi

  gh_prepare_pr_workspace "$pr_number" "$meta_json"
  head_sha=$(printf '%s\n' "$meta_json" | jq -r '.headRefOid // ""')
  pending_ids_json=$(gh_pr_pending_comment_ids_json "$CTX_FILE")
  run_claude_for_pr "$pr_number" "$current_stage" "$head_sha" "$meta_json" "$pending_ids_json"
  flush_mark_queues "$pr_number"
  requested_stage=${CLAUDE_REQUESTED_STAGE:-$current_stage}
  next_stage=$(validate_stage_transition "$current_stage" "$requested_stage")
  log_info "stage decision current=$current_stage requested=$requested_stage next=$next_stage"

  if [[ "$next_stage" != "$current_stage" ]]; then
    if gh_post_stage_marker "$pr_number" "$next_stage" >/dev/null; then
      log_info "posted stage marker for $next_stage"
    else
      log_warn "failed to post stage marker; keeping current stage"
      next_stage=$current_stage
    fi
  fi

  persist_system_state "$current_stage" "$next_stage"
  log_info "completed processing"
}

main() {
  local pr_number=${1:-}

  require_cmd bash git jq gh tee awk mktemp
  assert_repo_root
  git_checkout_detached_head
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
