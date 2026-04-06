---
name: cc-happy-resolver
description: Use this skill when the PR worker asks you to handle a single `cc-happy-resolver` pass for one GitHub pull request.
---

Overall workflow:
1. Read the pass context from the worker prompt, including the context JSON path, recent solved comment ids, recent bot comment ids, hint, statectl path, and push command.
2. Read `fetch.md` and `gh-helper-commands.md` to gather current-head PR state without duplicating prior work.
3. Read the stage file that matches the current stage, then do the required investigation, implementation, or review work for exactly one pass.
4. Read `post.md` before posting comments or recording bot state, `finished.md` before moving to `finished`, `next-stage.md` before choosing the next stage, and `exit.md` before ending the pass.

Read `fetch.md` and `gh-helper-commands.md` at the start of every pass.
Read the stage file that matches the current stage before taking action: `plan.md`, `impl.md`, or `review.md`.
Read `post.md` before posting any top-level summary comment or review reply.
Read `finished.md` before changing the next stage to `finished`.
Read `next-stage.md` before deciding the `RESULT_STAGE`.
Read `exit.md` before exiting this pass.
