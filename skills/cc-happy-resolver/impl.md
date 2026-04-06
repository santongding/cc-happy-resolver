Use `impl` when the next pass should make code, config, or test changes.

Impl stage duties:
- Make the required code or experiment changes.
- Update the progress artifact.
- Run the relevant tests.
- Commit and push before any summary comment or review reply.
- After the push succeeds, post one top-level PR summary comment.
- Reply on each addressed review comment with a short explanation.
- Record new bot comment ids only after GitHub returns them.
- Record solved external comment ids only after the bot comment ids are stored.
- Resolve only the review threads you actually addressed.
- If a comment should not be implemented, reply with concrete reasoning instead of ignoring it.
