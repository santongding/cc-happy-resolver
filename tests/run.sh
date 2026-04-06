#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/core.sh"
source "$ROOT_DIR/lib/gh.sh"
source "$ROOT_DIR/issue-scan.sh"
source "$ROOT_DIR/worker.sh"

pass_count=0
fail_count=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  return 1
}

assert_eq() {
  local expected=$1
  local actual=$2
  [[ "$expected" == "$actual" ]] || fail "expected [$expected], got [$actual]"
}

assert_ne() {
  local left=$1
  local right=$2
  [[ "$left" != "$right" ]] || fail "did not expect [$left]"
}

run_test() {
  local name=$1
  local status

  set +e
  (
    set -euo pipefail
    "$name"
  )
  status=$?
  set -e

  if [[ $status -eq 0 ]]; then
    printf 'ok - %s\n' "$name"
    pass_count=$((pass_count + 1))
  else
    printf 'not ok - %s\n' "$name"
    fail_count=$((fail_count + 1))
  fi
}

test_repo_slug_parsing() {
  local tmpdir
  tmpdir=$(mktemp -d)
  (
    cd "$tmpdir"
    git init -q
    git remote add origin https://github.com/acme/demo.git
    assert_eq "acme/demo" "$(repo_slug)"
    git remote set-url origin git@github.com:octo/widgets.git
    assert_eq "octo/widgets" "$(repo_slug)"
  )
}

test_state_round_trip_and_array_uniqueness() {
  local tmpdir state_file json
  tmpdir=$(mktemp -d)
  state_file="$tmpdir/pr-1.state.json"
  state_write_json "$state_file" "$(default_state_json)"
  json=$(json_array_add_unique "$(load_state_json "$state_file")" "last_solved_comments" "42")
  json=$(json_array_add_unique "$json" "last_solved_comments" "42")
  state_write_json "$state_file" "$json"
  assert_eq "[42]" "$(jq -c '.last_solved_comments' "$state_file")"
}

test_statectl_updates_are_sanitized_and_scoped() {
  local tmpdir state_file lock_file state_json
  tmpdir=$(mktemp -d)
  state_file="$tmpdir/pr-2.state.json"
  lock_file="$tmpdir/pr-2.lock"
  printf '%s\n' "$$" >"$lock_file"
  state_write_json "$state_file" "$(default_state_json)"

  (
    export PR_LOOP_STATE_FILE="$state_file"
    export PR_LOOP_LOCK_FILE="$lock_file"
    export PR_LOOP_WORKER_PID="$$"
    "$ROOT_DIR/statectl.sh" set-hint $'review\nlater'
    "$ROOT_DIR/statectl.sh" add-solved-comment 5
    "$ROOT_DIR/statectl.sh" add-solved-comment 5
    "$ROOT_DIR/statectl.sh" add-solved-subcomment 9
  )

  state_json=$(load_state_json "$state_file")
  assert_eq "review later" "$(printf '%s\n' "$state_json" | jq -r '.hint')"
  assert_eq "[5]" "$(printf '%s\n' "$state_json" | jq -c '.last_solved_comments')"
  assert_eq "[9]" "$(printf '%s\n' "$state_json" | jq -c '.last_solved_subcomments')"
}

test_stage_parsing_uses_only_strict_markers() {
  local tmpdir ctx_file
  tmpdir=$(mktemp -d)
  ctx_file="$tmpdir/ctx.json"

  cat >"$ctx_file" <<'EOF'
{
  "meta": {"state":"OPEN","headRefOid":"abc"},
  "issueComments": [
    {"id": 1, "body": "> [pr-loop-bot] <!-- PR-LOOP:STAGE:impl:DO-NOT-EDIT -->", "createdAt": "2026-04-06T00:00:00Z", "updatedAt": "2026-04-06T00:00:00Z"},
    {"id": 2, "body": "[pr-loop-bot] <!-- PR-LOOP:STAGE:impl:DO-NOT-EDIT -->\nextra", "createdAt": "2026-04-06T00:01:00Z", "updatedAt": "2026-04-06T00:01:00Z"},
    {"id": 3, "body": "[pr-loop-bot] <!-- PR-LOOP:STAGE:impl:DO-NOT-EDIT -->", "createdAt": "2026-04-06T00:02:00Z", "updatedAt": "2026-04-06T00:02:00Z"},
    {"id": 4, "body": "[pr-loop-bot] <!-- PR-LOOP:STAGE:review:DO-NOT-EDIT -->", "createdAt": "2026-04-06T00:03:00Z", "updatedAt": "2026-04-06T00:03:00Z"}
  ],
  "reviewComments": [],
  "reviews": []
}
EOF

  assert_eq "review" "$(gh_pr_stage "$ctx_file")"
}

