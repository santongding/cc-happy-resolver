#!/usr/bin/env bash
set -euo pipefail

PR_LOOP_LOOP_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$PR_LOOP_LOOP_DIR/lib/core.sh"
source "$PR_LOOP_LOOP_DIR/lib/gh.sh"

PR_LOOP_LOG_MODULE=loop

dispatch_pr() {
  local pr_number=$1
  log_info "dispatching worker for PR #$pr_number"
  "$PR_LOOP_LOOP_DIR/worker.sh" "$pr_number"
  log_info "worker finished for PR #$pr_number"
}

loop_once() {
  local prs_json pr_count

  prs_json=$(gh_list_open_prs)
  pr_count=$(jq 'length' <<<"$prs_json")
  log_info "scan found $pr_count open PR(s)"
  jq -r '.[].number' <<<"$prs_json" | while IFS= read -r pr_number; do
    [[ -n "$pr_number" ]] || continue
    dispatch_pr "$pr_number"
  done
}

main() {
  local interval=${PR_LOOP_POLL_SECONDS:-30}
  local once=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --once)
        once=1
        ;;
      --interval)
        shift
        interval=${1:-$interval}
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
    shift || true
  done

  require_cmd bash git jq gh
  assert_repo_root
  ensure_repo_state_dir >/dev/null
  export PR_LOOP_LOG_REPO="$(repo_key)"
  log_info "starting loop at $(pwd -P) with poll interval ${interval}s${once:+ (once mode=$once)}"

  while true; do
    log_info "starting scan iteration"
    "$PR_LOOP_LOOP_DIR/issue-scan.sh"
    loop_once
    if [[ "$once" == "1" ]]; then
      log_info "completed single scan iteration"
      break
    fi
    log_info "sleeping for ${interval}s before next scan"
    sleep "$interval"
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
