import SwiftUI

/// Chat channels: a list (channel ⨝ live status) where each row pushes a detail
/// for connect/test/logs, plus a "+" to add one and a row into the global message
/// settings (command prefix, language, event filter, webhooks).
struct ChatChannelsSettingsView: View {
    let client: CodegClient?
    @StateObject private var model: ChatChannelsSettingsModel
    @State private var showAdd = false
    @State private var pendingDelete: ChatChannelInfo?
    /// TEMPORARY (hang triage): bump to re-read the probe counters.
    @State private var probeTick = 0
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme

    init(client: CodegClient?) {
        self.client = client
        _model = StateObject(wrappedValue: ChatChannelsSettingsModel(client: client))
    }

    var body: some View {
        // TEMPORARY (hang triage): SwiftUI prints *why* this body re-ran; stdout is
        // redirected to a file by `HangProbe.startCapturingStdout()` and the card
        // reads it back. The explicit line is a fallback that survives even if
        // `_printChanges()` is a no-op in a release build.
        let _ = Self._printChanges()
        let _ = print("[probe] list hz=\(horizontalSizeClass == .compact ? "C" : "R") scheme=\(colorScheme == .dark ? "D" : "L") add=\(showAdd) del=\(pendingDelete?.id ?? -1) tick=\(probeTick) phase=\(model.phase) n=\(model.channels.count) st=\(model.statuses.count)")
        let _ = HangProbe.bodyTick("list")
        ZStack {
            CodegBackground()
            content
        }
        // A standard large title (matches Experts / Skills / Agents / Model
        // Providers): big at the top on compact, collapsing to a centered inline
        // title as the list scrolls. iPad keeps the system default.
        .onAppear { HangProbe.bump("list.appear") }   // TEMPORARY (hang triage)
        .navigationTitle("Chat Channels")
        .navigationBarTitleDisplayMode(horizontalSizeClass == .compact ? .large : .automatic)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showAdd = true } label: { Image(systemName: "plus") }
                    .tint(Theme.accent)
                    .accessibilityLabel("Add Channel")
            }
        }
        // The row content is a plain `NavigationLink` (the toggle beside it stays
        // outside the label, so it still owns its own taps). `navigationDestination
        // (item:)` — the item-driven form upstream uses — is iOS 17+, and the
        // `isPresented` stand-in declared here (inside a screen that is itself a
        // destination of the settings stack) made iOS 16's navigation authority
        // re-register the destination every frame: "Update NavigationAuthority
        // bound path tried to update multiple times per frame", the body
        // re-evaluated at display rate, no frame was ever committed, and the
        // scene-update watchdog killed the app.
        .sheet(isPresented: $showAdd) {
            ChatChannelEditorSheet(editing: nil, client: client) { name, type, configJson, enabled, daily, dailyTime, token in
                try await model.create(name: name, type: type, configJson: configJson, enabled: enabled, dailyReportEnabled: daily, dailyReportTime: dailyTime, token: token)
            } onUpdate: { _, _ in }
        }
        .confirmationDialog(
            "Delete Channel",
            // Same hazard as the destination above: SwiftUI writes `false` here
            // during its own updates, and clearing `@State` that is already nil
            // still invalidates — an endless re-render. Only clear when set.
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { newValue in
                    HangProbe.bump("dlg.set")            // TEMPORARY (hang triage)
                    guard !newValue, pendingDelete != nil else { return }
                    HangProbe.bump("dlg.write")          // TEMPORARY (hang triage)
                    pendingDelete = nil
                }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { channel in
            Button("Delete \(channel.name)", role: .destructive) {
                Task { await model.delete(channel) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: { channel in
            Text("Remove “\(channel.name)” and its stored token.")
        }
        .overlay(alignment: .bottom) { toastView }
        .animation(.snappy(duration: 0.25), value: model.toast)
        .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        if model.channels.isEmpty {
            switch model.phase {
            case .loading:
                LoadingView(label: "Loading channels…")
            case .failed(let message):
                InlineErrorView(message: message) { Task { await model.load() } }
            case .loaded:
                ScrollView {
                    VStack(spacing: 14) {
                        probeCard
                        EmptyStateView(
                            icon: "bell.badge.fill",
                            title: "No Chat Channels",
                            message: "Connect Telegram, Lark, or WeChat to get notified and chat with your agents.",
                            actionTitle: "Add Channel",
                            action: { showAdd = true }
                        )
                        generalSection
                    }
                    .padding(.horizontal, Theme.Layout.screenHMargin)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
                .scrollContentBackground(.hidden)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    probeCard
                    if let error = model.refreshError {
                        RefreshErrorBanner(
                            message: error,
                            retry: { Task { await model.load() } },
                            dismiss: { model.refreshError = nil }
                        )
                    }
                    ForEach(model.channels) { channel in
                        ChannelRow(
                            channel: channel,
                            status: model.status(for: channel),
                            model: model,
                            client: client
                        )
                        .contextMenu {
                            Button(role: .destructive) { pendingDelete = channel } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    generalSection
                        .padding(.top, 8)
                }
                .padding(.horizontal, Theme.Layout.screenHMargin)
                .padding(.top, 2)
                .padding(.bottom, 24)
            }
            .scrollContentBackground(.hidden)
            .refreshable { await model.load() }
        }
    }

    /// The cross-channel "Message Settings" entry, set apart from the channel
    /// cards under its own header so it doesn't read as just another channel.
    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("GENERAL")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
                .tracking(0.5)
                .padding(.leading, 4)
            NavigationLink {
                ChatGlobalSettingsView(client: client)
            } label: {
                GlassCard(cornerRadius: Theme.Radius.md, padding: 13) {
                    HStack(spacing: 13) {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Theme.accentDim)
                            .frame(width: 40, height: 40)
                            .overlay(
                                Image(systemName: "slider.horizontal.3")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(Theme.accent)
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Message Settings")
                                .font(.headline)
                                .foregroundStyle(Theme.textPrimary)
                            Text("Command prefix, language, events, webhooks")
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast = model.toast {
            Text(toast)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .codegGlassEffect(tint: Theme.accent.opacity(0.18), in: Capsule())
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: toast) {
                    try? await Task.sleep(for: .seconds(3))
                    if !Task.isCancelled { model.toast = nil }
                }
        }
    }
    // MARK: - TEMPORARY hang triage

    /// Counters written by `HangProbe`, shown here because this screen does not
    /// hang: reproduce the freeze in Message Settings, relaunch, and read them.
    /// Remove with `HangProbe`.
    private var probeCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("HANG PROBE")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 8)
                Text("v\(probeTick)").font(.caption2).foregroundStyle(Theme.textTertiary)
                Button("Reset") { HangProbe.reset(); probeTick &+= 1 }
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
            }
            ForEach(HangProbe.snapshot(), id: \.name) { row in
                HStack {
                    Text(row.name)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 8)
                    Text("\(row.count)")
                        .font(.system(size: 11, design: .monospaced).weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            Divider().padding(.vertical, 2)
            Text("captured stdout")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
            ForEach(HangProbe.capturedLines(), id: \.name) { row in
                HStack(alignment: .top) {
                    Text(row.name)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Text("\(row.count)")
                        .font(.system(size: 10, design: .monospaced).weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            if !HangProbe.capturedStack.isEmpty {
                Divider().padding(.vertical, 2)
                Text("main-thread stack at first loop")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
                Text(HangProbe.capturedStack)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md)
    }

}

/// One channel card: type avatar, name + live status pill, the config summary
/// (and daily-report time when set), a chevron, and an instant enable toggle.
/// Tapping the content (not the toggle) opens the detail.
private struct ChannelRow: View {
    let channel: ChatChannelInfo
    let status: ChannelConnectionStatus
    let model: ChatChannelsSettingsModel
    let client: CodegClient?

    private var configSummary: String {
        ChannelConfig.parse(channel.configJson).summary(type: channel.channelType)
    }

    var body: some View {
        GlassCard(cornerRadius: Theme.Radius.md, padding: 12) {
            HStack(spacing: 12) {
                NavigationLink {
                    ChatChannelDetailView(channel: channel, client: client) {
                        Task { await model.load() }
                    }
                } label: {
                    HStack(spacing: 12) {
                        ChannelTypeAvatar(type: channel.channelType, size: 40)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 7) {
                                Text(channel.name)
                                    .font(.headline)
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                ChannelStatusPill(status: status)
                            }
                            if !configSummary.isEmpty {
                                Text(configSummary)
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            if channel.dailyReportEnabled, let time = channel.dailyReportTime {
                                HStack(spacing: 5) {
                                    Image(systemName: "clock")
                                        .font(.caption2)
                                        .foregroundStyle(Theme.textTertiary)
                                    Text("Daily report · \(time)")
                                        .font(.caption)
                                        .foregroundStyle(Theme.textTertiary)
                                        .monospacedDigit()
                                }
                            }
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Toggle("", isOn: Binding(
                    get: { channel.enabled },
                    set: { on in Task { await model.setEnabled(channel, on) } }
                ))
                .labelsHidden()
                .tint(Theme.accent)
                .accessibilityLabel("\(channel.name) enabled")
                .disabled(model.togglingEnabled.contains(channel.id))
            }
        }
        .contentShape(Rectangle())
    }
}

/// A small status pill reflecting a channel's live connection state, colored by
/// the status (green connected / orange connecting / gray disconnected / red
/// error). Mirrors the Agents page's `AgentStatusPill`.
struct ChannelStatusPill: View {
    let status: ChannelConnectionStatus

    var body: some View {
        Text(status.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(status.tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(status.tint.opacity(0.14), in: Capsule())
            .fixedSize(horizontal: true, vertical: false)
    }
}

/// Circular brand-tinted avatar for a channel type (rhymes with `AgentAvatar`).
struct ChannelTypeAvatar: View {
    let type: ChannelType
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: type.icon)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(type.tint)
            .frame(width: size, height: size)
            .background(type.tint.opacity(0.16), in: Circle())
            .overlay(Circle().strokeBorder(type.tint.opacity(0.32), lineWidth: 1))
    }
}
