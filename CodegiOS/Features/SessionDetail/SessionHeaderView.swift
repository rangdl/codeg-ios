import SwiftUI

/// The session header: a flat card carrying identity (title, agent, status),
/// the model + git branch, and a compact token / context-window readout
/// derived from `SessionStats`. Intentionally shadowless (a plain tinted
/// surface, not Liquid Glass) so the banner sits calmly atop the transcript.
struct SessionHeaderView: View {
    let summary: ConversationSummary
    let stats: SessionStats?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Title + badges
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                (summary.trimmedTitle.map { Text(verbatim: $0) } ?? Text("Untitled session"))
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                StatusBadge(status: summary.status)
            }

            // Meta row: agent · model · branch
            HStack(spacing: 8) {
                AgentBadge(agent: summary.agentType)
                if let model = summary.model, !model.isEmpty {
                    MetaChip(symbol: "cpu", text: model, mono: true)
                }
                if let branch = summary.gitBranch, !branch.isEmpty {
                    MetaChip(symbol: "arrow.triangle.branch", text: branch, mono: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let usage = UsageReadout(summary: summary, stats: stats) {
                Divider().overlay(Theme.hairline)
                usage
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .hairlineBorder(Theme.Radius.lg)
    }
}

/// A small icon+text chip used in the header meta row.
private struct MetaChip: View {
    let symbol: String
    let text: String
    var mono: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(mono ? .mono(11) : .caption2.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.05), in: Capsule())
    }
}

/// Token + context-window summary, web `session-details-content` token
/// section parity: total, input, output, cache write/read, context window.
/// Cache lines hide when zero (they carry no signal for agents that don't
/// report caching). Initializer fails when there is nothing to show, so the
/// header can omit the whole row.
private struct UsageReadout: View {
    let tokensLabel: String?
    let inputLabel: String?
    let outputLabel: String?
    let cacheWriteLabel: String?
    let cacheReadLabel: String?
    let durationLabel: String?
    let contextPercent: Double?
    let contextLabel: String?

    /// The web resolves the percentage by trusting the backend figure,
    /// recomputing from used/max only when absent, clamped to 0–100.
    private static func contextPercent(stats: SessionStats?) -> Double? {
        guard let stats else { return nil }
        if let pct = stats.contextWindowUsagePercent {
            return max(0, min(100, pct))
        }
        guard let used = stats.contextWindowUsedTokens,
              let cap = stats.contextWindowMaxTokens, cap > 0 else { return nil }
        return max(0, min(100, Double(used) / Double(cap) * 100))
    }

    /// Web parity (`resolveSessionDurationMs`): the recorded generation time
    /// when present, else for completed sessions the created→updated span.
    private static func durationLabel(summary: ConversationSummary, stats: SessionStats?) -> String? {
        var ms = stats?.totalDurationMs ?? 0
        if ms <= 0 {
            guard summary.status == .completed else { return nil }
            let span = Int(summary.updatedAt.timeIntervalSince(summary.createdAt) * 1000)
            guard span > 0 else { return nil }
            ms = span
        }
        return Self.formatDuration(ms)
    }

    /// Web session-details `formatDuration` parity: `450ms` / `12.3s` /
    /// `4.5m` / `1.2h` (trailing `.0` trimmed).
    static func formatDuration(_ ms: Int) -> String {
        func trim(_ value: Double) -> String {
            var s = String(format: "%.1f", value)
            if s.hasSuffix(".0") { s.removeLast(2) }
            return s
        }
        if ms < 1_000 { return "\(ms)ms" }
        let seconds = Double(ms) / 1_000
        if seconds < 60 { return "\(trim(seconds))s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(trim(minutes))m" }
        return "\(trim(minutes / 60))h"
    }

