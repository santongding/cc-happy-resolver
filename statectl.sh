#!/usr/bin/env bash
set -euo pipefail

PR_LOOP_STATECTL_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$PR_LOOP_STATECTL_DIR/lib/core.sh"

PR_LOOP_LOG_MODULE=statectl

require_lock_context() {
  [[ -n "${PR_LOOP_STATE_FILE:-}" ]] || die "PR_LOOP_STATE_FILE is required"
  [[ -n "${PR_LOOP_LOCK_FILE:-}" ]] || die "PR_LOOP_LOCK_FILE is required"
  [[ -n "${PR_LOOP_PR_NUMBER:-}" ]] || die "PR_LOOP_PR_NUMBER is required"
  [[ -n "${PR_LOOP_WORKER_PID:-}" ]] || die "PR_LOOP_WORKER_PID is required"
  [[ -f "${PR_LOOP_LOCK_FILE}" ]] || die "worker lock file is missing"
  kill -0 "$PR_LOOP_WORKER_PID" >/dev/null 2>&1 || die "worker process is not running"

  local owner_pid
  owner_pid=$(cat "$PR_LOOP_LOCK_FILE" 2>/dev/null || true)
  [[ -n "$owner_pid" && "$owner_pid" == "$PR_LOOP_WORKER_PID" ]] || die "worker lock ownership check failed"
  log_info "validated worker lock context for pid=$PR_LOOP_WORKER_PID"
}

write_state_json() {
  local next_json=$1
  state_write_json "$PR_LOOP_STATE_FILE" "$next_json"
}

append_numeric_id() {
  local file=$1
  local comment_id=$2
  printf '%s\n' "$comment_id" >>"$file"
}

comment_mark_file() {
  printf '%s/pr-%s.mark-comment.ids\n' "$(dirname "$PR_LOOP_STATE_FILE")" "$PR_LOOP_PR_NUMBER"
}

subcomment_mark_file() {
  printf '%s/pr-%s.mark-sub-comment.ids\n' "$(dirname "$PR_LOOP_STATE_FILE")" "$PR_LOOP_PR_NUMBER"
}

cmd_mark_comment() {
  local comment_id=$1
  [[ "$comment_id" =~ ^[0-9]+$ ]] || die "comment id must be numeric"
  log_info "queueing issue comment id=$comment_id for hooray"
  append_numeric_id "$(comment_mark_file)" "$comment_id"
}

cmd_mark_subcomment() {
  local comment_id=$1
  [[ "$comment_id" =~ ^[0-9]+$ ]] || die "subcomment id must be numeric"
  log_info "queueing review comment id=$comment_id for hooray"
  append_numeric_id "$(subcomment_mark_file)" "$comment_id"
}

cmd_set_next_stage() {
  local stage=$1

  case "$stage" in
    plan|impl|review|finished)
      ;;
    *)
      die "next stage must be one of: plan, impl, review, finished"
      return 1
      ;;
  esac

  log_info "rolling stage state to next stage=$stage"
  write_state_json "$(load_state_json "$PR_LOOP_STATE_FILE" | jq -c --arg stage "$stage" --arg updated_at "$(now_utc)" '
    .last_stage = (.current_stage // "")
    | .current_stage = $stage
    | .updated_at = $updated_at
  ')"
}

main() {
  require_cmd jq
  require_lock_context

  local subcommand=${1:-}
  shift || true
  log_info "statectl command=${subcommand:-<empty>} state_file=$PR_LOOP_STATE_FILE"

  case "$subcommand" in
    mark-comment)
      cmd_mark_comment "${1:-}"
      ;;
    mark-sub-comment)
      cmd_mark_subcomment "${1:-}"
      ;;
    set-next-stage)
      cmd_set_next_stage "${1:-}"
      ;;
    *)
      die "unknown command: ${subcommand:-<empty>}"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
