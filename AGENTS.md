# Repository workflow

- Use GitHub Flow: one scoped work branch and one pull request. Do not create issues unless the user explicitly asks.
- Inspect the working tree first and preserve unrelated user changes.
- Start branches from current main with names such as feat/description, fix/description, or chore/description. Issue numbers are not required.
- Never commit or push implementation changes directly to main.
- Prefix PR titles with [FEAT], [FIX], [CHORE], [DOCS], [REFACTOR], [TEST], [CI], [PERF], [BUILD], or [REVERT]. Describe changes and actual verification results. No issue linkage is required.
- Merge only with squash after required checks pass and conversations are resolved. Do not bypass repository rules. Merge or publish only when the user has authorized it.
- Do not rewrite published release tags or replace published release assets.
- Keep signing keys, local maintainer notes, and build outputs out of Git. PR checks must not use signing secrets.
- Use GKSDUD_SIGN_MODE=ad-hoc bash build.sh for development verification. Do not replace the installed app unless requested.
