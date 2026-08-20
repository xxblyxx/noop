# Repo Map

Structure only — the lean map loaded with `CLAUDE.md`. Depth lives in
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) (pipeline) and
[`docs/CROSS_PLATFORM.md`](docs/CROSS_PLATFORM.md) (what's shared vs mirrored).

## Structure
- `Packages/` — 8 SwiftPM libs, platform-neutral, the only code CI tests by default:
  `WhoopProtocol` `OuraProtocol` `PolarProtocol` (pure decode, no CoreBluetooth) ·
  `WhoopStore` (GRDB/SQLite) · `StrandAnalytics` (HRV/recovery/strain/sleep math) ·
  `StrandImport` (WHOOP CSV + Apple Health) · `StrandDesign` (SwiftUI tokens) · `NoopLocalAccess`
- `Strand/` — macOS app, the reference implementation; shared with iOS. `BLE/ Collect/ Data/ Screens/ App/ System/`
- `StrandiOS/` `StrandiOSShared/` `StrandiOSWidgets/` — iOS-only app layer (scheme `NOOPiOS`), widgets, Live Activity
- `NOOPWatch/` `NOOPWatchComplications/` — watchOS app and complications
- `StrandTests/` — app-target tests; run only via `xcodebuild … test` on macOS
- `android/` — Kotlin/Compose parity twin (`com.noop.*`), Room, flavors `Full`/`Demo`
- `Tools/` — Python/shell dev + release tooling, and the `Backfill` / `SleepBench` / `SleepPSG` CLIs
- `docs/` — architecture, protocol, build; `superpowers/{specs,plans,handoff}` for design and phase files
- `Config/` `marketing/` `.github/` — xcconfigs, demo assets, 8 CI workflows

## Key files
- `project.yml` — XcodeGen source of truth. `Strand.xcodeproj/` is generated; re-run `xcodegen generate`
- `Strand/App/StrandApp.swift` · `StrandiOS/App/StrandiOSApp.swift` · `NOOPWatch/NOOPWatchApp.swift` — the three `@main`
- `Strand/Data/IntelligenceEngine.swift` — hottest file in the repo; Kotlin twin at `android/…/analytics/IntelligenceEngine.kt`
- `Strand/Data/Repository.swift` · `Strand/App/AppModel.swift` · `Strand/BLE/BLEManager.swift`
- Android twins: `…/data/WhoopRepository.kt` · `…/ui/AppViewModel.kt` · `…/ble/WhoopBleClient.kt` · `…/ui/MainActivity.kt`

## Fast loops
```bash
cd Packages/<pkg> && swift build && swift test        # fastest; no Xcode, no strap
xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme Strand \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
python3 Tools/doc_comment_lint.py && python3 Tools/i18n_audit.py --ci origin/main
```

**Never scan:** `.build/` · `build-device/` · `tmp/` · `Strand.xcodeproj/` — untracked build output, tens of thousands of files.
