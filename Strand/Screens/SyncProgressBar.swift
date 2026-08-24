import SwiftUI
import StrandDesign

/// #1005-STORM: "catching up on last night" — a thin, full-width determinate bar at the top of Today,
/// so a sync/analyze pass that used to run silently for minutes is visible rather than presenting
/// half-scored data as final. See `SyncProgress.swift` for what the fraction actually means (two phases,
/// one of them a time ESTIMATE, not a measurement — read that file before assuming this is more precise
/// than it is).
///
/// Deliberately reads `SyncProgress`, NOT `LiveState` — this exists specifically so a screen that wants
/// this bar does not also inherit `LiveState`'s ~60-property churn (see that type's doc notes on why
/// TodayView avoids observing it directly). Renders nothing (`EmptyView`, zero layout impact) while
/// `phase == .idle`, so a screen that never syncs never pays for this.
struct SyncProgressBar: View {
    @EnvironmentObject private var progress: SyncProgress

    var body: some View {
        if progress.phase != .idle {
            VStack(alignment: .leading, spacing: 4) {
                TypicalRangeBar(value: progress.fraction, color: StrandPalette.accent,
                                height: NoopMetrics.indicatorTrackHeight, cornerRadius: 0)
                    .animation(.easeInOut(duration: 0.3), value: progress.fraction)

                Text(label)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .padding(.horizontal, NoopMetrics.screenHPadding)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(axLabel))
            .transition(.opacity)
        }
    }

    private var label: String {
        switch progress.phase {
        case .idle: return ""   // unreachable (body already gates on phase != .idle), kept exhaustive
        case .offload: return String(localized: "Catching up on last night…")
        case .analyze: return String(localized: "Scoring last night…")
        }
    }

    private var axLabel: String {
        let pct = Int((progress.fraction * 100).rounded())
        return "\(label), \(pct) percent"
    }
}

#if DEBUG
#Preview("SyncProgressBar") {
    let offload = SyncProgress()
    offload.beginOffload(frontier: 0)
    offload.updateOffload(frontier: 30)   // fabricated fractions for the preview only, not live data

    let analyze = SyncProgress()
    analyze.beginOffload(frontier: 0)
    analyze.updateOffload(frontier: 100)
    analyze.beginAnalyze()
    analyze.tickAnalyzeEstimate()

    return VStack(spacing: 24) {
        SyncProgressBar().environmentObject(offload)
        SyncProgressBar().environmentObject(analyze)
        SyncProgressBar().environmentObject(SyncProgress())   // idle — renders nothing, shown for contrast
    }
    .padding(.vertical, 40)
    .background(StrandPalette.surfaceBase)
}
#endif