test_snapshot_changes_when_review_reply_changes() {
  local tmpdir ctx1 ctx2 snap1 snap2
  tmpdir=$(mktemp -d)
  ctx1="$tmpdir/ctx1.json"
  ctx2="$tmpdir/ctx2.json"

  cat >"$ctx1" <<'EOF'
{
  "meta": {"state":"OPEN","headRefOid":"abc"},
  "issueComments": [],
  "reviewComments": [
    {"id": 10, "updatedAt": "2026-04-06T00:00:00Z", "inReplyToId": null},
    {"id": 11, "updatedAt": "2026-04-06T00:01:00Z", "inReplyToId": 10}
  ],
  "reviews": []
}
EOF

  cat >"$ctx2" <<'EOF'
{
  "meta": {"state":"OPEN","headRefOid":"abc"},
  "issueComments": [],
  "reviewComments": [
    {"id": 10, "updatedAt": "2026-04-06T00:00:00Z", "inReplyToId": null},
    {"id": 11, "updatedAt": "2026-04-06T00:02:00Z", "inReplyToId": 10}
  ],
  "reviews": []
}
EOF

  snap1=$(gh_pr_snapshot "$ctx1")
  snap2=$(gh_pr_snapshot "$ctx2")
  assert_ne "$snap1" "$snap2"
}

test_validate_stage_transition_rules() {
  assert_eq "impl" "$(validate_stage_transition plan impl 0)"
  assert_eq "plan" "$(validate_stage_transition plan review 0)"
  assert_eq "impl" "$(validate_stage_transition impl review 1)"
}

test_entrypoint_script_dirs_are_isolated_from_libs() {
  (
    source "$ROOT_DIR/pr-loop.sh"
    source "$ROOT_DIR/issue-scan.sh"
    source "$ROOT_DIR/worker.sh"
    source "$ROOT_DIR/statectl.sh"

    assert_eq "$ROOT_DIR" "$PR_LOOP_LOOP_DIR"
    assert_eq "$ROOT_DIR" "$PR_LOOP_ISSUE_SCAN_DIR"
    assert_eq "$ROOT_DIR" "$PR_LOOP_WORKER_DIR"
    assert_eq "$ROOT_DIR" "$PR_LOOP_STATECTL_DIR"
    assert_eq "$ROOT_DIR/lib" "$PR_LOOP_GH_LIB_DIR"
  )
}

test_find_related_pr_number_matches_branch_or_issue_reference() {
  local prs_json

  prs_json=$(cat <<'EOF'
[
  {"number": 12, "headRefName": "feature/elsewhere", "title": "Unrelated", "body": ""},
  {"number": 13, "headRefName": "cc-happy/issue-42", "title": "Seeded", "body": ""},
  {"number": 14, "headRefName": "feature/manual", "title": "Fixes #99", "body": ""}
]
EOF
)

  assert_eq "13" "$(gh_find_related_pr_number 42 "$prs_json")"
  assert_eq "14" "$(gh_find_related_pr_number 99 "$prs_json")"
  assert_eq "" "$(gh_find_related_pr_number 777 "$prs_json")"
}

test_seed_issue_branch_creates_plan_branch_from_default() {
  local tmpdir origin_repo work_repo diff_output plan_blob
  tmpdir=$(mktemp -d)
  origin_repo="$tmpdir/origin.git"
  work_repo="$tmpdir/work"

  git init --bare "$origin_repo" >/dev/null
  git clone "$origin_repo" "$work_repo" >/dev/null 2>&1

  (
    cd "$work_repo"
    git checkout -b main >/dev/null
    printf 'hello\n' > README.md
    git -c user.name='Tester' -c user.email='tester@example.com' add README.md
    git -c user.name='Tester' -c user.email='tester@example.com' commit -m init >/dev/null
    git push -u origin main >/dev/null
    gh_seed_issue_branch 123 main
    git fetch origin "refs/heads/cc-happy/issue-123:refs/remotes/origin/cc-happy/issue-123" >/dev/null
    diff_output=$(git diff --name-status origin/main origin/cc-happy/issue-123)
    plan_blob=$(git show origin/cc-happy/issue-123:PLAN.md)

    assert_eq $'A\tPLAN.md' "$diff_output"
    assert_eq "" "$plan_blob"
    assert_eq "$(git show origin/main:README.md)" "$(git show origin/cc-happy/issue-123:README.md)"
  )
}