    init?(summary: ConversationSummary, stats: SessionStats?) {
        guard let stats else { return nil }

        let usage = stats.totalUsage
        let tokenCount = stats.totalTokens ?? usage?.total
        if let tokenCount, tokenCount > 0 {
            tokensLabel = TokenFormat.compact(tokenCount) + " tokens"
        } else {
            tokensLabel = nil
        }

        func compact(_ n: Int?) -> String? {
            guard let n, n > 0 else { return nil }
            return TokenFormat.compact(n)
        }
        inputLabel = compact(usage?.inputTokens)
        outputLabel = compact(usage?.outputTokens)
        cacheWriteLabel = compact(usage?.cacheCreationInputTokens)
        cacheReadLabel = compact(usage?.cacheReadInputTokens)

        // Never coerce an unknown `used` to 0 — some parsers infer the model's
        // context cap without any usage figure, so render "— / max" rather
        // than a bogus "0 / max". With only a `used`, show it alone.
        let used = stats.contextWindowUsedTokens
        let cap = stats.contextWindowMaxTokens
        contextPercent = Self.contextPercent(stats: stats)
        if let cap, cap > 0 {
            let usedText = used != nil ? TokenFormat.compact(used!) : "—"
            contextLabel = "\(usedText) / \(TokenFormat.compact(cap))"
        } else if let used {
            contextLabel = TokenFormat.compact(used)
        } else {
            contextLabel = nil
        }

        durationLabel = Self.durationLabel(summary: summary, stats: stats)

        if tokensLabel == nil && inputLabel == nil && contextPercent == nil && durationLabel == nil { return nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if let tokensLabel {
                    HStack(spacing: 4) {
                        Image(systemName: "circle.hexagongrid.fill").font(.system(size: 9))
                        Text(tokensLabel).font(.mono(11))
                    }
                    .foregroundStyle(Theme.textSecondary)
                }

                if contextPercent != nil || contextLabel != nil {
                    HStack(spacing: 6) {
                        if let contextPercent {
                            ContextGauge(fraction: contextPercent / 100)
                                .frame(width: 54, height: 5)
                            Text(percentText(contextPercent))
                                .font(.mono(11))
                                .foregroundStyle(contextTint(contextPercent / 100))
                        }
                        if let contextLabel {
                            Text(contextLabel)
                                .font(.mono(10))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
                if let durationLabel {
                    HStack(spacing: 4) {
                        Image(systemName: "clock").font(.system(size: 9))
                        Text(durationLabel).font(.mono(11))
                    }
                    .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }

            // Input / output / cache write / cache read — the web details'
            // per-usage rows, as compact labeled figures. Hidden entirely when
            // no usage is recorded (some agents send no per-turn usage).
            if inputLabel != nil || outputLabel != nil || cacheWriteLabel != nil || cacheReadLabel != nil {
                HStack(spacing: 12) {
                    usageStat("Input", inputLabel, symbol: "arrow.down")
                    usageStat("Output", outputLabel, symbol: "arrow.up")
                    usageStat("Cache W", cacheWriteLabel, symbol: "square.and.arrow.down.on.square")
                    usageStat("Cache R", cacheReadLabel, symbol: "square.and.arrow.down")
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private func usageStat(_ name: LocalizedStringKey, _ value: String?, symbol: String) -> some View {
        if let value {
            HStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 8, weight: .semibold))
                Text(name)
                    .font(.system(size: 9, weight: .medium))
                Text(value)
                    .font(.mono(10))
            }
            .foregroundStyle(Theme.textTertiary)
        }
    }

    /// One decimal place, matching the web `formatContextWindowPercent`.
    private func percentText(_ percent: Double) -> String {
        String(format: "%.1f%%", percent)
    }

    private func contextTint(_ percent: Double) -> Color {
        switch percent {
        case ..<70: return Theme.textSecondary
        case ..<90: return Theme.warning
        default: return Theme.danger
        }
    }
}

/// A slim capsule progress bar for context-window usage.
private struct ContextGauge: View {
    let fraction: Double

    private var tint: Color {
        switch fraction {
        case ..<0.7: return Theme.accent
        case ..<0.9: return Theme.warning
        default: return Theme.danger
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(tint)
                    .frame(width: max(3, geo.size.width * fraction))
            }
        }
    }
}
