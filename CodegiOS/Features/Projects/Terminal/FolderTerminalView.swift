import SwiftUI

/// The folder detail's **Terminal** tab: a slim status/control strip over a
/// full-bleed native terminal, with connecting / exited / failed states. The
/// emulator view itself is owned by ``TerminalSession`` and merely re-hosted here
/// (see ``TerminalSurface``) so it survives switching between the detail's tabs.
struct FolderTerminalView: View {
    /// `@ObservedObject`, not a plain `let`: `TerminalSession` is an
    /// `ObservableObject` after the iOS 16 conversion, so a plain `let` subscribes
    /// to nothing and `body` never re-evaluates. `phase` then stays frozen at
    /// whatever it was on the first render (`.idle`/`.connecting`), which is why
    /// both the status strip and the full-screen overlay kept showing
    /// "Starting terminal…" even though the PTY was live — SwiftTerm renders
    /// through UIKit, so the terminal itself kept working and made the stuck
    /// spinner look like a connect problem. Upstream needs no wrapper: it is
    /// `@Observable`, where reading `phase` in `body` tracks automatically.
    /// Same conversion gap as 9be8b11 (`AgentOptionsSheet`).
    @ObservedObject var session: TerminalSession
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            controlStrip
            Divider().overlay(Theme.hairline)
            terminalArea
        }
        .task { session.start() }   // idempotent — lazy first start
    }

    // MARK: - Control strip

    private var controlStrip: some View {
        HStack(spacing: 14) {
            statusLabel
            Spacer(minLength: 8)
            Button { session.dismissKeyboard() } label: {
                Image(systemName: "keyboard.chevron.compact.down")
            }
            .tint(Theme.textSecondary)
            .accessibilityLabel("Hide Keyboard")
            Menu {
                Button { session.clear() } label: { Label("Clear", systemImage: "clear") }
                Button { session.restart() } label: { Label("Restart", systemImage: "arrow.clockwise") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .tint(Theme.accent)
            .accessibilityLabel("Terminal Actions")
        }
        .font(.body)
        .padding(.horizontal, Theme.Layout.screenHMargin)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch session.phase {
        case .idle, .connecting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Starting terminal…").foregroundStyle(Theme.textSecondary)
            }
            .font(.caption)
        case .running:
            HStack(spacing: 6) {
                Circle().fill(Theme.accent).frame(width: 7, height: 7)
                Text("Terminal").foregroundStyle(Theme.textSecondary)
            }
            .font(.caption)
        case .exited:
            HStack(spacing: 6) {
                Circle().fill(Theme.textTertiary).frame(width: 7, height: 7)
                Text("Exited").foregroundStyle(Theme.textTertiary)
            }
            .font(.caption)
        case .failed:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                Text("Failed").foregroundStyle(Theme.warning)
            }
            .font(.caption)
        }
    }

    // MARK: - Terminal area

    private var terminalArea: some View {
        ZStack {
            session.backgroundColor(dark: isDark)
                .ignoresSafeArea(.container, edges: .bottom)
            // Inset the emulator so glyphs don't sit flush against the screen edge.
            // The container fill behind it is the same palette color, so the inset
            // reads as interior padding rather than a border. (SwiftTerm recomputes
            // cols/rows for the smaller bounds, so text simply reflows.)
            TerminalSurface(session: session, dark: isDark)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            overlay
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var overlay: some View {
        switch session.phase {
        case .idle, .connecting:
            LoadingView(label: "Starting terminal…")
        case .exited:
            exitBanner(message: "Process exited", prominent: true)
        case .failed(let msg):
            exitBanner(message: LocalizedStringKey(stringLiteral: msg), prominent: true, isError: true)
        case .running:
            EmptyView()
        }
    }

    private func exitBanner(message: LocalizedStringKey, prominent: Bool, isError: Bool = false) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                if isError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                }
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(3)
                Spacer(minLength: 8)
                AccentPillButton(title: "Restart", systemImage: "arrow.clockwise", prominent: prominent) {
                    session.restart()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.hairline))
            .padding(.horizontal, Theme.Layout.screenHMargin)
            .padding(.bottom, 12)
        }
    }
}

// MARK: - Keep-alive UIKit bridge

/// Hosts ``TerminalSession/view`` without recreating it. SwiftUI rebuilds this
/// representable whenever the user flips folder-detail tabs, so `makeUIView`
/// returns a plain container and `updateUIView` re-parents the *same* retained
/// terminal view into it — preserving scrollback and the running PTY. The
/// emulator's own `layoutSubviews` recomputes cols/rows (no fit addon needed).
struct TerminalSurface: UIViewRepresentable {
    let session: TerminalSession
    let dark: Bool

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        let term = session.view
        if term.superview !== container {
            term.removeFromSuperview()
            term.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(term)
            NSLayoutConstraint.activate([
                term.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                term.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                term.topAnchor.constraint(equalTo: container.topAnchor),
                term.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        session.applyTheme(dark: dark)
    }
}
