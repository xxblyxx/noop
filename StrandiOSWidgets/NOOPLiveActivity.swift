import WidgetKit
import SwiftUI
import ActivityKit
import StrandDesign

/// Live Activity for an active live-HR session — shown on the Lock Screen and in the Dynamic Island.
/// Two rendering modes share ONE activity, switched purely on `context.state.workoutStart`: the
/// ambient "Live HR" presentation when no workout is recording (byte-identical to what shipped before
/// this file gained a second mode — do not regress it), and the workout layout ("Zone Glass") while
/// `AppModel.activeWorkout` is non-nil. See `NOOPActivityAttributes.ContentState`'s doc comment for why
/// this is one activity with an optional payload rather than a second `ActivityAttributes` type.
struct NOOPLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NOOPActivityAttributes.self) { context in
            Group {
                if let start = context.state.workoutStart {
                    WorkoutLockScreenView(context: context, start: start)
                } else {
                    AmbientLockScreenView(context: context)
                }
            }
            .padding()
            .activityBackgroundTint(StrandPalette.surfaceBase)
            .activitySystemActionForegroundColor(StrandPalette.textPrimary)
        } dynamicIsland: { context in
            // ONE DynamicIsland construction — each region branches internally on workoutStart, rather
            // than building two separate `DynamicIsland{...}` values, because the outer closure isn't
            // `@ViewBuilder`-attributed the way each region's own content closure is: two differently-
            // shaped branches at the top level wouldn't type-check as a single expression.
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if context.state.workoutStart != nil {
                        HStack(spacing: 6) {
                            Image(systemName: WorkoutTypeIconography.systemSymbolName(for: context.state.sport ?? ""))
                                .foregroundStyle(StrandPalette.textSecondary)
                            zoneChip(zone: context.state.zone ?? 0, withName: true)
                        }
                    } else {
                        Label("\(context.state.bpm.map(String.init) ?? "–")", systemImage: "heart.fill")
                            .foregroundStyle(StrandPalette.statusCritical)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.workoutStart != nil {
                        heartReadout(bpm: context.state.bpm, zone: context.state.zone ?? 0, isStale: context.isStale)
                    } else {
                        // Charge + Effort (#446) — one more stat alongside the leading live HR.
                        HStack(spacing: 10) {
                            if let r = context.state.recovery {
                                statColumn(label: "Charge", value: "\(r)%")
                            }
                            if let e = context.state.effort {
                                statColumn(label: "Effort", value: "\(e)")
                            }
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let start = context.state.workoutStart {
                        HStack(alignment: .firstTextBaseline) {
                            Text(timerInterval: start...Date.distantFuture, countsDown: false)
                                .font(.system(.title2, design: .rounded).weight(.bold))
                                .monospacedDigit()
                                // Text(timerInterval:) reserves a wider frame for the widest H:MM:SS and
                                // left-aligns inside it by default, which drifts short elapsed times off
                                // center under their column — see OpenCircuit's `ElapsedText` for the
                                // same fix.
                                .multilineTextAlignment(.center)
                                .foregroundStyle(StrandPalette.textSecondary)
                            Spacer()
                            effortReadout(text: context.state.workoutEffortText)
                        }
                        .padding(.top, 2)
                    } else {
                        Text(context.attributes.title).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                if context.state.workoutStart != nil {
                    HStack(spacing: 3) {
                        Image(systemName: WorkoutTypeIconography.systemSymbolName(for: context.state.sport ?? ""))
                            .foregroundStyle(StrandPalette.textSecondary)
                        zoneChip(zone: context.state.zone ?? 0, compact: true)
                    }
                } else {
                    Image(systemName: "heart.fill").foregroundStyle(StrandPalette.statusCritical)
                }
            } compactTrailing: {
                if context.state.workoutStart != nil {
                    heartReadout(bpm: context.state.bpm, zone: context.state.zone ?? 0,
                                isStale: context.isStale, compact: true)
                } else {
                    Text("\(context.state.bpm.map(String.init) ?? "–")")
                }
            } minimal: {
                if context.state.workoutStart != nil {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(heartTint(bpm: context.state.bpm, zone: context.state.zone ?? 0,
                                                   isStale: context.isStale))
                } else {
                    Image(systemName: "heart.fill").foregroundStyle(StrandPalette.statusCritical)
                }
            }
        }
    }
}

// MARK: - Ambient (Live HR) Lock Screen — byte-identical to the pre-workout-mode banner

private struct AmbientLockScreenView: View {
    let context: ActivityViewContext<NOOPActivityAttributes>

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform.path.ecg")
                .font(.title2)
                .foregroundStyle(StrandPalette.statusCritical)
            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.title)
                    .font(.caption).foregroundStyle(StrandPalette.textSecondary)
                Text("\(context.state.bpm.map(String.init) ?? "–") bpm")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            Spacer()
            // Charge + Effort (#446) on the banner, mirroring the Dynamic Island expanded stats.
            HStack(spacing: 12) {
                if let r = context.state.recovery {
                    bannerStat(label: "Charge", value: "\(r)%")
                }
                if let e = context.state.effort {
                    bannerStat(label: "Effort", value: "\(e)")
                }
            }
        }
    }
}

