# CLAUDE.md — working on NOOP

## ⛔ PERSONAL USE ONLY — NEVER CONTACT UPSTREAM. HIGHEST PRIORITY RULE.

This tree is a **personal-use fork**. It exists to run on the owner's own hardware, not to feed work
back to `ryanbr/noop`. There is **no intention to open a PR upstream, ever** — the owner is not
familiar with that process and does not want to risk disrupting the parent project. So "this would be
a good upstream contribution" is never a reason to do anything.

**Nothing from this tree goes upstream.** No exceptions, no "just this once", no asking whether an
exception applies. Forbidden however helpful it looks: pull requests to `ryanbr/noop` or any other
remote; issue comments, replies, reactions or new issues upstream — including posting a measurement,
a correction, or a capture; any `gh` / `git push` / `curl` / API call that **writes** to a repo other
than `xxblyxx/noop` (reading upstream is fine); sending findings off this machine by gist, forum,
Discord or email.

⚠️ **"Personal use" is not the same as "private".** `xxblyxx/noop` is a **public** repo on GitHub
(`private: false`) and a fork of `ryanbr/noop`. Anything pushed is world-readable, and because forks
share an object store, a pushed commit's SHA is reachable through the parent repo's URL space even
though it lands on no upstream branch and notifies nobody. Local commits leak nothing; **pushing is
what publishes.** See "Commits" below — pushing is the owner's call, never an assumed step.

Note the tension with "the project stays anonymous" below. That rule is **upstream's**, and it exists
because upstream DISTRIBUTES: notarizing on macOS or publishing to Play needs a paid identity tied to
a real person, which upstream will not attach to a clean-room protocol reimplementation — hence the
un-notarized `.app`, the unsigned APK, and the self-signed `.ipa`.

**It largely does not apply to this fork, which distributes nothing.** Builds here are signed with
the owner's own paid team for one device, and commits are authored as `xxblyxx <xxblyxx@gmail.com>`.
So do not claim anonymity for anything produced in this tree: neither the local build nor the git
history is anonymous, and author metadata is permanent and world-readable on any pushed commit. The
rule still binds where it bites — never publish a build or artifact from here under any identity.

When a task seems to call for it — an issue's premise is wrong, a doc says "post this on #NNNN" —
record the finding **locally** and stop. Do not offer posting as an option and do not ask permission;
the answer is already no. Issue numbers here are local references, never destinations.

**Subagents do not load this file.** Restate this rule in every subagent prompt that can run `Bash`.

## What this is

NOOP is a **fully offline, on-device** companion app for WHOOP 4.0 and 5.0/MG straps (Oura and Polar
are experimental, gated). No server, no account, no cloud sync, no telemetry, and the project stays
anonymous. Clean-room interoperability only. A change is out of scope if it sends data off-device,
phones home, or adds firmware / decompiled code / WHOOP assets — see
[`docs/SCOPE.md`](docs/SCOPE.md).

**Work lands as commits on a working branch, merged into `main` locally, and stops there.** There
is no contributor flow and no review queue here, so "open a PR" is not a step — the merge happens on
this machine (see "git branching" below). Commit when the work is done; do **not** `git push` unless
the owner asks for it in that session — the commit on `main` is the deliverable, publishing is a
separate decision (see the visibility warning above). The `docs/` guides are written for upstream's
public workflow — read them for technical depth, not for process.

**NOOP's own data is the first-party source.** Whatever the strap sends over BLE and whatever NOOP
decodes, stores and computes on-device is the source of truth for every surface. Prefer it whenever
it can answer the question at all — including when it is rougher, sparser, or less flattering than a
number some other app already has. The point of this project is reading YOUR strap yourself; a
surface that quietly shows another vendor's figure makes the number untraceable and the app a viewer
for someone else's cloud.

**Apple Health / HealthKit and third-party imports are secondary — ASK FIRST.** Do not wire a screen,
tile or metric to Apple Health data on your own initiative, even when the Health value is already
imported, better calibrated, and sitting right there. Say what NOOP's own data can and cannot do,
name the Health value as an option, and let the owner choose. (Some surfaces already read
`apple-health` — steps, weight, active calories. Those are existing decisions, not a precedent to
extend.) Whichever source wins, the surface must say which one it is.

**Hardware on hand: a WHOOP 5.0.** That is what any "can you check this" runs against, and the family
to assume when a question doesn't name one. Anything 4.0-specific cannot be verified here — say so
rather than claiming it was tested.

See @REPO_MAP.md for structure.

## Token rules

1. Delegate codebase search to the Explore subagent; don't read files into the main context
   speculatively. Explore skips this file, so restate any constraint it needs — including the
   never-scan list in `REPO_MAP.md`.
2. Never scan the whole repo. Read the smallest viable file set before planning.
3. Use plan mode for anything touching more than one file.
4. Stay inside the active plan's boundary. Durable plans live in `docs/superpowers/plans/`; a plan
   written by the harness's plan mode lands in `~/.claude/plans/` instead and is scratch — copy it
   into `docs/superpowers/plans/` if it is worth keeping. If a dependency forces you outside the
   boundary, stop and say why before proceeding.
5. Run tests via the qa-runner subagent — don't dump verbose output into the main context.
6. After changes, `/wrapup`: update `REPO_MAP.md` if the structure changed.
7. When context fills, write `docs/superpowers/handoff/…`, then stop.
8. Ship complete work — no stubs, placeholders, or half-wired code. Instrumentation and a
   default-off Experimental toggle are complete work, not stubs; see the physiological-signal rule.
