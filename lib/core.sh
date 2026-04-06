#!/usr/bin/env bash

if [[ -n "${PR_LOOP_CORE_SH_LOADED:-}" ]]; then
  return 0
fi
PR_LOOP_CORE_SH_LOADED=1

readonly PR_LOOP_DEFAULT_HINT_MAX=240

log_prefix() {
  printf '[pr-loop][repo=%s][pr=%s][%s]' \
    "${PR_LOOP_LOG_REPO:-?}" \
    "${PR_LOOP_LOG_PR:--}" \
    "${PR_LOOP_LOG_MODULE:-main}"
}

log_info() {
  printf '%s %s\n' "$(log_prefix)" "$*" >&2
}

log_warn() {
  printf '%s WARN: %s\n' "$(log_prefix)" "$*" >&2
}

log_error() {
  printf '%s ERROR: %s\n' "$(log_prefix)" "$*" >&2
}

die() {
  log_error "$*"
  return 1
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
  done
}

repo_slug_from_url() {
  local remote_url=$1
  local slug=

  case "$remote_url" in
    git@github.com:*)
      slug=${remote_url#git@github.com:}
      ;;
    ssh://git@github.com/*)
      slug=${remote_url#ssh://git@github.com/}
      ;;
    https://github.com/*)
      slug=${remote_url#https://github.com/}
      ;;
    http://github.com/*)
      slug=${remote_url#http://github.com/}
      ;;
    git://github.com/*)
      slug=${remote_url#git://github.com/}
      ;;
    *)
      die "origin remote is not a GitHub URL: $remote_url"
      return 1
      ;;
  esac

  slug=${slug%.git}
  [[ "$slug" =~ ^[^/]+/[^/]+$ ]] || die "failed to parse GitHub slug from origin: $remote_url"
  printf '%s\n' "$slug"
}

repo_slug() {
  local remote_url
  remote_url=$(git remote get-url origin 2>/dev/null) || {
    die "failed to resolve origin remote"
    return 1
  }
  repo_slug_from_url "$remote_url"
}

assert_repo_root() {
  local top
  top=$(git rev-parse --show-toplevel 2>/dev/null) || {
    die "current directory is not inside a git repository"
    return 1
  }
  [[ "$(cd "$top" && pwd -P)" == "$(pwd -P)" ]] || die "current directory must be the git repository root"
  repo_slug >/dev/null
}

git_checkout_detached_head() {
  local current_branch current_head

  current_branch=$(git symbolic-ref -q --short HEAD 2>/dev/null || true)
  if [[ -z "$current_branch" ]]; then
    log_info "git HEAD is already detached"
    return 0
  fi

  current_head=$(git rev-parse --verify HEAD 2>/dev/null) || {
    die "failed to resolve HEAD before detaching"
    return 1
  }

  log_info "detaching git HEAD from branch $current_branch at ${current_head:0:12}"
  git checkout --detach "$current_head" >/dev/null
}

repo_key() {
  local slug
  slug=$(repo_slug) || return 1
  printf '%s\n' "${slug/\//__}"
}

repo_state_dir() {
  local root="${PR_LOOP_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/pr-loop}"
  printf '%s/%s\n' "$root" "$(repo_key)"
}

ensure_repo_state_dir() {
  local dir
  dir=$(repo_state_dir) || return 1
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

pr_state_file() {
  local pr_number=$1
  printf '%s/pr-%s.state.json\n' "$(ensure_repo_state_dir)" "$pr_number"
}

pr_lock_file() {
  local pr_number=$1
  printf '%s/pr-%s.lock\n' "$(ensure_repo_state_dir)" "$pr_number"
}

issue_scan_lock_file() {
  printf '%s/issues-scan.lock\n' "$(ensure_repo_state_dir)"
}

default_state_json() {
  cat <<'EOF'
{"current_stage":"","hint":"","last_head_sha":"","last_pr_updated_at":"","last_snapshot":"","last_solved_comment_ids":[],"last_stage":"","recent_bot_comment_ids":[],"updated_at":""}
EOF
}

load_state_json() {
  local file=$1
  local backup

  if [[ ! -f "$file" ]]; then
    default_state_json
    return 0
  fi

  if jq -e . "$file" >/dev/null 2>&1; then
    jq -cS '
      .last_solved_comment_ids = (
        ((.last_solved_comment_ids // [])
        + (.last_solved_comments // [])
        + (.last_solved_subcomments // []))
        | unique
      )
      | .recent_bot_comment_ids = (
        ((.recent_bot_comment_ids // [])
        + (.recent_bot_issue_comment_ids // [])
        + (.recent_bot_review_reply_ids // []))
        | unique
      )
      | .last_stage = (.last_stage // "")
      | .current_stage = (.current_stage // .next_stage // "")
      | del(
          .last_solved_comments,
          .last_solved_subcomments,
          .next_stage,
          .recent_bot_issue_comment_ids,
          .recent_bot_review_reply_ids
        )
    ' "$file"
    return 0
  fi

  backup="${file}.corrupt.$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || printf '%s' "$$")"
  cp "$file" "$backup" 2>/dev/null || true
  log_warn "state file is invalid JSON, using defaults and preserving a backup at $backup"
  default_state_json
}

state_read_json() {
  local file=$1
  local jq_filter=$2
  local default_value=${3-}
  local output

  if output=$(load_state_json "$file" | jq -cer "$jq_filter" 2>/dev/null); then
    printf '%s\n' "$output"
    return 0
  fi

  if [[ $# -ge 3 ]]; then
    printf '%s\n' "$default_value"
    return 0
  fi

  return 1
}

atomic_write() {
  local target=$1
  local dir tmp

  dir=$(dirname "$target")
  mkdir -p "$dir"
  tmp=$(mktemp "$dir/.tmp.$(basename "$target").XXXXXX")
  cat >"$tmp"
  mv -f "$tmp" "$target"
}

state_write_json() {
  local file=$1
  local json=$2
  local normalized

  normalized=$(printf '%s\n' "$json" | jq -cS .) || {
    die "refusing to write invalid JSON to $file"
    return 1
  }
  printf '%s\n' "$normalized" | atomic_write "$file"
}

json_array_add_unique() {
  local json=$1
  local field=$2
  local raw_value=$3

  printf '%s\n' "$json" | jq -c --arg field "$field" --arg raw "$raw_value" '
    .[$field] = (
      ((.[$field] // []) + [($raw | fromjson? // $raw)])
      | unique
    )
  '
}

now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

sha256_stream() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

acquire_lock() {
  local lock_file=$1

  mkdir -p "$(dirname "$lock_file")"

  if command -v flock >/dev/null 2>&1; then
    eval "exec ${PR_LOOP_LOCK_FD:-200}>\"$lock_file\""
    local fd=${PR_LOOP_LOCK_FD:-200}
    if flock -n "$fd"; then
      printf '%s\n' "$$" >"$lock_file"
      PR_LOOP_LOCK_BACKEND=flock
      PR_LOOP_LOCK_FD=$fd
      return 0
    fi
    return 1
  fi

  if command -v shlock >/dev/null 2>&1 && shlock -f "$lock_file" -p "$$" >/dev/null 2>&1; then
    PR_LOOP_LOCK_BACKEND=shlock
    return 0
  fi

  return 1
}

release_lock() {
  local lock_file=$1

  if [[ "${PR_LOOP_LOCK_BACKEND:-}" == "flock" ]]; then
    eval "exec ${PR_LOOP_LOCK_FD:-200}>&-"
    rm -f "$lock_file"
    PR_LOOP_LOCK_BACKEND=
    PR_LOOP_LOCK_FD=
    return 0
  fi

  if [[ "${PR_LOOP_LOCK_BACKEND:-}" == "shlock" ]]; then
    rm -f "$lock_file"
    PR_LOOP_LOCK_BACKEND=
    return 0
  fi

  return 0
}
