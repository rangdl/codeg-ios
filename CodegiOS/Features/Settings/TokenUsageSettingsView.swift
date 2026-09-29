import SwiftUI

/// Server-side token usage dashboard (web `token-usage` parity, mobile shape):
/// totals for the range, a daily bar series, and by-model / by-agent /
/// by-folder breakdowns. Data comes from `token_usage_report` — the same
/// aggregated store the web dashboard reads, so numbers match it exactly.
struct TokenUsageSettingsView: View {
    let client: CodegClient?

    @State private var report: TokenUsageReport?
    @State private var isLoading = false
    @State private var error: String?
    /// Days the report covers (local-time day buckets, ending today).
    @State private var days = 30

    var body: some View {
        Group {
            if client == nil {
                EmptyStateView(icon: "server.rack", title: "No Server Selected",
                               message: "Pick a server to see its token usage.")
            } else if isLoading, report == nil {
                LoadingView(label: "Loading usage…")
            } else if let error, report == nil {
                InlineErrorView(message: error) { Task { await load() } }
            } else if let report {
                List {
                    totalsCard(report.totals)
                    seriesSection(report)
                    breakdownSection("By Model", icon: "cpu", items: report.byModel)
                    breakdownSection("By Agent", icon: "waveform", items: report.byAgent)
                    breakdownSection("By Folder", icon: "folder", items: report.byFolder)
                    if report.truncated == true {
                        Label("The range is very large — numbers cover only its most recent slice.",
                              systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .scrollContentBackground(.hidden)
            } else {
                EmptyStateView(icon: "chart.bar", title: "No Usage Yet",
                               message: "Token counts appear once agents run.")
            }
        }
        .background(CodegBackground())
        .navigationTitle("Token Usage")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Picker("Range", selection: $days) {
                    Text("7D").tag(7)
                    Text("30D").tag(30)
                    Text("90D").tag(90)
                }
                .pickerStyle(.menu)
                .onChange(of: days) { _ in Task { await load() } }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let tz = -TimeZone.current.secondsFromGMT() / 60
            let start = ISO8601.dateOnlyString(daysAgo: days)
            report = try await client.tokenUsageReport(filter: TokenUsageFilterBody(
                start: start, end: nil, folderIds: nil, agentTypes: nil, models: nil,
                bucket: "day", tzOffsetMinutes: tz, comparePrevious: false))
            error = nil
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Sections

    private func totalsCard(_ t: TokenUsageTotals) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Total Tokens")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
            Text(Self.compact(t.totalTokens))
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            HStack(spacing: 14) {
                stat("Input", t.inputTokens)
                stat("Output", t.outputTokens)
                if let cc = t.cacheCreationTokens { stat("Cache W", cc) }
                if let cr = t.cacheReadTokens { stat("Cache R", cr) }
            }
            Divider().overlay(Theme.hairline)
            HStack(spacing: 14) {
                Label("\(t.turnCount) turns", systemImage: "bubble.left.and.bubble.right")
                Label("\(t.conversationCount) sessions", systemImage: "square.stack")
                Label("\(t.activeDays)d active", systemImage: "calendar")
            }
            .font(.caption)
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .hairlineBorder(Theme.Radius.lg)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(Self.compact(value))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    /// Daily bars — plain rounded rects over the shared theme, scaled to the max.
    private func seriesSection(_ report: TokenUsageReport) -> some View {
        let points = report.series
        let maxTokens = max(points.map(\.totalTokens).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Daily")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            if points.isEmpty {
                Text("No usage in this range.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textTertiary)
            } else {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Theme.accent.opacity(p.totalTokens == 0 ? 0.15 : 0.75))
                            .frame(height: max(2, CGFloat(p.totalTokens) / CGFloat(maxTokens) * 56))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 58)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .hairlineBorder(Theme.Radius.lg)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    }

    private func breakdownSection(_ title: LocalizedStringKey, icon: String,
                                  items: [TokenUsageBreakdownItem]) -> some View {
        Group {
            if !items.isEmpty {
                Section {
                    ForEach(items.prefix(8), id: \.key) { item in
                        HStack(spacing: 10) {
                            Image(systemName: icon)
                                .font(.caption)
                                .foregroundStyle(Theme.textTertiary)
                                .frame(width: 18)
                            Text(verbatim: item.label ?? item.key)
                                .font(.subheadline)
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(Self.compact(item.totalTokens))
                                .font(.subheadline.weight(.medium).monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Label(title, systemImage: icon)
                }
            }
        }
    }

    /// 12.3k / 4.5M style compact counts.
    static func compact(_ value: Int) -> String {
        switch value {
        case ..<1_000: return "\(value)"
        case ..<1_000_000: return String(format: "%.1fk", Double(value) / 1_000)
        case ..<1_000_000_000: return String(format: "%.1fM", Double(value) / 1_000_000)
        default: return String(format: "%.1fB", Double(value) / 1_000_000_000)
        }
    }
}

extension ISO8601 {
    /// Local-midnight N days ago, as an RFC3339 string (the filter's inclusive `start`).
    static func dateOnlyString(daysAgo: Int) -> String {
        var cal = Calendar.current
        cal.timeZone = .current
        let start = cal.startOfDay(for: Date())
        let date = cal.date(byAdding: .day, value: -daysAgo + 1, to: start) ?? start
        var formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
