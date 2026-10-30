import SwiftUI
import Foundation

/// The running turn's figures under the transcript (web `LiveTurnStats` parity):
/// elapsed time, files changed with +/- lines, and an estimated output rate.
/// Deliberately quiet — the timeline already says what the agent is doing.
struct LiveTurnStatsRow: View {
    @ObservedObject var live: LiveTurn

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsedMs = max(0, Int(context.date.timeIntervalSince(live.startedAt) * 1000))
            let edits = live.liveEditStats
            HStack(spacing: 12) {
                stat(icon: "timer", text: DurationFormat.short(elapsedMs))
                if edits.files > 0 {
                    stat(icon: "doc.text", text: "\(edits.files)F +\(TokenFormat.compact(edits.additions))/-\(TokenFormat.compact(edits.deletions))")
                }
                if let tps = live.outputTokensPerSecond, tps > 0 {
                    stat(icon: "paperplane", text: String(format: "%.1f tok/s", tps))
                }
                Spacer(minLength: 0)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, Theme.Layout.screenHMargin)
            .padding(.vertical, 4)
        }
    }

    private func stat(icon: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9, weight: .semibold))
            Text(verbatim: text)
        }
    }
}

/// Compact context-window readout near the composer (web `ComposerContextUsage`
/// parity). The full input/output/cache breakdown stays in Session Details; this
/// is the always-visible "how full is the window" figure.
struct ComposerContextUsage: View {
    let stats: SessionStats

    static func hasData(_ stats: SessionStats) -> Bool {
        stats.contextWindowUsedTokens != nil || (stats.contextWindowMaxTokens ?? 0) > 0
    }

    private var percent: Double? {
        if let pct = stats.contextWindowUsagePercent {
            return max(0, min(100, pct))
        }
        guard let used = stats.contextWindowUsedTokens,
              let cap = stats.contextWindowMaxTokens, cap > 0 else { return nil }
        return max(0, min(100, Double(used) / Double(cap) * 100))
    }

    private var figures: String? {
        guard let cap = stats.contextWindowMaxTokens, cap > 0 else {
            return stats.contextWindowUsedTokens.map(TokenFormat.compact)
        }
        let used = stats.contextWindowUsedTokens.map(TokenFormat.compact) ?? "—"
        return "\(used) / \(TokenFormat.compact(cap))"
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("Context")
                .font(.caption2.weight(.semibold))
            if let percent {
                ProgressView(value: percent / 100)
                    .progressViewStyle(.linear)
                    .frame(width: 48)
                    .tint(tint(percent))
                Text(verbatim: "\(Int(percent.rounded()))%")
            }
            if let figures {
                Text(verbatim: figures)
            }
            Spacer(minLength: 0)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, Theme.Layout.screenHMargin)
        .padding(.vertical, 4)
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
