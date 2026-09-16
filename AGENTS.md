# Repository workflow

- Use GitHub Flow: one scoped issue, one work branch, one pull request.
- Inspect the working tree first and preserve unrelated user changes.
- Start branches from current main with names such as feat/12-description, fix/12-description, or chore/12-description.
- Never commit or push implementation changes directly to main.
- Include Closes #NUMBER in the PR and describe changes and actual verification results.
- Merge only with squash after required checks pass and conversations are resolved. Do not bypass repository rules. Merge or publish only when the user has authorized it.
- Do not rewrite published release tags or replace published release assets.
- Keep signing keys, local maintainer notes, and build outputs out of Git. PR checks must not use signing secrets.
- Use GKSDUD_SIGN_MODE=ad-hoc bash build.sh for development verification. Do not replace the installed app unless requested.
- Do not use em dashes (U+2014) or middle dots (U+00B7) in newly authored prose.
