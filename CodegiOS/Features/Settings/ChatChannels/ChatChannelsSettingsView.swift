import SwiftUI

/// Chat channels: a list (channel ⨝ live status) where each row pushes a detail
/// for connect/test/logs, plus a "+" to add one and a row into the global message
/// settings (command prefix, language, event filter, webhooks).
struct ChatChannelsSettingsView: View {
    let client: CodegClient?
    @StateObject private var model: ChatChannelsSettingsModel
    @State private var pendingDelete: ChatChannelInfo?
    @State private var sheetRoute: SheetRoute?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// The three modals this screen presents, routed through ONE `.sheet(item:)`.
    ///
    /// Not three separate presentations, and never a `navigationDestination`:
    /// on iOS 16 a view only honors the **last** `.sheet` attached to it, and
    /// `navigationDestination(isPresented:)` — which this page used for the
    /// channel detail — is unreliable before 16.4 (the channel detail never
    /// pushed; every row tap hung on 16.1.2, across a view-driven
    /// `NavigationLink`, two isPresented destinations, and a List rebuild).
    /// A single routed sheet is the shape that works here, matching the other
    /// settings pages (Experts / Skills / MCP), which present their details the
    /// same way and have never hung.
    private enum SheetRoute: Identifiable {
        case globalSettings
        case addChannel
        case channelDetail(ChatChannelInfo)

        var id: String {
            switch self {
            case .globalSettings: "global-settings"
            case .addChannel: "add-channel"
            case .channelDetail(let channel): "channel-\(channel.id)"
            }
        }
    }

    init(client: CodegClient?) {
        self.client = client
        _model = StateObject(wrappedValue: ChatChannelsSettingsModel(client: client))
    }

    var body: some View {
        ZStack {
            CodegBackground()
            content
        }
        // A standard large title (matches Experts / Skills / Agents / Model
        // Providers): big at the top on compact, collapsing to a centered inline
        // title as the list scrolls. iPad keeps the system default.
        .navigationTitle("Chat Channels")
        .navigationBarTitleDisplayMode(horizontalSizeClass == .compact ? .large : .automatic)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { sheetRoute = .addChannel } label: { Image(systemName: "plus") }
                    .tint(Theme.accent)
                    .accessibilityLabel("Add Channel")
            }
        }
        .sheet(item: $sheetRoute) { route in
            switch route {
            case .globalSettings:
                NavigationStack {
                    ChatGlobalSettingsView(client: client)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { sheetRoute = nil }
                            }
                        }
                }
            case .addChannel:
                ChatChannelEditorSheet(editing: nil, client: client) { name, type, configJson, enabled, daily, dailyTime, token in
                    try await model.create(name: name, type: type, configJson: configJson, enabled: enabled, dailyReportEnabled: daily, dailyReportTime: dailyTime, token: token)
                } onUpdate: { _, _ in }
            case .channelDetail(let channel):
                // A sheet, not a push: `ChatChannelDetailView` also carries its own
                // sheets (edit / QR), which nest fine inside a presented sheet.
                NavigationStack {
                    ChatChannelDetailView(channel: channel, client: client) {
                        Task { await model.load() }
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { sheetRoute = nil }
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete Channel",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
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
        switch model.phase {
        case .loading where model.channels.isEmpty:
            LoadingView(label: "Loading channels…")
        case .failed(let message) where model.channels.isEmpty:
            InlineErrorView(message: message) { Task { await model.load() } }
        default:
            channelList
        }
    }

    /// A `List` (not a `ScrollView` + `LazyVStack`) so the row `contextMenu` is a
    /// standard `List` affordance rather than a gesture fighting the scroll view.
    private var channelList: some View {
        List {
            if let error = model.refreshError {
                RefreshErrorBanner(
                    message: error,
                    retry: { Task { await model.load() } },
                    dismiss: { model.refreshError = nil }
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: Theme.Layout.screenHMargin, bottom: 8, trailing: Theme.Layout.screenHMargin))
            }
            if model.channels.isEmpty {
                EmptyStateView(
                    icon: "bell.badge.fill",
                    title: "No Chat Channels",
                    message: "Connect Telegram, Lark, or WeChat to get notified and chat with your agents.",
                    actionTitle: "Add Channel",
                    action: { sheetRoute = .addChannel }
                )
                .frame(maxWidth: .infinity, alignment: .center)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: Theme.Layout.screenHMargin, bottom: 8, trailing: Theme.Layout.screenHMargin))
            } else {
                ForEach(model.channels) { channel in
                    ChannelRow(
                        channel: channel,
                        status: model.status(for: channel),
                        model: model,
                        onOpen: { sheetRoute = .channelDetail(channel) }
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 5, leading: Theme.Layout.screenHMargin, bottom: 5, trailing: Theme.Layout.screenHMargin))
                    .contextMenu {
                        Button(role: .destructive) { pendingDelete = channel } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            generalSection
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 14, leading: Theme.Layout.screenHMargin, bottom: 8, trailing: Theme.Layout.screenHMargin))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await model.load() }
    }

    /// The cross-channel "Message Settings" entry, set apart from the channel
    /// cards under its own header so it doesn't read as just another channel.
    /// Tap routes through `sheetRoute` (see `SheetRoute`).
    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("GENERAL")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
                .tracking(0.5)
                .padding(.leading, 4)
            Button {
                sheetRoute = .globalSettings
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
}

/// One channel card: type avatar, name + live status pill, the config summary
/// (and daily-report time when set), a chevron, and an instant enable toggle.
/// Tapping the content (not the toggle) opens the detail.
private struct ChannelRow: View {
    let channel: ChatChannelInfo
    let status: ChannelConnectionStatus
    @ObservedObject var model: ChatChannelsSettingsModel
    let onOpen: () -> Void

    private var configSummary: String {
        ChannelConfig.parse(channel.configJson).summary(type: channel.channelType)
    }

    var body: some View {
        GlassCard(cornerRadius: Theme.Radius.md, padding: 12) {
            HStack(spacing: 12) {
                Button(action: onOpen) {
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
