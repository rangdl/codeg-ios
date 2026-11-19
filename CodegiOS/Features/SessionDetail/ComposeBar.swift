import SwiftUI
import PhotosUI
import UIKit

/// The pinned bottom compose bar. A leading "+" sits to the left of a growing
/// multiline field; a send button sits on the right. While a turn streams it
/// becomes Stop — joined, once something is typed, by a send that QUEUES the
/// message for when the agent is free, and whose long-press sends it into the
/// running turn instead (when the session has a live-feedback channel).
/// Attached-image thumbnails appear above the field. The "agent is
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
    /// False only when the live session has positively said it takes images in
    /// neither encoding — then the Attach section is dropped rather than shown
    /// permanently disabled, since for that agent there is nothing to enable.
    /// True (the default) whenever capabilities are still unknown.
    let canAttachImages: Bool
    let onAddAttachments: ([Attachment]) -> Void
    let onRemoveAttachment: (UUID) -> Void
    let onNotice: (String) -> Void
    let onSend: () -> Void
    let onStop: () -> Void
    let onDismissNotice: () -> Void
    /// Backs the "+" menu's text-insert pickers (quick messages / experts / commands).
    @ObservedObject var insertModel: ComposeInsertModel
    /// Backs the "+" menu's References picker (files / agents / assistants /
    /// sessions / commits). Owned by the view model so its four loaders can be
    /// wired to this conversation's client and folder.
    @ObservedObject var mentionModel: MentionInsertModel
    /// The session can take a message into the running turn right now, and
    /// over which channel — the long-press offer's wording follows it, so a
    /// pull session never promises an instant insert.
    var canSteer: Bool = false
    var steerChannel: SteerChannel = .pull
    /// A steer is on its way; the mid-turn send waits for it.
    var isSteering: Bool = false
    var onSteer: () -> Void = {}
    /// The prompt the agent predicts comes next, offered as the empty field's
    /// placeholder; "Use" (or a bare hardware Tab) fills it in — never sends.
    var suggestion: String? = nil
    var onUseSuggestion: () -> Void = {}
    /// Backs the inline `/`·`$` command menu and `@` mention panel shown above
    /// the field. Nil turns both off.
    var suggestions: ComposerSuggestionModel? = nil

    /// Plain `Bool`, not `@FocusState`: the field is a `UIViewRepresentable`, and
    /// `.focused(_:)` never reaches it — the flag stayed false forever, so the
    /// `/`·`@` panel never opened and the bar's focus padding never settled.
    /// `ComposerTextView` writes it back on begin/end editing.
    @State private var focused = false
    /// Bumped when the suggestion is taken, for its selection tick.
    @State private var suggestionHaptic = 0
    /// The field's caret as a UTF-16 offset, read for the inline triggers and
    /// set to put the caret after an inserted suggestion. iOS 16 has no
    /// `TextField(selection:)`, so `ComposerTextView` reports it.
    @State private var caretUTF16: Int? = nil
    /// Height of the text field, measured by `ComposerTextView` from the real
    /// content and pinned with `.frame(height:)`. Driving it from state (not
    /// `sizeThatFits`) is what stops the per-keystroke bounce — see the wrapper.
    @State private var fieldHeight: CGFloat = 0
    /// A text swap requested by a picked suggestion, applied by the text view.
    @State private var pendingText: String? = nil
    @State private var pendingCaret: Int? = nil
    /// Bumped on each suggestion pick, for a selection tick.
    @State private var pickTick = 0
    /// References already staged in the draft, by uri: the picker marks them and
    /// refuses a second copy (a reference is context; pointing at the same file
    /// twice adds nothing).
    @State private var stagedReferenceURIs: Set<String> = []
    /// Bumped on each send tap to fire a light "sent" impact immediately (rather
    /// than waiting for the turn to start streaming).
    @State private var sendHaptic = 0
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var showCamera = false
    @State private var presentedInsert: ComposeInsertModel.Source?

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var hasContent: Bool {
        hasText || !attachments.isEmpty
    }
    /// Images ride only one of the two live-feedback wires, so a draft carrying
    /// them is queued whole instead.
    private var canSteerDraft: Bool {
        canSteer && hasText && attachments.isEmpty && !isSteering
    }
    private var remainingSlots: Int {
        max(0, AttachmentPrep.maxCount - attachments.count)
    }
    /// The suggestion, only while the field it would fill is empty.
    private var offeredSuggestion: String? {
        PromptSuggestionGate.offered(suggestion, draft: text, hasAttachments: !attachments.isEmpty,
                                     inFlight: isInFlight, steering: isSteering, queueEmpty: true)
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

            if let suggestions {
                // A dedicated `@ObservedObject` host, so the panel redraws the
                // instant the model's `trigger` changes. Reading `suggestions.panel`
                // directly here did NOT subscribe to the model (it was a bare
                // `var`), so a freshly-typed `/` or `@` only showed up a keystroke
                // later — when some unrelated state (the text binding) happened to
                // redraw the bar.
                ComposerSuggestionPanelHost(
                    model: suggestions,
                    onPick: { pickSuggestion($0, from: suggestions) }
                )
            }

            // iOS 26's `GlassEffectContainer` groups glass shapes so they blend;
            // on 16 the shapes are flat fills, so a plain container is equivalent.
            Group {
                HStack(alignment: .bottom, spacing: 8) {
                    addButton
                    ComposerTextView(text: $text,
                                     caret: $caretUTF16,
                                     pendingText: $pendingText,
                                     pendingCaret: $pendingCaret,
                                     isFocused: $focused,
                                     font: UIFont.preferredFont(forTextStyle: .body),
                                     lineLimit: offeredSuggestion == nil ? 1...6 : 1...2,
                                     measuredHeight: $fieldHeight,
                                     onEdit: { newText, newCaret, isFocused in
                                         suggestions?.update(text: newText, caretUTF16: newCaret, focused: isFocused)
                                     })
                        // Pin height right on the representable: its `sizeThatFits`
                        // proposal already has the outer paddings subtracted, so the
                        // measured width matches the rendered width.
                        .frame(height: fieldHeight > 0 ? fieldHeight : nil)
                        .foregroundStyle(Theme.textPrimary)
                        .tint(Theme.accent)
                        .padding(.horizontal, 16)
                        .padding(.trailing, offeredSuggestion == nil ? 0 : 44)
                        .padding(.vertical, 10)
                        .overlay(alignment: .trailing) {
                            if offeredSuggestion != nil { useSuggestionButton }
                        }
                        // `xl` radius clamps to a capsule while the field is one
                        // line (rhyming with the round +/send buttons) and relaxes
                        // to a rounded rect as it grows — no hard switch needed.
                        .codegGlassEffect(in: RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
                        .hairlineBorder(Theme.Radius.xl)

                    actionButton
                }
            }
        }
        // Fixed side gutter. Upstream narrowed the idle bar to 36pt and widened it
        // to 16pt on focus, but that slides the whole row — the "+" and the send
        // button jump sideways every time focus toggles, and any focus flicker
        // turns into visible drift. A constant gutter keeps both pinned; the
        // field absorbs the width on its own.
        .padding(.horizontal, 16)
        .padding(.top, 8)
        // Hosted in a bottom `safeAreaInset`. A constant bottom gap keeps the bar
        // (and both its buttons) from bobbing vertically when focus toggles —
        // upstream varied it per focus state, which combined with the focus
        // animation to make the row visibly drift while typing.
        .padding(.bottom, 8)
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
            if source == .references {
                MentionInsertSheet(model: mentionModel,
                                   insertedURIs: stagedReferenceURIs) { reference in
                    insert(reference)
                }
            } else {
                ComposeInsertSheet(source: source, model: insertModel) { transform in
                    text = transform(text)
                }
            }
        }
        .animation(Theme.Motion.expand, value: isInFlight)
        .animation(Theme.Motion.expand, value: hasContent)
        .animation(Theme.Motion.expand, value: notice)
        .animation(Theme.Motion.expand, value: attachments)
        // No `.animation(value: focused)`: the bar's geometry no longer depends on
        // focus, and animating on it only let a focus flicker ripple the layout.
        .codegSensoryFeedback(.lightImpact, trigger: sendHaptic)
        .codegSensoryFeedback(.selection, trigger: suggestionHaptic)
        // The inline `/`·`$`·`@` triggers are driven by `ComposerTextView.onEdit`,
        // which reports live text + caret + focus in one callback. A focus change
        // still re-evaluates here, for when focus is toggled from outside the field.
        .onChange(of: focused) { _ in refreshSuggestions() }
        .animation(Theme.Motion.expand, value: suggestions?.panel != nil)
        .codegSensoryFeedback(.selection, trigger: pickTick)
    }

    /// "Use" inside the field, while the predicted prompt is its placeholder.
    private var useSuggestionButton: some View {
        Button(action: useSuggestion) {
            Text("Use")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Theme.accent.opacity(0.14), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.trailing, 8)
        .accessibilityLabel("Use suggested message")
        .transition(.opacity)
    }

    private func useSuggestion() {
        guard offeredSuggestion != nil else { return }
        suggestionHaptic &+= 1
        onUseSuggestion()
    }

    // MARK: - Inline suggestions

    /// Report text + caret to the suggestion model.
    private func refreshSuggestions() {
        suggestions?.update(text: text, caretUTF16: caretUTF16, focused: focused)
    }

    private func pickSuggestion(_ row: ComposerSuggestionRow, from model: ComposerSuggestionModel) {
        guard let result = model.pick(row, in: text) else { return }
        replaceText(result.text, caretUTF16: result.caret)
    }


    /// Swap in the edited text, then put the caret after the insertion on the
    /// next runloop — set together, the field would apply the text change after
    /// the selection and drop it.
    /// Stage one reference: append its Markdown to the draft and remember the
    /// uri so the picker can mark it.
    private func insert(_ reference: MentionReference) {
        guard !stagedReferenceURIs.contains(reference.uri) else { return }
        stagedReferenceURIs.insert(reference.uri)
        let spacer = text.isEmpty || text.hasSuffix(" ") || text.hasSuffix("\n") ? "" : " "
        replaceText(text + spacer + reference.markdown + " ", caretUTF16: (text + spacer + reference.markdown + " ").utf16.count)
    }

    private func replaceText(_ newText: String, caretUTF16: Int) {
        pickTick &+= 1
        text = newText
        pendingText = newText
        pendingCaret = caretUTF16
    }

    // MARK: - Buttons

    @ViewBuilder
    private var addButton: some View {
        Menu {
            // Attach images. Disabled per-item when the attachment budget is full,
            // so the insert actions below stay reachable.
            if canAttachImages {
                Section("Attach") {
                    Button { showPhotoPicker = true } label: {
                        Label("Photo Library", systemImage: "photo.on.rectangle")
                    }
                    .disabled(!canAttachMore)
                    if isCameraAvailable {
                        Button { showCamera = true } label: {
                            Label("Camera", systemImage: "camera")
                        }
                        .disabled(!canAttachMore)
                    }
                    Button { showFileImporter = true } label: {
                        Label("Files", systemImage: "folder")
                    }
                    .disabled(!canAttachMore)
                }
            }
            // Insert text: quick messages, expert mentions, slash commands.
            Section("Insert") {
                ForEach(ComposeInsertModel.Source.allCases) { source in
                    Button { presentedInsert = source } label: {
                        Label(source.title, systemImage: source.systemImage)
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 26, height: 26)
        }
        .codegGlassButtonStyle()
        .clipShape(Circle())
        .tint(Theme.textSecondary)
        .accessibilityLabel("Add or insert")
    }

    @ViewBuilder
    private var actionButton: some View {
        if isInFlight {
            HStack(spacing: 8) {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 26, height: 26)
                }
                .codegGlassButtonStyle(prominent: true)
                .tint(Theme.danger)
                .clipShape(Circle())
                .accessibilityLabel("Stop")
                if hasContent {
                    queueButton
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .transition(.scale.combined(with: .opacity))
        } else {
            Button(action: send) {
                sendGlyph
            }
            .codegGlassButtonStyle(prominent: true)
            .tint(Theme.accent)
            .clipShape(Circle())
            .disabled(!hasContent)
            .opacity(hasContent ? 1 : 0.5)
            .transition(.scale.combined(with: .opacity))
            .accessibilityLabel("Send")
        }
    }

    private var sendGlyph: some View {
        Image(systemName: "arrow.up")
            .font(.system(size: 16, weight: .bold))
            .frame(width: 26, height: 26)
    }

    /// Mid-turn send: a tap queues the message (what sending has always meant
    /// while the agent works); a long-press offers to send it into the turn
    /// that is running instead — the bolt is the instant insert, the clock the
    /// note that waits for the agent's next check.
    @ViewBuilder
    private var queueButton: some View {
        if canSteerDraft {
            Menu {
                Button(action: steer) {
                    Label(steerChannel == .pull ? LocalizedStringKey("Send note for next check") : LocalizedStringKey("Insert into current turn"),
                          systemImage: steerChannel == .pull ? "clock" : "bolt.fill")
                }
                Button(action: send) {
                    Label("Queue message", systemImage: "text.line.last.and.arrowtriangle.forward")
                }
            } label: {
                sendGlyph
            } primaryAction: {
                send()
            }
            .codegGlassButtonStyle(prominent: true)
            .tint(Theme.accent)
            .clipShape(Circle())
            .accessibilityLabel("Queue message")
        } else {
            Button(action: send) {
                sendGlyph
            }
            .codegGlassButtonStyle(prominent: true)
            .tint(Theme.accent)
            .clipShape(Circle())
            .disabled(isSteering)
            .opacity(isSteering ? 0.5 : 1)
            .accessibilityLabel("Queue message")
        }
    }

    private func send() {
        guard hasContent, !isSteering else { return }
        sendHaptic &+= 1
        onSend()
    }

    private func steer() {
        guard canSteerDraft else { return }
        sendHaptic &+= 1
        onSteer()
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

/// Hosts the inline `/`·`$`·`@` panel and subscribes to the suggestion model, so
/// the panel redraws the moment `trigger` flips. Kept as its own `@ObservedObject`
/// view because `ComposeBar` receives the model as a bare `var` (optional), which
/// subscribes to nothing — the panel then only refreshed as a side effect of some
/// other state change, one keystroke late.
private struct ComposerSuggestionPanelHost: View {
    @ObservedObject var model: ComposerSuggestionModel
    let onPick: (ComposerSuggestionRow) -> Void

    var body: some View {
        if let panel = model.panel {
            ComposerSuggestionPanel(
                state: panel,
                onPick: onPick,
                onSelectTab: { model.selectTab($0) }
            )
        }
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


/// Whether the focused field holds an input method's marked text: pinyin,
/// kana or hangul still being composed. SwiftUI does not expose it, so this
/// asks the first responder, which is the field whenever a key reaches it.
@MainActor
enum TextInputComposition {
    static var isActive: Bool {
        (FirstResponder.current as? UITextInput)?.markedTextRange != nil
    }
}

@MainActor
private enum FirstResponder {
    static weak var found: UIResponder?

    /// An action sent to a nil target goes to the first responder, which
    /// reports itself.
    static var current: UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.codegReportFirstResponder(_:)),
                                        to: nil, from: nil, for: nil)
        let responder = found
        found = nil
        return responder
    }
}

extension UIResponder {
    @objc fileprivate func codegReportFirstResponder(_ sender: Any?) {
        FirstResponder.found = self
    }
}
