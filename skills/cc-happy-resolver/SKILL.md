---
name: cc-happy-resolver
description: Use this skill when handling a single `cc-happy-resolver` pass for one GitHub pull request.
---

Overall workflow:
1. Read the pass context from the prompt, including the PR number, stage, head SHA, recent solved external comment ids, recent bot comment ids, the one-line next-pass hint, the `statectl.sh` path, and the push command.
2. Read `fetch.md` and `gh-helper-commands.md` to gather current-head PR state without duplicating prior work.
3. Read the stage file that matches the current stage (`plan.md`, `impl.md`, or `review.md`), then do the required investigation, implementation, or review work for exactly one pass.
4. Read `record.md` before updating `PROGRESS.md` or recording pass state that must survive into later passes.
5. Read `post.md` before posting comments, `finished.md` before moving to `finished`, `next-stage.md` before choosing the next stage, and `exit.md` before ending the current pass.

Stage handoff contract:
- Do not print `RESULT_STAGE=...` in terminal output.
- Record the next stage with the prompt-provided `statectl.sh` path.
- Call `set-next-stage` only once, at the very end of the pass, after all other state updates are complete.
