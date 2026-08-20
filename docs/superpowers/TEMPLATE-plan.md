# Phase — <title>

## Goal

The exact goal of this phase, in one or two sentences. What is true when it's done.

## Files likely involved

- `path/to/file`
- Its cross-platform twin, if the change touches a decoder, an analytics formula, a migration, or a
  stored value — parity is not optional (`docs/CROSS_PLATFORM.md`).

## Allowed areas

- `folder-or-file`

## Do not modify

- `folder-or-file`

## Acceptance criteria

- [ ] Requirement
- [ ] Existing tests pass
- [ ] New tests added if behavior changed
- [ ] Kotlin twin written, if a decoder / formula / migration / stored value changed
- [ ] No stubs or placeholders
- [ ] `docs/PENDING_VALIDATION.md` entry added if correctness rests on data that doesn't exist yet
- [ ] Validation artifact saved in `validation/` (gitignored)

## Validation commands

Pick the ones that actually cover this change; delete the rest.

```bash
# Swift packages — the only thing default CI covers
cd Packages/<pkg> && swift build && swift test

# macOS app target — required if Strand/ or StrandiOS*/ changed; NO default CI compiles these
xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme Strand \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build

# Repo lint gates
python3 Tools/doc_comment_lint.py
python3 Tools/i18n_audit.py --ci origin/main
```

**Cannot be verified on this machine:** anything Kotlin (no JDK/SDK — dispatch `android.yml`) and any
BLE behavior (needs a real strap; the maintainer's is a WHOOP 5.0).
