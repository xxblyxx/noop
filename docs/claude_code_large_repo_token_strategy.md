# Claude Code — Large Repo Operating Doc

Rules and scaffolding for working a large repo without burning tokens. Hand this to Claude Code; it can also set up the files in the Setup section itself.

The strategy in one line: keep `CLAUDE.md` lean, push exploration into subagents (separate context windows), use plan mode to read before writing, and `/clear` between phases.

---

## How this was adopted in NOOP — read this before following the Setup section

This document is kept as the **rationale**, not as a checklist to re-run. It was adopted in full on
2026-08-19, with four deliberate deviations. Do not "fix" them back.

- **`@`-imports do not save tokens.** The claim below that a `@`-import keeps the map "without
  bloating the always-on file" is wrong: `@`-imports are inlined into context on every turn, exactly
  like `CLAUDE.md`. Real savings come only from content **linked as a plain path** and read on
  demand. NOOP uses exactly one `@`-import (`REPO_MAP.md`); every other doc is linked.
- **No `tasks/` or top-level `handoff/`.** `docs/superpowers/` already held `specs/` and `plans/` on a
  dated-slug convention, so `handoff/` was added there and `/phase` and `/handoff` point at it. A
  second parallel planning tree would rot.
- **No `docs/IMPLEMENTATION_LOG.md`.** Three ledgers already exist — descriptive commit messages on
  `main`, `CHANGELOG.md`, and `docs/PENDING_VALIDATION.md`. `/wrapup` updates `REPO_MAP.md` only.
- **Do not run `/init`.** `CLAUDE.md` here is deliberately built and was trimmed in place; `/init`
  would regenerate over it.

