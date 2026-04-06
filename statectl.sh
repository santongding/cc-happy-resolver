#!/usr/bin/env bash
set -euo pipefail

PR_LOOP_STATECTL_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$PR_LOOP_STATECTL_DIR/lib/core.sh"

PR_LOOP_LOG_MODULE=statectl

require_lock_context() {
  [[ -n "${PR_LOOP_STATE_FILE:-}" ]] || die "PR_LOOP_STATE_FILE is required"
  [[ -n "${PR_LOOP_LOCK_FILE:-}" ]] || die "PR_LOOP_LOCK_FILE is required"
  [[ -n "${PR_LOOP_WORKER_PID:-}" ]] || die "PR_LOOP_WORKER_PID is required"
  [[ -f "${PR_LOOP_LOCK_FILE}" ]] || die "worker lock file is missing"
  kill -0 "$PR_LOOP_WORKER_PID" >/dev/null 2>&1 || die "worker process is not running"

  local owner_pid
  owner_pid=$(cat "$PR_LOOP_LOCK_FILE" 2>/dev/null || true)
  [[ -n "$owner_pid" && "$owner_pid" == "$PR_LOOP_WORKER_PID" ]] || die "worker lock ownership check failed"
  log_info "validated worker lock context for pid=$PR_LOOP_WORKER_PID"
}

sanitize_hint() {
  local raw=$1
  local max_len=${PR_LOOP_HINT_MAX_LEN:-$PR_LOOP_DEFAULT_HINT_MAX}
  local single_line

  single_line=$(printf '%s' "$raw" | tr '\r\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')
  printf '%s' "${single_line:0:max_len}"
}

write_state_json() {
  local next_json=$1
  state_write_json "$PR_LOOP_STATE_FILE" "$next_json"
}

write_array_add_unique() {
  local field=$1
  local raw_value=$2

  write_state_json "$(
    json_array_add_unique "$(load_state_json "$PR_LOOP_STATE_FILE")" "$field" "$raw_value" \
      | jq -c --arg updated_at "$(now_utc)" '.updated_at = $updated_at'
  )"
}

cmd_set_hint() {
  local hint
  hint=$(sanitize_hint "${1:-}")
  log_info "updating hint to: ${hint:-<empty>}"
  write_state_json "$(load_state_json "$PR_LOOP_STATE_FILE" | jq -c --arg hint "$hint" --arg updated_at "$(now_utc)" '
    .hint = $hint
    | .updated_at = $updated_at
  ')"
}

cmd_add_solved_comment() {
  local comment_id=$1
  [[ "$comment_id" =~ ^[0-9]+$ ]] || die "comment id must be numeric"
  log_info "recording solved external comment id=$comment_id"
  write_array_add_unique "last_solved_comment_ids" "$comment_id"
}

cmd_add_solved_subcomment() {
  local comment_id=$1
  [[ "$comment_id" =~ ^[0-9]+$ ]] || die "subcomment id must be numeric"
  log_info "recording solved external subcomment id=$comment_id"
  write_array_add_unique "last_solved_comment_ids" "$comment_id"
}

cmd_add_bot_comment() {
  local comment_id=$1
  [[ "$comment_id" =~ ^[0-9]+$ ]] || die "bot comment id must be numeric"
  log_info "recording recent bot comment id=$comment_id"
  write_array_add_unique "recent_bot_comment_ids" "$comment_id"
}

cmd_add_bot_issue_comment() {
  local comment_id=$1
  cmd_add_bot_comment "$comment_id"
}

cmd_add_bot_review_reply() {
  local comment_id=$1
  cmd_add_bot_comment "$comment_id"
}

cmd_clear_recent_bot_comments() {
  log_info "clearing recent bot comment ids"
  write_state_json "$(load_state_json "$PR_LOOP_STATE_FILE" | jq -c --arg updated_at "$(now_utc)" '
    .recent_bot_comment_ids = []
    | .updated_at = $updated_at
  ')"
}

cmd_set_last_head_sha() {
  local sha=$1
  [[ "$sha" =~ ^[0-9a-fA-F]{6,64}$ ]] || die "head sha must be a hex string"
  log_info "recording last head sha=${sha:0:12}"
  write_state_json "$(load_state_json "$PR_LOOP_STATE_FILE" | jq -c --arg sha "$sha" --arg updated_at "$(now_utc)" '
    .last_head_sha = $sha
    | .updated_at = $updated_at
  ')"
}

cmd_mark_updated() {
  log_info "touching state updated_at"
  write_state_json "$(load_state_json "$PR_LOOP_STATE_FILE" | jq -c --arg updated_at "$(now_utc)" '.updated_at = $updated_at')"
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

  log_info "recording next stage=$stage"
  write_state_json "$(load_state_json "$PR_LOOP_STATE_FILE" | jq -c --arg stage "$stage" --arg updated_at "$(now_utc)" '
    .next_stage = $stage
    | .updated_at = $updated_at
  ')"
}

cmd_clear_next_stage() {
  log_info "clearing pending next stage"
  write_state_json "$(load_state_json "$PR_LOOP_STATE_FILE" | jq -c --arg updated_at "$(now_utc)" '
    .next_stage = ""
    | .updated_at = $updated_at
  ')"
}

main() {
  require_cmd jq sed tr
  require_lock_context

  local subcommand=${1:-}
  shift || true
  log_info "statectl command=${subcommand:-<empty>} state_file=$PR_LOOP_STATE_FILE"

  case "$subcommand" in
    set-hint)
      cmd_set_hint "${1:-}"
      ;;
    add-solved-comment)
      cmd_add_solved_comment "${1:-}"
      ;;
    add-solved-subcomment)
      cmd_add_solved_subcomment "${1:-}"
      ;;
    add-bot-comment)
      cmd_add_bot_comment "${1:-}"
      ;;
    add-bot-issue-comment)
      cmd_add_bot_issue_comment "${1:-}"
      ;;
    add-bot-review-reply)
      cmd_add_bot_review_reply "${1:-}"
      ;;
    clear-recent-bot-comments)
      cmd_clear_recent_bot_comments
      ;;
    set-last-head-sha)
      cmd_set_last_head_sha "${1:-}"
      ;;
    mark-updated)
      cmd_mark_updated
      ;;
    set-next-stage)
      cmd_set_next_stage "${1:-}"
      ;;
    clear-next-stage)
      cmd_clear_next_stage
      ;;
    *)
      die "unknown command: ${subcommand:-<empty>}"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
