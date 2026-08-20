---
description: Write a handoff file for the current phase and stop
argument-hint: [plan-slug]
allowed-tools: Write, Read, Glob, Bash(git status:*), Bash(git diff:*), Bash(date:*)
---
Write `docs/superpowers/handoff/<today>-$ARGUMENTS-handoff.md` following
`docs/superpowers/TEMPLATE-handoff.md`, filling every section from this session's actual work
(`git status` / `git diff` for files touched). Use today's date in `YYYY-MM-DD` form.

Be honest about status and validation — an overstated handoff is worse than none. Then stop. Do not
start new work.
