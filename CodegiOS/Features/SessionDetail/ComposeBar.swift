import SwiftUI
import PhotosUI

/// The pinned bottom compose bar. A leading "+" sits to the left of a growing
/// multiline field; a send button (which becomes Stop while a turn streams) sits
/// on the right. Attached-image thumbnails appear above the field. The "agent is
/// working" state is shown as a node at the tail of the transcript timeline (a
/// thinking tick, a running tool, a streaming reply) — not as a status line here.
///
/// The "+" owns the attachment pickers (Photo Library / Camera / Files) because
/// `PhotosPicker` / `.fileImporter` must be hosted on a view in the bar. (The
/// agent avatar lives in the session's navigation bar, not here.)
struct ComposeBar: View {
    @Binding var text: String
    let isInFlight: Bool
    let notice: String?
    let attachments: [Attachment]
    let canAttachMore: Bool
    let onAddAttachments: ([Attachment]) -> Void
    let onRemoveAttachment: (UUID) -> Void
    let onNotice: (String) -> Void
    let onSend: () -> Void
    let onStop: () -> Void
    let onDismissNotice: () -> Void
    /// Backs the "+" menu's text-insert pickers (quick messages / experts / commands).
    let insertModel: ComposeInsertModel

    @FocusState private var focused: Bool
    /// Bumped on each send tap to fire a light "sent" impact immediately (rather
    /// than waiting for the turn to start streaming).
    @State private var sendHaptic = 0
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var showCamera = false
    @State private var presentedInsert: ComposeInsertModel.Source?
    /// The "+" dropdown. Drawn in our own hierarchy rather than with a native
    /// `Menu`: on iOS 16 presenting a `Menu` corrupts SwiftUI's keyboard avoidance
    /// for the whole screen (measured on device: the transcript's slot loses ~190pt
    /// while the keyboard is up, and keeps ~340pt reserved after the keyboard is
    /// dismissed — the blank strip above the compose bar), and that inset is
    /// applied above this screen, so it can't be corrected from here.
    @State private var showAddMenu = false
    /// Measured height of the panel, so it can be parked above the row whatever the
    /// field's line count does.
    @State private var addMenuHeight: CGFloat = 0

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var canSend: Bool {
        (hasText || !attachments.isEmpty) && !isInFlight
    }
    private var remainingSlots: Int {
        max(0, AttachmentPrep.maxCount - attachments.count)
    }

