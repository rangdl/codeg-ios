import SwiftUI
import Foundation

/// One compact row above the composer: the running turn's figures on the left
/// (elapsed, files changed, tok/s) and the context-window usage on the right.
/// Web parity: the two read as one line rather than two stacked strips.
struct ComposerMetricsRow: View {
    let live: LiveTurn?
    let context: ContextUsageSnapshot?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let live {
                LiveStatsContent(live: live)
            }
            Spacer(minLength: 8)
            if let context {
                ContextFigure(usage: context)
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, Theme.Layout.screenHMargin)
        .padding(.vertical, 4)
    }
}

/// The left half. Observes the live turn for tool/output updates and ticks once
/// a second for the elapsed label.
private struct LiveStatsContent: View {
    @ObservedObject var live: LiveTurn

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsedMs = max(0, Int(context.date.timeIntervalSince(live.startedAt) * 1000))
            let edits = live.liveEditStats
            HStack(spacing: 10) {
                stat(icon: "timer", text: DurationFormat.short(elapsedMs))
                if edits.files > 0 {
                    stat(
                        icon: "doc.text",
                        text: "\(edits.files)F +\(TokenFormat.compact(edits.additions))/-\(TokenFormat.compact(edits.deletions))"
                    )
                }
                if let tps = live.outputTokensPerSecond, tps > 0 {
                    stat(icon: "paperplane", text: String(format: "%.1f tok/s", tps))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .layoutPriority(0)
        }
    }

    private func stat(icon: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9, weight: .semibold))
            Text(verbatim: text)
        }
    }
}

/// The right half: context occupancy. Compact enough to share the row with the
/// live figures; `/max` is shown when the server reports it.
private struct ContextFigure: View {
    let usage: ContextUsageSnapshot

    var body: some View {
        HStack(spacing: 5) {
            Text("Context")
                .font(.caption2.weight(.semibold))
            if let percent = usage.percent {
                ProgressView(value: percent / 100)
                    .progressViewStyle(.linear)
                    .frame(width: 36)
                    .tint(tint(percent))
                Text(verbatim: "\(Int(percent.rounded()))%")
            }
            if let figures {
                Text(verbatim: figures)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .layoutPriority(1)
    }

    private var figures: String? {
        if let max = usage.max, max > 0 {
            let used = usage.used.map(TokenFormat.compact) ?? "—"
            return "\(used) / \(TokenFormat.compact(max))"
        }
        return usage.used.map(TokenFormat.compact)
    }

    private func tint(_ pct: Double) -> Color {
        if pct >= 90 { return Theme.danger }
        if pct >= 70 { return Color(red: 0.95, green: 0.65, blue: 0.20) }
        return Theme.accent
    }
}

/// One quiet composer status strip (connecting / reconnecting). Kept separate
/// from the transcript's inline error card: this reports a transient transport
/// state, not a failed turn.
struct ComposerStatusRow: View {
    let icon: String
    let text: LocalizedStringKey
    var tint: Color = Theme.textSecondary
    var spinning: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            if spinning {
                ProgressView().controlSize(.mini).tint(tint)
            } else {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            }
            Text(text).font(.caption2.weight(.medium))
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tint.opacity(0.08), in: Capsule())
        .padding(.horizontal, Theme.Layout.screenHMargin)
        .padding(.vertical, 3)
    }
}