test_scan_open_issues_creates_missing_prs_only() {
  local tmpdir actions_file
  tmpdir=$(mktemp -d)
  actions_file="$tmpdir/actions.log"

  (
    source "$ROOT_DIR/issue-scan.sh"
    export PR_LOOP_LOG_REPO=test__repo
    export TEST_ISSUES_LOCK="$tmpdir/issues.lock"
    export TEST_ACTIONS_FILE="$actions_file"
    export TEST_PRS_JSON='[{"number":200,"headRefName":"cc-happy/issue-2","title":"Existing seed","body":""}]'

    issue_scan_lock_file() { printf '%s\n' "$TEST_ISSUES_LOCK"; }
    acquire_lock() { printf '%s\n' "$$" >"$1"; return 0; }
    release_lock() { rm -f "$1"; return 0; }
    gh_list_open_issues() {
      cat <<'EOF'
[{"number":1,"title":"First issue","body":"","updatedAt":"2026-04-06T00:00:00Z"},{"number":2,"title":"Second issue","body":"","updatedAt":"2026-04-06T00:00:00Z"}]
EOF
    }
    gh_list_open_prs() { printf '%s\n' "$TEST_PRS_JSON"; }
    gh_repo_default_branch() { printf '%s\n' "main"; }
    gh_seed_issue_branch() {
      printf 'seed:%s:%s\n' "$1" "$2" >>"$TEST_ACTIONS_FILE"
    }
    gh_create_issue_pr() {
      printf 'pr:%s:%s:%s\n' "$1" "$2" "$3" >>"$TEST_ACTIONS_FILE"
      TEST_PRS_JSON='[{"number":200,"headRefName":"cc-happy/issue-2","title":"Existing seed","body":""},{"number":201,"headRefName":"cc-happy/issue-1","title":"Issue #1: First issue","body":"Closes #1"}]'
      export TEST_PRS_JSON
    }

    scan_open_issues
  )

  assert_eq $'seed:1:main\npr:1:First issue:main' "$(cat "$actions_file")"
}

