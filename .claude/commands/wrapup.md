---
description: Update the repo map after a phase
allowed-tools: Read, Edit, Glob, Bash(git diff:*), Bash(git status:*)
---
From this session's changes (`git diff`), update `REPO_MAP.md` **only if the structure actually
changed** — a new top-level directory, a new package, a moved or renamed entry point. Keep it under
~35 lines; it is a map, not an index.

If nothing structural changed, say so and change nothing.

This repo has no implementation log — the commit messages, `CHANGELOG.md`, and
`docs/PENDING_VALIDATION.md` are the ledgers. Do not create one.
