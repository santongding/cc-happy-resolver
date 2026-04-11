---
name: cc-happy-resolver
description: Use this skill when handling a single `cc-happy-resolver` pass for one GitHub pull request.
---

Always read `PROGRESS.md` and `AGENTS.md` first to know what happened. 
Always update `PROGRESS.md` when about to exit, except that should remove it before moving the PR to `finished`.

Overall workflow:
1. Read the pass context from the prompt, including the PR number, stage, head SHA, the pending issue/review comment ID lists, the `statectl.sh` path, the comment-marking contract, and the push command.
2. Read `fetch.md` and `gh-helper-commands.md` to gather current-head PR state without duplicating prior work.
3. Read the stage file that matches the current stage (`plan.md`, `impl.md`, or `review.md`), then do the required investigation, implementation, or review work for exactly one pass.
4. Read `record.md` before updating `PROGRESS.md` or recording pass state that must survive into later passes.
5. Read `post.md` before posting comments, `finished.md` before moving to `finished`, `next-stage.md` before choosing the next stage, and `exit.md` before ending the current pass.
6. If any unexpected error happened, remember to post a comment to notify others and keep the current stage.

Stage handoff contract:
- Do not print `RESULT_STAGE=...` in terminal output.
- Record the next stage with the prompt-provided `statectl.sh` path.
- Call `set-next-stage` only once, at the very end of the pass, after all other state updates are complete.

Do not be surprised if the diff against the default branch only contains `PROGRESS.md`.
It is a placeholder change used to record intermediate state. Remove it before moving the PR to `finished`.