test_process_pr_reloads_state_and_recomputes_snapshot() {
  local tmpdir state_file lock_file final_state expected_snapshot

  tmpdir=$(mktemp -d)
  state_file="$tmpdir/pr-7.state.json"
  lock_file="$tmpdir/pr-7.lock"
  state_write_json "$state_file" "$(default_state_json)"

  (
    source "$ROOT_DIR/worker.sh"
    source "$ROOT_DIR/lib/gh.sh"
    export PR_LOOP_LOG_REPO=test__repo
    export TEST_TMPDIR="$tmpdir"
    export TEST_STATE_FILE="$state_file"
    export TEST_LOCK_FILE="$lock_file"
    export TEST_POSTED_STAGE=
    export TEST_COLLECT_PHASE=pre

    repo_state_dir() { printf '%s\n' "$TEST_TMPDIR"; }
    ensure_repo_state_dir() { mkdir -p "$TEST_TMPDIR"; printf '%s\n' "$TEST_TMPDIR"; }
    pr_state_file() { printf '%s\n' "$TEST_STATE_FILE"; }
    pr_lock_file() { printf '%s\n' "$TEST_LOCK_FILE"; }
    acquire_lock() { printf '%s\n' "$$" >"$1"; return 0; }
    release_lock() { rm -f "$1"; return 0; }
    gh_pr_meta() {
      if [[ "${TEST_COLLECT_PHASE:-pre}" == "post" ]]; then
        cat <<'EOF'
{"number":7,"state":"OPEN","updatedAt":"2026-04-06T00:02:00Z","headRefOid":"abc","headRefName":"feature","headRepositoryCloneUrl":"https://github.com/acme/demo.git","isCrossRepository":false,"title":"Test PR","htmlUrl":"https://example.invalid/pr/7"}
EOF
      else
        cat <<'EOF'
{"number":7,"state":"OPEN","updatedAt":"2026-04-06T00:01:00Z","headRefOid":"abc","headRefName":"feature","headRepositoryCloneUrl":"https://github.com/acme/demo.git","isCrossRepository":false,"title":"Test PR","htmlUrl":"https://example.invalid/pr/7"}
EOF
      fi
    }
    gh_collect_context() {
      if [[ "${TEST_COLLECT_PHASE:-pre}" == "post" ]]; then
        cat <<'EOF'
{"meta":{"state":"OPEN","headRefOid":"abc","updatedAt":"2026-04-06T00:02:00Z"},"issueComments":[{"id":101,"body":"[pr-loop-bot] <!-- PR-LOOP:STAGE:impl:DO-NOT-EDIT -->","createdAt":"2026-04-06T00:02:00Z","updatedAt":"2026-04-06T00:02:00Z"}],"reviewComments":[],"reviews":[]}
EOF
      else
        cat <<'EOF'
{"meta":{"state":"OPEN","headRefOid":"abc","updatedAt":"2026-04-06T00:01:00Z"},"issueComments":[],"reviewComments":[],"reviews":[]}
EOF
      fi
    }
    gh_prepare_pr_workspace() {
      export PR_LOOP_PUSH_REMOTE=origin
      export PR_LOOP_PUSH_REF=feature
    }
    run_claude_for_pr() {
      export PR_LOOP_STATE_FILE="$TEST_STATE_FILE"
      export PR_LOOP_LOCK_FILE="$TEST_LOCK_FILE"
      export PR_LOOP_WORKER_PID="$$"
      "$ROOT_DIR/statectl.sh" set-hint "focus reviewer" >/dev/null
      "$ROOT_DIR/statectl.sh" add-solved-comment 99 >/dev/null
      printf '%s\n' "impl"
    }
    gh_post_stage_marker() {
      TEST_POSTED_STAGE=$2
      export TEST_COLLECT_PHASE=post
      return 0
    }
    git_worktree_dirty() { return 1; }

    process_pr 7
    assert_eq "impl" "$TEST_POSTED_STAGE"
  )

  final_state=$(load_state_json "$state_file")
  expected_snapshot=$(cat <<'EOF' | jq -cS . | sha256_stream
{"state":"OPEN","headRefOid":"abc","stage":"impl","issueComments":[{"id":101,"updatedAt":"2026-04-06T00:02:00Z"}],"reviewComments":[]}
EOF
)
  assert_eq "focus reviewer" "$(printf '%s\n' "$final_state" | jq -r '.hint')"
  assert_eq "[99]" "$(printf '%s\n' "$final_state" | jq -c '.last_solved_comments')"
  assert_eq "2026-04-06T00:02:00Z" "$(printf '%s\n' "$final_state" | jq -r '.last_pr_updated_at')"
  assert_eq "$expected_snapshot" "$(printf '%s\n' "$final_state" | jq -r '.last_snapshot')"
}

main() {
  require_cmd bash git jq mktemp
  bash -n "$ROOT_DIR/pr-loop.sh" "$ROOT_DIR/issue-scan.sh" "$ROOT_DIR/worker.sh" "$ROOT_DIR/statectl.sh" "$ROOT_DIR/lib/core.sh" "$ROOT_DIR/lib/gh.sh"

  run_test test_repo_slug_parsing
  run_test test_state_round_trip_and_array_uniqueness
  run_test test_statectl_updates_are_sanitized_and_scoped
  run_test test_stage_parsing_uses_only_strict_markers
  run_test test_snapshot_changes_when_review_reply_changes
  run_test test_validate_stage_transition_rules
  run_test test_entrypoint_script_dirs_are_isolated_from_libs
  run_test test_find_related_pr_number_matches_branch_or_issue_reference
  run_test test_seed_issue_branch_creates_plan_branch_from_default
  run_test test_scan_open_issues_creates_missing_prs_only
  run_test test_process_pr_reloads_state_and_recomputes_snapshot

  printf '\nPassed: %d\nFailed: %d\n' "$pass_count" "$fail_count"
  [[ "$fail_count" -eq 0 ]]
}

main "$@"
