# CLAUDE.md — working on NOOP

## ⛔ THIS FORK IS PRIVATE — NEVER CONTACT UPSTREAM. HIGHEST PRIORITY RULE.

**Nothing from this tree ever leaves it.** No exceptions, no "just this once", no asking whether an
exception applies. Forbidden however helpful it looks: pull requests to `ryanbr/noop` or any other
remote; issue comments, replies, reactions or new issues upstream — including posting a measurement,
a correction, or a capture; any `gh` / `git push` / `curl` / API call that **writes** to a repo other
than `xxblyxx/noop` (reading upstream is fine); sending findings off this machine by gist, forum,
Discord or email.

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

**Work lands as direct commits to `main`.** There is no contributor flow and no review queue here, so
"open a PR" is not a step. The `docs/` guides are written for upstream's public workflow — read them
for technical depth, not for process.

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
4. Stay inside the active plan's boundary (`docs/superpowers/plans/`). If a dependency forces you
   out, stop and say why before proceeding.
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

- **`swift-packages.yml` does not compile the app targets**, and `app-build.yml` is disabled. Touch
  anything under `Strand/`, `StrandiOS/`, `StrandiOSShared/`, `StrandiOSWidgets/` and **no default CI
  validates it** — a compile error passes every green check. Build it yourself:
  `xcodegen generate && xcodebuild … build`.
- **Kotlin cannot be compiled on this machine** — no JDK, no Android SDK. Write the twin anyway, say
  so plainly in the commit ("Kotlin twin written but not compiled locally"), and dispatch
  `android.yml` to actually verify it. Never imply the Kotlin was run.

## Commits

One concern per commit — a protocol change, a migration, and a UI change stay separate. **Show your
verification:** BLE → what you tested on hardware; analytics → the method and a test; app-target
Swift → that you compiled the app, because CI won't. Never commit generated artifacts
(`Strand.xcodeproj/`, `build/`, `.build/`, `*.app`). Bump `MARKETING_VERSION` in `project.yml` and
`versionName` in `android/app/build.gradle.kts` together. Docs and comments are neutral,
third-person, project-voice; keep upstream credits intact.

When in doubt, prefer the smallest change that's correct and covered by a test that runs without a
strap.
