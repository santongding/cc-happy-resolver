---
name: cc-happy-resolver
description: Use this skill when handling a single `cc-happy-resolver` pass for one GitHub pull request.
---

Overall workflow:
1. Read the pass context from the prompt, including the PR number, stage, head SHA, context JSON path, recent solved external comment ids, recent bot comment ids, hint, statectl path, and push command.
2. Read `fetch.md` and `gh-helper-commands.md` to gather current-head PR state without duplicating prior work.
3. Read the stage file that matches the current stage (`plan.md`, `impl.md`, or `review.md`), then do the required investigation, implementation, or review work for exactly one pass.
4. Read `record.md` before updating `PROGRESS.md` or recording pass state that must survive into later passes.
5. Read `post.md` before posting comments, `finished.md` before moving to `finished`, `next-stage.md` before choosing the next stage, and `exit.md` before ending the current pass.
