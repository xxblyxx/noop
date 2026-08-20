# Port OpenCircuit's usage guard and branch-first rule into NOOP

## Context

Two sibling personal-use projects — `/Users/brian/dev/OpenCircuit` and `/Users/brian/dev/blyDex` —
carry Claude rules that NOOP lacks:

1. **Branch before a code change.** Both keep the default branch clean by branching first;
   OpenCircuit's version is the polished one (names the branch, carves out docs-only edits, sets the
   `feat/ fix/ docs/` convention). NOOP has no such rule and every session commits straight onto
   `main`.
2. **Know the plan budget before starting.** OpenCircuit runs `scripts/usage-guard.py` from two
   hooks so the 5h/weekly utilization arrives *unprompted, before the first instruction*, and warns
   at ≥80%. The failure it guards against is starting a long task at 78% and running dry halfway
   through, with the reasoning stranded in a context that is about to become unusable. blyDex has
   only prose plus a per-phase gate. NOOP has neither — just the user-level `usage-monitor` skill,
   which only answers when asked, i.e. after the work has already been committed to.

Outcome: NOOP gets OpenCircuit's guard (script + both hooks + doc), blyDex's per-phase gate wired
into `/phase`, and a branch-first rule retargeted to `main` — with CLAUDE.md's contradicting
"direct commits to `main`" sentence rewritten rather than left to fight the new rule.

**Decisions already taken** (asked and answered):
- Branch lifecycle: branch → work → **fast-forward merge into `main` and delete the branch** once
  verified. The commit on `main` is still the deliverable. Still never `git push` unless asked.
- Usage guard: **full port** — `SessionStart` + `UserPromptSubmit`.
- **Yes** to the per-phase usage gate in `/phase`.
- Branch rule is **prose only**, like both siblings. No enforcement hook.

## Do this work on a branch

First application of the new rule: `git checkout -b feat/claude-usage-guard`, two commits there,
`git merge --ff-only` into `main` and delete the branch after verification. No push.

---

## 1. `Tools/usage-guard.py` (new, mode 755)

Port `/Users/brian/dev/OpenCircuit/scripts/usage-guard.py` (223 lines, stdlib only) essentially
verbatim — it is already written to the same "fail loud, not silent" contract as NOOP's existing
`Tools/pending-validation.py`. Three changes on the way in:

- `STATE = Path.home() / ".claude" / "noop-usage-guard.json"` — **must** be renamed. OpenCircuit
  hardcodes `opencircuit-usage-guard.json`; sharing it would let a warning fired in one project
  silence the other for 30 minutes.
- `CACHE = Path.home() / ".claude" / "vscode-claude-status-cache.json"` — **do not** rename. Sharing
  this one is deliberate: Claude Code's own `/usage` writes it, so a manual `/usage` counts as a
  refresh and vice versa. The API speaks percent (0–100), the cache stores fractions (0–1); the
  `/100.0` conversion is load-bearing.
- Docstring usage examples repointed from `scripts/usage-guard.py` to `Tools/usage-guard.py`.

Everything else stays: `THRESHOLD_PCT = 80.0`, 15-min refresh floor, 30-min staleness and re-warn
windows, 8s network / 5s keychain timeouts, always `exit 0`, output as one JSON line
`{"hookSpecificOutput": {"hookEventName": ..., "additionalContext": ...}}`. Credentials come from
`~/.claude/.credentials.json` (Linux) or the macOS keychain
(`security find-generic-password -s "Claude Code-credentials" -w`). Never `ccusage` — its numbers
are estimates against a guessed limit and will not match `/usage`.

## 2. `Tools/test_usage_guard.py` (new)

NOOP's `Tools/` has a real test convention (`test_pending_validation.py`, `test_i18n_audit.py`) and
`.github/workflows/tools-python.yml` runs `python3 -m unittest discover -p "test_*.py"` — so this
test *will* run in CI, on ubuntu, with no keychain. Load the hyphenated module the same way
`test_pending_validation.py` does (`importlib.util.spec_from_file_location`).

**No test may touch the network or the keychain, on CI or on this Mac.** Two mechanisms, and both
are needed: point `ug.CACHE` at a fresh temp cache so `refresh()` short-circuits, *and* — for the
one test that deliberately has no cache — patch `ug._access_token` to raise. Relying on the cache
patch alone is what would go wrong: cache-absent means `refresh()` does not short-circuit, and it
only stays offline on ubuntu CI (where `_access_token()` raises "not on macOS"). On this machine the
keychain read succeeds and the test would make a real call to `api.anthropic.com`.

Cover:

- `refresh()` returns cached data with no network call when the cache is younger than
  `REFRESH_MAX_AGE`; and returns `(None, None, err)` when the cache is absent **and
  `ug._access_token` is patched to raise**.
- `_warning_block()` names the *5h window* when only `pct5h ≥ 80`, the *weekly window* when only
  `pct7d ≥ 80`, and includes the matching reset time.
- `_should_warn_again()` (with `ug.STATE` in a tmpdir): `True` first call, `False` immediately
  after, `True` again once `lastWarnAt` is backdated past `REWARN_AFTER`.
- `_local()` returns `"?"` on garbage rather than raising.
- `main(--mode prompt)` prints nothing under threshold; with a patched 85% cache it prints valid
  JSON with `hookEventName == "UserPromptSubmit"`, and the throttle file it writes is
  `noop-usage-guard.json` — **not** `opencircuit-usage-guard.json`. This test is where the ≥80% path
  is proven; there is no safe by-hand version of it (see Verification).
