Exit rules:
- End after exactly one pass. Ralph is responsible for the next iteration.
- Do not lie about the final result.
- Before exiting, make sure the chosen next stage matches the current PR state and completed work.
- Use the prompt-provided `statectl.sh` path to record the next stage:
`<statectl-path> set-next-stage plan`
`<statectl-path> set-next-stage impl`
`<statectl-path> set-next-stage review`
`<statectl-path> set-next-stage finished`
- `set-next-stage` must be the last statectl mutation of the pass so the next stage reflects the final branch and PR state.
- Do not emit `RESULT_STAGE=...` in terminal output.
