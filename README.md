# cc-happy-resolver

`cc-happy-resolver` is a shell-based GitHub PR triage loop for repositories that use Claude to move pull requests through a staged workflow.

It does three things:

- Scans open issues and creates a seed branch + seed PR when an issue does not already have one.
- Scans open PRs and runs a worker against each PR that needs another pass.
- Tracks per-PR state so the worker only re-runs when GitHub-visible state changes or when the stage advances.

## What It Can Do

- Detect open GitHub issues that do not have a related PR.
- Create a branch named `cc-happy/issue-<number>` from the default branch.
- Create a seed commit containing `PROGRESS.md` so the branch is pushable.
- Open a PR for that issue automatically.
- Read PR metadata, issue comments, review comments, and reviews.
- Infer the PR stage from bot stage-marker comments.
- Prepare a clean local checkout of the PR branch.
- Invoke Claude with the bundled `cc-happy-resolver` skill for a single pass.
- Persist state such as last snapshot, last stage, solved comment IDs, and hints between passes.

## How It Works

Each PR moves through these stages:

- `plan`
- `impl`
- `review`
- `finished`

The worker reads the current PR context, runs one Claude pass for the current stage, and expects Claude to record the next stage through `statectl.sh`. Stage changes are published back to GitHub as bot comments so the next pass can resume from the right point.

The loop stores state under:

```text
$XDG_STATE_HOME/pr-loop/<owner>__<repo>/
```

If `XDG_STATE_HOME` is unset, it falls back to:

```text
$HOME/.local/state/pr-loop/<owner>__<repo>/
```

## Prerequisites

You need:

- `bash`
- `git`
- `jq`
- `gh`
- `claude`
- `flock` or `shlock` for locking

GitHub requirements:

- Run inside the repository root.
- The repository must have an `origin` remote that points to GitHub.
- `gh` must already be authenticated and able to read/write PRs and issues.

Claude requirements:

- Claude CLI must be installed.
- The bundled skill is installed to `~/.claude/skills/cc-happy-resolver` by `make install`.

## Install

Install the scripts and Claude skill:

```bash
make install
```

By default this installs:

- `pr-loop` to `~/.local/bin/pr-loop`
- helper scripts to `~/.local/lib/pr-loop`
- the Claude skill to `~/.claude/skills/cc-happy-resolver`

Run the test suite with:

```bash
make test
```

Remove the installation with:

```bash
make uninstall
```

## How To Use It

### 1. Run a single scan

Use this when you want one pass over issues and PRs:

```bash
pr-loop --once
```

This will:

- scan open issues and create missing seed PRs
- scan open PRs
- run `worker.sh` for each PR that is not already up to date

### 2. Run continuously

Use this for a polling loop:

```bash
pr-loop
```

Default poll interval is 30 seconds.

Set a custom interval:

```bash
pr-loop --interval 120
```

Or with an environment variable:

```bash
PR_LOOP_POLL_SECONDS=120 pr-loop
```

### 3. Scan issues only

If you only want the issue-to-seed-PR behavior:

```bash
./issue-scan.sh
```

This checks open issues, finds ones without a related PR, creates a seed branch, and opens a PR.

### 4. Process one PR manually

If you want to run the worker on one PR directly:

```bash
./worker.sh 123
```

This fetches PR context, checks out a clean copy of the PR branch locally, runs one Claude pass, and persists updated state.

## Important Behavior

`worker.sh` makes the local checkout match the PR branch exactly before running Claude. It does this with:

- `git fetch`
- `git checkout -B`
- `git reset --hard`
- `git clean -ffd`

Use it in a dedicated repository checkout, not in a working tree with local changes you care about.

## Related PR Detection

An issue is considered to already have a related PR if any PR, including closed or merged PRs, matches one of these:

- the head branch is `cc-happy/issue-<number>`
- the PR title mentions `#<number>`
- the PR body mentions `#<number>`

## Stage Markers

The current PR stage is read from PR issue comments posted by the bot. The worker posts markers in this format:

```text
[pr-loop-bot] PR-LOOP:STAGE:<plan|impl|review|finished>:DO-NOT-EDIT
```

If no valid stage marker exists yet, the PR starts at `plan`.

## Configuration

Useful environment variables:

- `PR_LOOP_POLL_SECONDS`: default polling interval for `pr-loop`
- `PR_LOOP_STATE_ROOT`: override the state directory root
- `PR_LOOP_CLAUDE_CMD`: override the Claude command used by `worker.sh`
- `PR_LOOP_CLAUDE_PROMPT_TEMPLATE`: override the prompt template file
- `PR_LOOP_CLAUDE_OUTPUT_FILTER`: override the stream filter script
- `PR_LOOP_PUSH_REMOTE`: override the remote used when pushing changes from the Claude pass
- `PR_LOOP_PUSH_REF`: override the branch ref used when pushing changes from the Claude pass
- `PR_LOOP_GIT_USER_NAME`: author name for seed commits
- `PR_LOOP_GIT_USER_EMAIL`: author email for seed commits
- `PR_LOOP_GH_API_RETRY_MAX_ATTEMPTS`: GitHub API retry count
- `PR_LOOP_GH_API_RETRY_DELAY_SECONDS`: GitHub API retry delay
- `PR_LOOP_HINT_MAX_LEN`: max stored hint length for `statectl.sh set-hint`

## Repository Layout

Key files:

- `pr-loop.sh`: top-level polling loop
- `issue-scan.sh`: issue scanner and seed PR creator
- `worker.sh`: single-PR processor
- `statectl.sh`: safe state mutation helper for Claude passes
- `lib/core.sh`: shared filesystem, locking, and state helpers
- `lib/gh.sh`: GitHub-specific operations
- `skills/cc-happy-resolver/`: Claude skill files used by the worker

## Typical Flow

1. Run `pr-loop --once` or `pr-loop`.
2. Missing issue PRs are created automatically.
3. Each open PR is inspected.
4. If its snapshot or stage changed, the worker runs one Claude pass.
5. The pass records the next stage with `statectl.sh`.
6. The worker posts the new stage marker if needed and saves updated state.
