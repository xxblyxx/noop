#if os(iOS)
import Foundation
import WidgetKit

extension WidgetSnapshot {
    /// Build a glance snapshot from the live app state and publish it to the shared App Group, then
    /// ask WidgetKit to refresh. Called when the app becomes active and after a Health sync.
    ///
    /// `async` because the Rest score (#446) lives in a computed metric series, not a `DailyMetric`
    /// column, so it needs an `exploreSeries` read. The sole caller already runs inside a `Task`, so it
    /// just gains an `await`.
    ///
    /// Every SCORE field is resolved by `Repository.glanceFields`, which gives each stat the selector its
    /// Today counterpart uses. This function used to resolve ONE recovery-gated anchor day
    /// (`Repository.widgetAnchor`) and read Charge, Effort, HRV and Resting HR off it, with the Rest series
    /// read nested inside `if let anchor`. That coupling meant a store with no scored `recovery` row blanked
    /// all five stat blocks at once — while Today, which resolves them through four independent selectors,
    /// still showed Effort, Rest, HRV and Resting HR. Only `bpm`/`batteryPct`/`bonded` survived, because
    /// they come off `model.live` and never touched the anchor. Charge alone stays anchor-gated; see
    /// `Repository.glanceFields` for the per-field rationale and the #911 rollover-drift history.
    @MainActor
    static func publish(from model: AppModel) async {
        let now = Date()
        // Read UNCONDITIONALLY. `sleep_performance` is an independent series — nesting this behind a
        // resolved recovery anchor (as this used to) blanked Rest for a reason that has nothing to do with
        // Rest. Same key/source as the Today Rest tile; `exploreSeries` merges imported + on-device.
        let restSeries = await model.repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
        let restByDay = Dictionary(restSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        let fields = Repository.glanceFields(
            days: model.repo.days,
            logicalKey: Repository.logicalDayKey(now),
            localKey: Repository.localDayKey(now),
            restByDay: restByDay,
            restTail: restSeries.last.map { (day: $0.day, value: $0.value) })
        // #313: honour the user's Effort scale at publish time. The widget extension cannot read the
        // app's plain `@AppStorage(UnitPrefs.effortScaleKey)` (it is not in the App Group), so we
        // pre-format the display string here and keep the 0–100 int for the ring fill (the fill
        // fraction is scale-independent: 38/100 == 8.0/21).
        let effortScale = UnitPrefs.resolveEffortScale(
            UserDefaults.standard.string(forKey: UnitPrefs.effortScaleKey) ?? ""
        )
        // Bind ONCE: both `effortDisplay` below and the `effort:` ring-fill argument derive from this, so
        // they can never describe different numbers.
        let strain = fields.effort
        let effortDisplay: String? = strain.map { stored in
            if effortScale == .whoop {
                return String(format: "%.1f", UnitFormatter.effortValue(stored, scale: .whoop))
            }
            return "\(Int(stored.rounded()))"
        }
        let snap = WidgetSnapshot(
            recovery: fields.charge.map { Int($0.rounded()) },
            bpm: model.bpm ?? model.live.heartRate,
            batteryPct: model.live.batteryPct.map { Int($0.rounded()) },
            bonded: model.live.bonded,
            updated: Date(),
            // Stored 0–100 axis for ring fill; display string carries the #313 scale.
            effort: strain.map { Int($0.rounded()) },
            rest: fields.rest.map { Int($0.rounded()) },
            hrv: fields.hrv.map { Int($0.rounded()) },
            restingHr: fields.restingHr,
            effortDisplay: effortDisplay,
            effortWhoop: effortScale == .whoop
        )
        saveAndReloadIfChanged(snap)
    }

    /// Publish fields that come directly from the live BLE state without re-reading the Rest metric
    /// series. HR is admitted once a minute and battery arrives about every eight minutes; routing those
    /// hooks through the full `publish` path used to query up to 4,000 days of Rest history every time even
    /// though none of the score fields could have changed. Reusing the last full snapshot keeps every score
    /// byte-identical and changes only the three live fields. A cold start with no snapshot falls back to a
    /// full build so this fast path can never publish an incomplete first glance. The first live update
    /// after a local-day rollover also takes the full path so the score anchor advances with Today.
    @MainActor
    static func publishLive(from model: AppModel) async {
        let now = Date()
        guard var snap = load(), !liveUpdateRequiresFullBuild(previous: snap, now: now) else {
            await publish(from: model)
            return
        }
        // The loaded value IS the current on-disk state (this runs on the main actor, so nothing else
        // rewrote it between here and the save); hand it to the dedup so the live path reads the App Group
        // ONCE per tick instead of loading it again inside saveAndReloadIfChanged.
        let previous = snap
        snap.bpm = model.bpm ?? model.live.heartRate
        snap.batteryPct = model.live.batteryPct.map { Int($0.rounded()) }
        snap.bonded = model.live.bonded
        snap.updated = now
        saveAndReloadIfChanged(snap, previous: previous)
    }

    /// Persist and ask WidgetKit for a new timeline only when a rendered field changed. The snapshot's
    /// timestamp is metadata only (no widget family displays it), so an otherwise-identical publish is a
    /// true no-op rather than an App-Group write plus an extension reload.
    /// `previous` lets the live fast path pass the snapshot it already loaded (it runs on the main actor,
    /// so that value is still current); the full publish path omits it and this loads once for the dedup.
    @MainActor
    private static func saveAndReloadIfChanged(_ snap: WidgetSnapshot, previous: WidgetSnapshot? = nil) {
        let previous = previous ?? load()
        if renderedContentChanged(from: previous, to: snap) {
            snap.save()
            WidgetCenter.shared.reloadAllTimelines()
        } else if liveUpdateRequiresFullBuild(previous: previous, now: snap.updated) {
            // The rollover's visible values can legitimately match yesterday's. Persist the fresh day
            // stamp once without spending a redundant WidgetKit reload, so later live ticks stay fast.
            snap.save()
        }
    }

    /// #114/#169: HR is the ONE high-frequency widget-publish trigger — `model.bpm` moves every few
    /// seconds during activity, unlike battery (~8 min) or connection flips (rare). Left ungated, the
    /// `model.$bpm` hook rewrote the shared snapshot + called `reloadAllTimelines()` on every tick (and,
    /// before the live-only fast path, also re-read the full Rest series). This caps HR-DRIVEN publishes
    /// to one per `interval`, mirroring Android's `PushGate` 60 s `HR_REFRESH_MS` cadence. Only the bpm
    /// hook consults it; the low-frequency score/battery/connection/scenePhase publish sites stay ungated,
    /// exactly as before. `@MainActor` (the hook already runs there), so the timestamp needs no locking.
    @MainActor
    enum HRPublishThrottle {
        static let interval: TimeInterval = 60
        private static var lastPublishedAt: Date = .distantPast
        /// True (and stamps `now`) when at least `interval` has elapsed since the last HR-driven publish;
        /// false to skip this HR change. The first call always admits (`.distantPast`).
        static func admit(now: Date = Date()) -> Bool {
            guard now.timeIntervalSince(lastPublishedAt) >= interval else { return false }
            lastPublishedAt = now
            return true
        }
    }
}
#endif