    var body: some View {
        VStack(spacing: 8) {
            if let notice {
                NoticeBanner(message: notice, onDismiss: onDismissNotice)
            }

            if !attachments.isEmpty {
                AttachmentChipsView(attachments: attachments, onRemove: onRemoveAttachment)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            HStack(alignment: .bottom, spacing: 8) {
                addButton
                TextField("Message", text: $text, axis: .vertical)
                    .textInputAutocapitalization(.sentences)
                    .lineLimit(1...6)
                    // Match the transcript body so the text you type reads at
                    // the same size as the reply it produces (was `.callout`,
                    // visibly smaller than the messages).
                    .font(Theme.Typography.messageBody)
                    .foregroundStyle(Theme.textPrimary)
                    .tint(Theme.accent)
                    .focused($focused)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    // `xl` radius clamps to a capsule while the field is one
                    // line (rhyming with the round +/send buttons) and relaxes
                    // to a rounded rect as it grows — no hard switch needed.
                    .codegGlassEffect(in: RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
                    .hairlineBorder(Theme.Radius.xl)

                actionButton
            }
            // Anchor the panel to the row's *top*, parked above it by its own
            // measured height — so it clears the field whatever the line count does,
            // and keeps the same gap with or without the keyboard.
            .overlay(alignment: .topLeading) {
                if showAddMenu {
                    addMenuPanel
                        .codegOnHeightChange { addMenuHeight = $0 }
                        .offset(y: -(addMenuHeight + 8))
                        .transition(.opacity)
                }
            }
        }
        // Idle, the bar floats as a narrower pill (36pt side margins) so it reads
        // as a compact resting affordance. Focusing the field (keyboard up) widens
        // it to the transcript's 16pt gutter, so typing gets the same width as the
        // messages it answers. The change animates with the focus transition below.
        .padding(.horizontal, focused ? 16 : 36)
        .padding(.top, 8)
        // Hosted in a bottom `safeAreaInset`. Keyboard DOWN: float a full
        // home-indicator inset (~34pt) above the edge; a small negative bottom
        // padding dips the idle bar lower while staying clear of the indicator
        // line. Keyboard UP: the inset rides just above the keyboard, so a positive
        // gap is required — the old negative pad tucked the bar *under* the
        // keyboard's top edge (part of it was obscured).
        .padding(.bottom, focused ? 8 : -10)
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $photoItems,
            maxSelectionCount: max(1, remainingSlots),
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: photoItems) { items in handlePhotoItems(items) }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in addCaptured(image) }
                .ignoresSafeArea()
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in handleFiles(result) }
        .sheet(item: $presentedInsert) { source in
            ComposeInsertSheet(source: source, model: insertModel) { transform in
                text = transform(text)
            }
        }
        .animation(Theme.Motion.expand, value: isInFlight)
        .animation(Theme.Motion.expand, value: notice)
        .animation(Theme.Motion.expand, value: attachments)
        // Tap-anywhere dismissal, the way a native menu behaves: the catcher sits
        // *behind* the bar and the panel but covers the screen, so tapping outside
        // closes the panel while the bar's own controls keep their taps.
        .background(alignment: .bottom) {
            if showAddMenu {
                Color.clear
                    .frame(width: 2000, height: 2000)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.snappy(duration: 0.15)) { showAddMenu = false }
                    }
            }
        }
        // Focusing the field means the user moved on — close the panel so it can't
        // float over the keyboard.
        .onChange(of: focused) { isFocused in
            if isFocused, showAddMenu {
                withAnimation(.snappy(duration: 0.15)) { showAddMenu = false }
            }
        }
        // No explicit focus animation: let the bar ride the system keyboard
        // animation (an own .snappy animation lagged the keyboard).
        .codegSensoryFeedback(.impact(style: .light), trigger: sendHaptic)
    }

    // MARK: - Buttons

    @ViewBuilder
    private var addButton: some View {
        // A plain Button + our own panel, not a native `Menu`: see `showAddMenu`.
        Button {
            withAnimation(.snappy(duration: 0.18)) { showAddMenu.toggle() }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.primary.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add or insert")
        .accessibilityExpanded(showAddMenu)
    }

    /// The dropdown shown above the "+".
    ///
    /// Order comes from `Source.displayOrder` rather than `allCases` (or its
    /// reverse), so it can't silently flip when a case is added or reordered.
    /// Rows keep a visible disabled state, which the previous version lost by
    /// styling them with `.plain` and no explicit colour.
    private var addMenuPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ComposeInsertModel.Source.displayOrder) { source in
                menuRow(source.title, source.systemImage) { presentedInsert = source }
            }
            Divider().overlay(Theme.hairline)
            menuRow("Files", "folder", enabled: canAttachMore) { showFileImporter = true }
            if isCameraAvailable {
                menuRow("Camera", "camera", enabled: canAttachMore) { showCamera = true }
            }
            menuRow("Photo Library", "photo.on.rectangle", enabled: canAttachMore) { showPhotoPicker = true }
        }
        // `minWidth` rather than a fixed width: long labels (or a larger Dynamic
        // Type size) grow the panel instead of being squeezed into an ellipsis.
        .frame(minWidth: 220, alignment: .leading)
        .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .stroke(Theme.surfaceStroke, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 16, y: 6)
        .accessibilityElement(children: .contain)
    }

    private func menuRow(
        _ title: LocalizedStringKey,
        _ icon: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.15)) { showAddMenu = false }
            action()
        } label: {
            HStack(spacing: 12) {
                Text(title).font(.subheadline)
                Spacer(minLength: 0)
                Image(systemName: icon).font(.subheadline)
            }
            .foregroundStyle(enabled ? Theme.textPrimary : Theme.textTertiary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    @ViewBuilder
    private var actionButton: some View {
        if isInFlight {
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Theme.danger))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .transition(.scale.combined(with: .opacity))
            .accessibilityLabel("Stop")
        } else {
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Theme.accent))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .opacity(canSend ? 1 : 0.5)
            .transition(.scale.combined(with: .opacity))
            .accessibilityLabel("Send")
        }
    }

    private func send() {
        guard canSend else { return }
        sendHaptic &+= 1
        onSend()
    }

    // MARK: - Attachment intake

    private func handlePhotoItems(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        let slots = remainingSlots
        let attempted = items.count
        Task { @MainActor in
            var prepared: [Attachment] = []
            for item in items.prefix(slots) {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                if let attachment = await Task.detached(priority: .userInitiated, operation: {
                    AttachmentPrep.make(fromImageData: data, name: "image")
                }).value {
                    prepared.append(attachment)
                }
            }
            // Notice first so the view model's more specific size/count notice (if
            // any) wins when it also drops some during add.
            if prepared.count < attempted { onNotice("Some images couldn't be added.") }
            if !prepared.isEmpty { onAddAttachments(prepared) }
            photoItems = []
        }
    }

    private func handleFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        let slots = remainingSlots
        let attempted = urls.count
        Task { @MainActor in
            var prepared: [Attachment] = []
            for url in urls.prefix(slots) {
                if let attachment = await Task.detached(priority: .userInitiated, operation: {
                    AttachmentPrep.make(fromFile: url)
                }).value {
                    prepared.append(attachment)
                }
            }
            if prepared.count < attempted { onNotice("Some images couldn't be added.") }
            if !prepared.isEmpty { onAddAttachments(prepared) }
        }
    }

    /// Camera capture is a single image and small enough to prep inline on the
    /// main actor (avoids sending a non-Sendable `UIImage` across a task boundary).
    private func addCaptured(_ image: UIImage) {
        guard remainingSlots > 0, let attachment = AttachmentPrep.make(from: image, name: "camera") else { return }
        onAddAttachments([attachment])
    }
}

/// A dismissible non-fatal notice (e.g. "a turn is already running").
private struct NoticeBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(message)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .codegGlassEffect(in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md, color: Theme.accent.opacity(0.35))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}
