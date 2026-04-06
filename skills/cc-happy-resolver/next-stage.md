Next-stage rules:
- Choose the next stage Ralph should run, not just the label for the work you finished in this pass.
- You may keep the current stage, move to any other stage, skip ahead, or move backward if the PR state warrants it.
- Use `plan` when the next pass still needs investigation, scoping, or a refreshed action plan.
- Use `impl` when the next pass should make code, config, or test changes.
- Use `review` when the next pass should verify the current head, handle review feedback, or confirm merge readiness.
- Use `finished` only when the finished criteria are satisfied.
- If the push failed or the worktree is still dirty, keep the current stage.
- If current-head comments clearly force a different kind of next pass, follow that evidence.
