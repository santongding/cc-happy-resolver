#!/usr/bin/env bash
set -euo pipefail

PR_LOOP_ISSUE_SCAN_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$PR_LOOP_ISSUE_SCAN_DIR/lib/core.sh"
source "$PR_LOOP_ISSUE_SCAN_DIR/lib/gh.sh"

PR_LOOP_LOG_MODULE=issue-scan

scan_open_issues() {
  local issues_json prs_json issue_count default_branch lock_file
  local issue_json issue_number issue_title related_pr scanner_locked=0
  local scan_status=0

  lock_file=$(issue_scan_lock_file)
  if ! acquire_lock "$lock_file"; then
    log_info "issue scanner lock busy, skipping"
    return 0
  fi
  scanner_locked=1
  log_info "acquired issue scanner lock $lock_file"

  (
    set -euo pipefail

    issues_json=$(gh_list_open_issues)
    issue_count=$(jq 'length' <<<"$issues_json")
    log_info "issue scan found $issue_count open issue(s)"

    if [[ "$issue_count" -eq 0 ]]; then
      exit 0
    fi

    prs_json=$(gh_list_open_prs)
    default_branch=$(gh_repo_default_branch)
    [[ -n "$default_branch" ]] || die "failed to determine default branch"
    log_info "issue scan will seed missing PRs from default branch $default_branch"

    while IFS= read -r issue_json; do
      [[ -n "$issue_json" ]] || continue
      issue_number=$(jq -r '.number' <<<"$issue_json")
      issue_title=$(jq -r '.title // ""' <<<"$issue_json")
      related_pr=$(gh_find_related_pr_number "$issue_number" "$prs_json")

      if [[ -n "$related_pr" ]]; then
        log_info "issue #$issue_number already has related PR #$related_pr"
        continue
      fi

      log_info "issue #$issue_number has no related PR; seeding branch and creating PR"
      if gh_seed_issue_branch "$issue_number" "$default_branch" \
        && gh_create_issue_pr "$issue_number" "$issue_title" "$default_branch"; then
        log_info "created seed PR for issue #$issue_number"
        prs_json=$(gh_list_open_prs)
        continue
      fi

      prs_json=$(gh_list_open_prs)
      related_pr=$(gh_find_related_pr_number "$issue_number" "$prs_json")
      if [[ -n "$related_pr" ]]; then
        log_info "issue #$issue_number gained related PR #$related_pr during creation attempt"
        continue
      fi

      log_warn "failed to create seed PR for issue #$issue_number"
    done < <(jq -c '.[]' <<<"$issues_json")
  ) || scan_status=$?

  if [[ "$scanner_locked" == "1" ]]; then
    release_lock "$lock_file"
    log_info "released issue scanner lock $lock_file"
  fi

  return "$scan_status"
}

main() {
  require_cmd bash git jq gh
  assert_repo_root
  ensure_repo_state_dir >/dev/null
  export PR_LOOP_LOG_REPO="$(repo_key)"
  log_info "starting issue scan in repo $(pwd -P)"
  scan_open_issues
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