9. Prefer targeted patches over full-file rewrites unless full replacement is safer.
10. A broad refactor needs a new plan file first — stop and write it.

## Usage guard — know the budget *before* starting (`Tools/usage-guard.py`)

Running out of plan usage halfway through a task is expensive in a specific way: the reasoning lives
in a context that is about to become unusable, and the work has to be re-derived after the reset. The
`usage-monitor` skill answers "check usage" — but only when asked, which is *after* committing to the
work. So the number arrives unprompted instead:

- **`SessionStart`** (`--mode session`) reports both windows every session. **Include the two numbers
  in your first reply**, in one line, then get on with what the session is for.
- **`UserPromptSubmit`** (`--mode prompt`) is silent until either window hits **80%**, then warns at
  most once per 30 min. That silence is what keeps the warning worth reading.
- At ≥80%: **say so before starting substantial work** and offer (a) proceed — fine for a small,
  self-contained task, (b) a cheaper model for the rest of the window, (c) the `usage-monitor` skill,
  which writes a resume doc to this project's memory dir and schedules an auto-resume agent for the
  reset time. `--report` prints numbers and nothing else; only the skill writes the resume doc.
- Numbers come from Anthropic's `/api/oauth/usage` (same source as `/usage`), cached in
  `~/.claude/vscode-claude-status-cache.json` and refreshed at most every 15 min. That cache is
  shared with Claude Code on purpose; the 30-minute throttle file (`~/.claude/noop-usage-guard.json`)
  is per-project so a sibling fork's warning cannot silence this one. Never use `ccusage` — it
  estimates against a guessed limit and won't match `/usage`.
- Failures are reported, not swallowed (same rule as `pending-validation.py`): a guard that goes
  quiet still gets trusted. Run `python3 Tools/usage-guard.py --report` to check it by hand.
- Hooks and `.claude/settings.json` are read once at process start. `--resume` / `--continue` keeps
  the original registry, so a change to either needs a genuinely new session to take effect.

## Read before you edit

These rules are **not** in this file. Load the doc before touching the area.

| Touching | Read first |
|---|---|
| a decoder, an analytics formula, a migration, a stored value | [`docs/CROSS_PLATFORM.md`](docs/CROSS_PLATFORM.md) — the Kotlin twin ships in the **same commit** |
| `Strand/BLE`, `Strand/Collect`, `com.noop.ble` | [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md) §BLE safety contract. Never add destructive writes. BLE cannot be CI-tested — validate on a real strap and say what you tested |
| a schema change | [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md) §Add a database column or table (schema reference: [`docs/DATA_MODEL.md`](docs/DATA_MODEL.md)) |
| any UI | design tokens only — `StrandPalette` / `StrandFont` on Apple, `Palette` / `Metrics` on Android. No hardcoded colors, fonts, or spacing |
| deriving a physiological signal from raw sensor data | [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md) §Derive a physiological signal — one matching night is **not** validation |
| build, CI, or toolchain | [`docs/BUILD.md`](docs/BUILD.md) |
| shipping a claim only future data can confirm | [`docs/PENDING_VALIDATION.md`](docs/PENDING_VALIDATION.md) — add an entry before calling the work done |

## The two traps

- **`swift-packages.yml` does not compile the app targets, and nothing else does either.**
  `app-build.yml` is not disabled — it is alive but triggers only on `pull_request` to `main` (plus
  manual `workflow_dispatch`), and it deliberately has no `push: main` leg. Since work here is merged
  locally and never arrives as a PR, that trigger never fires. Net effect is the same as if it were
  off: touch anything under `Strand/`, `StrandiOS/`, `StrandiOSShared/`, `StrandiOSWidgets/` and **no
  CI validates it** — a compile error passes every green check. Build it yourself:
  `xcodegen generate && xcodebuild … build`.
- **Kotlin cannot be compiled on this machine** — no JDK, no Android SDK, and **CI is not used to
  cover that gap**. Write the twin anyway (the cross-platform rule below still stands), and say
  plainly in the commit: "Kotlin twin written but not compiled locally". Do **not** dispatch
  `android.yml` and do not push in order to trigger it — pushing is the owner's call, and the Android
  build is not wanted. Never imply the Kotlin was run. Accept the consequence honestly: the twin's
  correctness rests on review and on parity with the Swift it mirrors, nothing more.

## git branching

Maintain the integrity of `main` — always create a branch to work from. Before implementing any code
change, if you are on `main`, ask the owner whether to create a branch and recommend a branch name.
Do not start editing until that's settled.

- This applies to code changes, not to docs-only tweaks the owner asked for directly. A change that
  touches both is a code change.
- Branch names follow the convention `feat/…`, `fix/…`, `docs/…`.
- When the work is verified, `git merge --ff-only` into `main` and delete the branch. `--ff-only` is
  deliberate: it fails loudly rather than quietly writing a merge commit if `main` moved.
- Branches never leave this machine. No push, no PR — see the never-contact-upstream rule at the top
  of this file.

## Commits

One concern per commit — a protocol change, a migration, and a UI change stay separate. **Show your
verification:** BLE → what you tested on hardware; analytics → the method and a test; app-target
Swift → that you compiled the app, because CI won't. Never commit generated artifacts
(`Strand.xcodeproj/`, `build/`, `.build/`, `*.app`). Ordinary commits do not need a version bump;
when you do bump one, bump `MARKETING_VERSION` in `project.yml` and `versionName` in
`android/app/build.gradle.kts` **together**, so the two platforms never disagree. Docs and comments
are neutral, third-person, project-voice; keep upstream credits intact.

When in doubt, prefer the smallest change that's correct and covered by a test that runs without a
strap.