- `main(--mode session)` prints exactly one line of valid JSON with
  `hookEventName == "SessionStart"`, both percentages present.

## 3. `.claude/settings.json` — two structural edits

Current file has one `SessionStart` entry (matcher `startup|clear` → `Tools/pending-validation.py`).

- **Append a second object** to the `SessionStart` array with matcher `startup|clear|resume` calling
  `python3 "$CLAUDE_PROJECT_DIR/Tools/usage-guard.py" --mode session 2>/dev/null || true`,
  `timeout: 20`. Keep it a separate object — the extra `resume` is deliberate (the banner should
  reappear after `--resume`) and pending-validation deliberately does not want it.
- **Add a new top-level `UserPromptSubmit` key** (NOOP has none) with no matcher, calling the same
  script with `--mode prompt`, `timeout: 20`.

Both follow the existing `2>/dev/null || true` idiom so a crash can never block a session.

## 4. `CLAUDE.md` — four edits

1. **Rewrite the "Work lands as direct commits" sentence** (~line 48). New wording: work lands as
   commits on a working branch that is merged into `main` locally and stops there; there is still no
   contributor flow, no review queue, "open a PR" is still not a step, and `git push` still only
   happens when the owner asks in that session.
2. **New `## git branching` section**, next to `## Commits`. OpenCircuit's rule retargeted to `main`
   with the merge-when-done lifecycle:
   - Always branch to work from; if on `main` and about to make a code change, ask which branch and
     recommend a name. Do not start editing until that is settled.
   - Applies to code changes, not to docs-only tweaks the owner asked for directly. **A change that
     touches both counts as a code change** — this task itself is one.
   - Names: `feat/…`, `fix/…`, `docs/…`.
   - When the work is verified, `git merge --ff-only` into `main` and delete the branch. Spell
     `--ff-only` out, so a later session cannot silently produce a merge commit if `main` moved.
   - Branches never leave this machine — no push, no PR (points back at the never-contact-upstream
     rule at the top of the file).
3. **New `## Usage guard` section**, adapted from OpenCircuit's, repointed at `Tools/usage-guard.py`:
   what each hook does, the ≥80% (a)/(b)/(c) offer, where the numbers come from, the never-`ccusage`
   warning, and `python3 Tools/usage-guard.py --report` to check it by hand.
4. **"The two traps" fix-up** (~line 112): "Since work here lands as direct commits and never as a
   PR" → wording that says the work is merged locally and never arrives as a PR, so `app-build.yml`
   still never fires. The trap itself is unchanged and must stay — branching does not create PRs.

## 5. `.claude/commands/phase.md` — per-phase usage gate

Currently 9 lines: read the plan under `docs/superpowers/plans/`, confirm goal / allowed areas /
do-not-modify, enter plan mode. Add blyDex's gate, with the two tools kept distinct because they do
different jobs: run `python3 Tools/usage-guard.py --report` at phase start and before moving to the
next phase — that is the cheap number — and **at ≥80% stop and invoke the `usage-monitor` skill**,
which is the only thing that writes the resume doc and schedules the auto-resume agent. `--report`
prints numbers and nothing else.

## 6. Keep the plan

Copy this file to `docs/superpowers/plans/2026-08-20-claude-usage-guard-and-branch-rule.md` —
`~/.claude/plans/` is scratch per CLAUDE.md token rule 4, and a process change is worth keeping.

---

## Commits (one concern each, both on the branch)

- **A — usage guard:** `Tools/usage-guard.py`, `Tools/test_usage_guard.py`, the two
  `.claude/settings.json` hooks, CLAUDE.md `## Usage guard`, the `/phase` gate, and the plan copy.
  Verification line: the unittest run and `--report` output.
- **B — branch rule:** the three CLAUDE.md branching edits (rewritten sentence, `## git branching`,
  two-traps fix-up). Docs only.

No Swift and no Kotlin is touched, so the cross-platform twin rule does not apply and no `xcodebuild`
is needed — say so in the commit rather than leaving it implied.

## Verification

```bash
python3 -m json.tool .claude/settings.json >/dev/null && echo "settings.json parses"
python3 Tools/usage-guard.py --report                 # both windows, human-readable
python3 Tools/usage-guard.py --mode session | python3 -m json.tool   # one valid JSON line
python3 Tools/usage-guard.py --mode prompt            # silent under 80% (no output, exit 0)
cd Tools && python3 -m unittest discover -p "test_*.py" -v   # via the qa-runner subagent
python3 Tools/doc_comment_lint.py
```

Then, offline-safety and end-to-end:

- Re-run `--report` twice within 15 minutes and confirm the second run does not re-hit the API
  (cache `updatedAt` unchanged).
- The ≥80% path is verified **only** by `test_usage_guard.py` with a patched `ug.CACHE`. Do not
  fake it by hand: `~/.claude/vscode-claude-status-cache.json` is the live file that Claude Code's
  `/usage` and `~/.claude/statusline.py` read, and writing a synthetic 85% into it would corrupt
  what the user sees.
- **Hooks and `settings.json` are read once at process start.** `--resume`/`--continue` keeps the old
  registry, so confirming the banner requires a genuinely new session — start one and check the
  usage line appears before the first reply.
- `/wrapup`: a new file in `Tools/` is probably not a structure change, but check whether
  `REPO_MAP.md`'s `Tools/` line needs the guard called out.
