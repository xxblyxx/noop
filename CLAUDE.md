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

Note the tension with "the project stays anonymous" below: commits here are authored as
`xxblyxx <xxblyxx@gmail.com>`, and author name and email are permanent, world-readable metadata on
any pushed commit. Anonymity in this tree therefore means *the shipped app carries no identity* — it
has never meant the git history does. Do not treat a push as anonymous.

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

**Work lands as direct commits to `main`, and stops there.** There is no contributor flow and no
review queue here, so "open a PR" is not a step. Commit when the work is done; do **not** `git push`
unless the owner asks for it in that session — the commit is the deliverable, publishing is a
separate decision (see the visibility warning above). The `docs/` guides are written for upstream's
public workflow — read them for technical depth, not for process.

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
  manual `workflow_dispatch`), and it deliberately has no `push: main` leg. Since work here lands as
  direct commits and never as a PR, that trigger never fires. Net effect is the same as if it were
  off: touch anything under `Strand/`, `StrandiOS/`, `StrandiOSShared/`, `StrandiOSWidgets/` and **no
  CI validates it** — a compile error passes every green check. Build it yourself:
  `xcodegen generate && xcodebuild … build`.
- **Kotlin cannot be compiled on this machine** — no JDK, no Android SDK, and **CI is not used to
  cover that gap**. Write the twin anyway (the cross-platform rule below still stands), and say
  plainly in the commit: "Kotlin twin written but not compiled locally". Do **not** dispatch
  `android.yml` and do not push in order to trigger it — pushing is the owner's call, and the Android
  build is not wanted. Never imply the Kotlin was run. Accept the consequence honestly: the twin's
  correctness rests on review and on parity with the Swift it mirrors, nothing more.

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
