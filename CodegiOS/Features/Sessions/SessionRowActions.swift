import SwiftUI

/// What a Chats row's context menu can do beyond pinning: the server its
/// sheets talk to, and how a confirmed move is run (the list's model does it,
/// and tells the outcome).
struct SessionRowActions {
    let client: CodegClient
    /// Move the conversation to the folder, named by the label.
    let move: (ConversationSummary, FolderDetail, String) -> Void
}

/// The sheets a Chats row's context menu opens. Each host that shows
/// interactive rows presents them itself — the list, and the full-screen group
/// it zooms into: a cover can't have its presenter put a sheet over it.
struct SessionRowSheets: ViewModifier {
    let actions: SessionRowActions?
    /// The conversation whose tags are being edited.
    @Binding var tagging: ConversationSummary?
    /// The conversation whose "Move to…" is open.
    @Binding var moving: ConversationSummary?

    func body(content: Content) -> some View {
        // iOS 16 keeps only the LAST `.sheet` on a view, so both presentations
        // route through one modifier and one enum.
        content.sheet(item: route) { route in
            if let actions {
                switch route {
                case .tags(let conversation):
                    TagPickerSheet(conversation: conversation, client: actions.client)
                case .move(let conversation):
                    MoveConversationSheet(conversation: conversation, client: actions.client) { folder, label in
                        actions.move(conversation, folder, label)
                    }
                }
            }
        }
    }

    /// Whichever sheet the row asked for, in one value.
    private var route: Binding<RowSheetRoute?> {
        Binding(
            get: {
                if let tagging { return .tags(tagging) }
                if let moving { return .move(moving) }
                return nil
            },
            set: { newValue in
                switch newValue {
                case .tags(let c): tagging = c; moving = nil
                case .move(let c): moving = c; tagging = nil
                case nil: tagging = nil; moving = nil
                }
            }
        )
    }
}

/// The two sheets a conversation row can open.
private enum RowSheetRoute: Identifiable {
    case tags(ConversationSummary)
    case move(ConversationSummary)

    var id: String {
        switch self {
        case .tags(let c): return "tags-\(c.id)"
        case .move(let c): return "move-\(c.id)"
        }
    }
}

/// How long a ``SwiftUI/View/transientNotice(_:dismiss:)`` stays up.
enum TransientNotice {
    /// A few seconds; longer for one with more to read — a move of several
    /// that left some behind says how many and why, on a second line.
    static func duration(for message: String) -> Duration {
        message.contains("\n") || message.count > 80 ? .seconds(7) : .seconds(4)
    }
}

extension View {
    func sessionRowSheets(_ actions: SessionRowActions?, tagging: Binding<ConversationSummary?>,
                          moving: Binding<ConversationSummary?>) -> some View {
        modifier(SessionRowSheets(actions: actions, tagging: tagging, moving: moving))
    }

    /// A one-line notice floating at the bottom for a few seconds (a move's
    /// outcome), cleared through `dismiss` when its time is up.
    func transientNotice(_ message: String?, dismiss: @escaping () -> Void) -> some View {
        overlay(alignment: .bottom) {
            if let message {
                Text(message)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .codegGlassEffect(tint: Theme.accent.opacity(0.18), in: Capsule())
                    .padding(.horizontal, 24)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture(perform: dismiss)
                    .task(id: message) {
                        try? await Task.sleep(for: TransientNotice.duration(for: message))
                        if !Task.isCancelled { dismiss() }
                    }
            }
        }
        .animation(.snappy(duration: 0.25), value: message)
    }
}