// MARK: - Workout Lock Screen ("Zone Glass" — the glance grid)

private struct WorkoutLockScreenView: View {
    let context: ActivityViewContext<NOOPActivityAttributes>
    let start: Date

    private var zone: Int { context.state.zone ?? 0 }
    private var zoneTint: Color { zone >= 1 ? StrandPalette.hrZoneColor(zone) : StrandPalette.effortColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The zone keyline, expressed as a top accent bar rather than a perimeter stroke — the
            // system draws its own rounded card behind this content (via `.activityBackgroundTint`)
            // and its exact corner geometry isn't ours to match precisely.
            Capsule().fill(zoneTint).frame(height: 3).frame(maxWidth: .infinity)

            HStack(spacing: 8) {
                Image(systemName: WorkoutTypeIconography.systemSymbolName(for: context.state.sport ?? ""))
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(context.state.sport ?? "Workout")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Text("Workout")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
            }

            HStack(spacing: 0) {
                gridCell(label: "Time") {
                    Text(timerInterval: start...Date.distantFuture, countsDown: false)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                gridCell(label: "Heart") {
                    if let bpm = context.state.bpm, !context.isStale {
                        Text("\(bpm)").foregroundStyle(zoneTint)
                    } else {
                        Text("—").foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                gridCell(label: "Effort") {
                    if let effortText = context.state.workoutEffortText {
                        Text(effortText).foregroundStyle(StrandPalette.effortColor)
                    } else {
                        Text("—").foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                gridCell(label: "Cal · est") {
                    if let kcal = context.state.workoutKcal {
                        HStack(spacing: 2) {
                            Image(systemName: "flame.fill")
                                .font(.caption2)
                                .foregroundStyle(StrandPalette.metricAmber)
                            Text("\(kcal)").foregroundStyle(StrandPalette.textPrimary)
                        }
                    } else {
                        Text("—").foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }

            // Distance/pace render only when GPS is actually live for a distance sport — no reserved
            // empty row for every other workout (mirrors `DistancePaceRowIfPresent` in LiveWorkoutView).
            if let distanceText = context.state.distanceText {
                HStack(spacing: 0) {
                    gridCell(label: "Dist") {
                        Text(distanceText).foregroundStyle(StrandPalette.textSecondary)
                    }
                    gridCell(label: "Pace") {
                        Text(context.state.paceText ?? "—").foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func gridCell<Content: View>(label: String, @ViewBuilder value: () -> Content) -> some View {
        VStack(spacing: 2) {
            value()
                .font(.system(.title3, design: .rounded).weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Shared workout-mode Dynamic Island pieces

/// "Z3" (or "Z3 · Aerobic" when `withName`), tinted and backgrounded by the zone color — falls back to
/// `effortColor` below Zone 1, matching `LiveWorkoutView.swift`'s own zone-tint rule.
@ViewBuilder
private func zoneChip(zone: Int, withName: Bool = false, compact: Bool = false) -> some View {
    let tint = zone >= 1 ? StrandPalette.hrZoneColor(zone) : StrandPalette.effortColor
    let label = zone >= 1 ? (withName ? "Z\(zone) · \(zoneName(zone))" : "Z\(zone)") : "—"
    Text(label)
        .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, compact ? 5 : 7)
        .padding(.vertical, 2)
        .background(tint.opacity(0.22), in: Capsule())
        .lineLimit(1)
}

private func zoneName(_ zone: Int) -> String {
    switch zone {
    case 1: return "Recovery"
    case 2: return "Fat burn"
    case 3: return "Aerobic"
    case 4: return "Threshold"
    case 5: return "Maximum"
    default: return ""
    }
}

/// Heart-rate readout for the workout mode: the zone-tinted reading, or a dimmed "—" the instant it's
/// absent OR stale — never a frozen held value (same discipline `LiveActivityController` already
/// applies to the ambient mode's `bonded`-vs-`connected` distinction).
@ViewBuilder
private func heartReadout(bpm: Int?, zone: Int, isStale: Bool, compact: Bool = false) -> some View {
    let tint = heartTint(bpm: bpm, zone: zone, isStale: isStale)
    HStack(spacing: 3) {
        Image(systemName: "heart.fill").font(compact ? .caption2 : .caption).foregroundStyle(tint)
        if let bpm, !isStale {
            Text("\(bpm)").font(compact ? .callout.weight(.semibold) : .headline)
                .monospacedDigit().foregroundStyle(tint)
        } else {
            Text("—").font(compact ? .callout.weight(.semibold) : .headline).foregroundStyle(tint)
        }
    }
}

private func heartTint(bpm: Int?, zone: Int, isStale: Bool) -> Color {
    guard bpm != nil, !isStale else { return StrandPalette.textTertiary }
    return zone >= 1 ? StrandPalette.hrZoneColor(zone) : StrandPalette.effortColor
}

/// Bottom-region effort readout for the expanded Dynamic Island — "—" while `StrainScorer` hasn't
/// scored yet, never "0" (the same honesty rule the Lock Screen grid's Effort cell follows).
@ViewBuilder
private func effortReadout(text: String?) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text(text ?? "—")
            .font(.system(.title3, design: .rounded).weight(.semibold))
            .foregroundStyle(text == nil ? StrandPalette.textTertiary : StrandPalette.effortColor)
        Text("effort").font(.caption2).foregroundStyle(.secondary)
    }
}

// MARK: - Ambient-mode stat columns (unchanged)

/// Lock-Screen banner stat column (label over value). File-scope because the `ActivityConfiguration`
/// content closure isn't a method of `NOOPLiveActivity`.
///
/// #759 - the label and value are CENTRE-aligned so each value sits directly under its own label. The
/// old `.trailing` alignment right-pinned both to the column's edge: when the value was narrower than
/// the label (e.g. "12" under "Effort") it drifted to the label's right edge instead of under it, which
/// read as "the number doesn't line up with its label". `fixedSize` stops either line truncating so the
/// pairing is never clipped at narrow widths.
@ViewBuilder
private func bannerStat(label: String, value: String) -> some View {
    VStack(alignment: .center, spacing: 2) {
        Text(label).font(.caption2).foregroundStyle(StrandPalette.textSecondary)
        Text(value).font(.headline).foregroundStyle(StrandPalette.textPrimary)
    }
    .multilineTextAlignment(.center)
    .fixedSize()
}

/// Dynamic Island expanded-region stat column (label over value). File-scope for the same reason as
/// `bannerStat`. #759 - centre-aligned + `fixedSize` for the same value-under-its-label fix as the banner.
@ViewBuilder
private func statColumn(label: String, value: String) -> some View {
    VStack(alignment: .center, spacing: 1) {
        Text(label).font(.caption2).foregroundStyle(.secondary)
        Text(value).font(.headline)
    }
    .multilineTextAlignment(.center)
    .fixedSize()
}