Two further adaptations worth knowing: rule 8 below ("no stubs, placeholders, mocks, or half-wired
code") is reworded in `CLAUDE.md` so it does not outlaw a sanctioned practice here — landing a
thin-evidence derivation as instrumentation or behind a default-off Experimental toggle. And because
subagents do **not** load `CLAUDE.md`, both agent definitions restate the private-fork rule; any new
one that can run `Bash` must too.

---

---

## Setup (create these once)

```txt
CLAUDE.md                      # always-loaded contract; imports the map
REPO_MAP.md                    # hand-maintained structure map
docs/IMPLEMENTATION_LOG.md     # running ledger of what changed and why
tasks/                         # one file per phase
handoff/                       # cross-session handoff files
validation/                    # test logs, screenshots
.claude/
  agents/
    code-reviewer.md
    qa-runner.md
  commands/
    phase.md                   # /phase <n>  — load a phase, lock the boundary
    handoff.md                 # /handoff <n> — write a handoff and stop
    wrapup.md                  # /wrapup     — update map + log
```

Generate `CLAUDE.md` with `/init`, then trim it hard. Manage subagents with `/agents`.

On first run, fill in the two templates marked **"Claude Code: fill this in"** — `REPO_MAP.md` and the phase-template validation commands — by inspecting the repo.

---

## CLAUDE.md

Keep it short — every line is loaded on every turn. It's a behavioral contract, not documentation. Delete anything that doesn't change how Claude acts. Use `@`-imports so the map loads without bloating the always-on file.

```md
# Project: <name>

<one-line description and stack>

See @REPO_MAP.md for structure.

## Token rules
1. Delegate codebase search to the Explore subagent. Don't read files into the
   main context speculatively.
2. Never scan the whole repo. Read the smallest viable file set before planning.
3. Use plan mode for anything touching more than one file.
4. Stay inside the active task boundary in `tasks/`. If a dependency forces you
   out, stop and say why before proceeding.
5. Run the qa-runner subagent for tests — don't dump verbose output into main context.
6. After changes: update `REPO_MAP.md` if structure changed, append to
   `docs/IMPLEMENTATION_LOG.md`.
7. When context fills, write a handoff file under `handoff/`, then stop.
8. No stubs, placeholders, mocks, or half-wired code.
9. Prefer targeted patches over full-file rewrites unless full replacement is safer.
10. If a task needs a broad refactor, stop and create a new phase file first.
```

Edit it anytime with `/memory`. Check what's currently loaded with `/context`.

---

## REPO_MAP.md

A small map beats repo-wide scanning. It's imported by `CLAUDE.md`, so it's always available without being told to read it. Keep it current via `/wrapup`.

**Claude Code: fill this in by inspecting the repo.** List only top-level directories with a one-line purpose each, and the handful of files that are entry points or get touched most often. Keep it under ~25 lines — this is a map, not an index. Delete the angle-bracket placeholders.

```md
# Repo Map

## Structure
- `/<dir>`   <one-line purpose>
- `/<dir>`   <one-line purpose>
- `/<dir>`   <one-line purpose>

## Key files
- `<path>`   <what it is / why it matters>
- `<path>`   <what it is / why it matters>
- `<path>`   <what it is / why it matters>
```

---

## Subagents

Each subagent has its own context window — verbose search and test output stays there, only a summary returns. This is the biggest token lever.

- **Explore** (built-in, read-only, Haiku) — use for all discovery and search. It *skips `CLAUDE.md`*, so restate any critical rule (e.g. "ignore `vendor/`") in the request.
- **Plan mode** (Shift+Tab) — read-only; research and propose before editing.
- Subagents **can't spawn subagents** — chain them from the main conversation.

`.claude/agents/code-reviewer.md`:

```md
---
name: code-reviewer
description: Reviews recent changes for quality, security, and task-boundary adherence. Use immediately after writing code.
tools: Read, Grep, Glob, Bash
model: inherit
memory: project
---
You are a senior code reviewer.

1. Run `git diff` to see recent changes.
2. Confirm changes stayed inside the active task boundary (`tasks/`).
3. Review for clarity, error handling, no stubs/placeholders, test coverage,
   and exposed secrets.

Report as Critical / Warnings / Suggestions with concrete fixes.
Save recurring issues and conventions to your agent memory.
```

`.claude/agents/qa-runner.md`:

```md
---
name: qa-runner
description: Runs tests and linters, reports only failures and a pass/fail summary. Use proactively after changes.
tools: Bash, Read, Grep, Glob
model: haiku
---
Run the project's test and lint commands. Report ONLY:
- pass/fail summary
- failing tests with their error messages
- where logs were saved (`validation/`)
Never paste full passing output.
```

Invoke explicitly with `@code-reviewer` / `@qa-runner`, or by name.

---

## Slash commands

`.claude/commands/phase.md`:

```md
---
description: Start a phase — load its task file and lock the boundary
argument-hint: [phase-number]
---
Read `tasks/phase-$ARGUMENTS*.md`. Confirm the goal, allowed areas, and
"do not modify" list back to me. Enter plan mode. Don't edit until I approve.
```

`.claude/commands/handoff.md`:

```md
---
description: Write a handoff file for the current phase and stop
argument-hint: [phase-number]
allowed-tools: Write, Bash(git status:*), Bash(git diff:*)
---
Write `handoff/phase-$ARGUMENTS-handoff.md` using the handoff template, then stop.
Don't start new work.
```

`.claude/commands/wrapup.md`:

```md
---
description: Update the repo map and implementation log after a phase
allowed-tools: Read, Edit, Bash(git diff:*)
---
From this session's changes: update `REPO_MAP.md` if structure changed, and
append a dated entry to `docs/IMPLEMENTATION_LOG.md` (Changed / Behavior /
Validation). Keep it concise.
```

(`.claude/commands/` works fine; Skills at `.claude/skills/<name>/SKILL.md` are the newer alternative if you want Claude to invoke a workflow on its own, not just via `/name`.)

---

## Phase file template — `tasks/phase-XX-title.md`

```md
# Phase XX — Title

## Goal
Exact goal of this phase.

## Files likely involved
- `path/to/file`

## Allowed areas
- `folder-or-file`

## Do not modify
- `folder-or-file`

## Acceptance criteria
- [ ] Requirement
- [ ] Existing tests pass
- [ ] New tests added if behavior changed
- [ ] No stubs or placeholders
- [ ] Validation artifact saved in `validation/`

## Validation commands
<!-- Claude Code: detect from package.json / Makefile / pyproject etc. and replace. -->
- `<test command>`
- `<lint command>`
- `<typecheck/build command, if any>`
```

---

## Handoff file template — `handoff/phase-XX-handoff.md`

```md
# Phase XX Handoff

## Goal
What this phase is accomplishing.

## Current status
Complete / partial / not started.

## Files touched
- `path/to/file`

## Important decisions
- Decision

## Remaining work
- [ ] Task

## Known risks
- Risk

## Validation status
Tests run / passing / logs at:

## Next recommended step
Smallest useful next action.
```

---

## Loop

1. `/phase <n>` — load the task, lock the boundary, plan mode.
2. Approve the plan; implement.
3. `@qa-runner`, then `@code-reviewer`.
4. `/wrapup`, then `/handoff <n>` if stopping.
5. `/clear` before the next phase — never carry one phase's context into the next.

Implementation log + subagent memory carry the decisions forward, so nothing gets rediscovered.
