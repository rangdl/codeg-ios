import SwiftUI

// Read-only, in-stream rendering of an `ask_user_question` tool call (historical
// transcript + the in-flight marker). Mirrors web `ask-question-result-card.tsx`:
// the answered / declined record collapses into a capsule summarizing the picks,
// expanding to the live `AskQuestionCard` in its read-only mode so the Q&A layout
// matches exactly. Error / in-flight states fall back to a compact header card.

/// Pre-filled selection for a read-only `AskQuestionCard` question: the chosen
/// option labels plus any free-text "Other" answer.
struct AskQuestionSelection {
    var chosen: [String]
    var otherText: String
}

struct AskQuestionResultCard: View {
    let vm: ToolCallVM
    @State private var expanded = false

    var body: some View {
        let questions = AskQuestionParse.parseInput(vm.input)
        let outcome = AskQuestionParse.parseOutcome(vm.output)
        // Codex's argument-parse failures are persisted with `is_error = false`,
        // so the text itself has to mark the ask as failed. Otherwise the card
        // reads as an answered question with no selection and hides both the
        // prompt and the failure.
        let failedOutput = AskQuestionParse.looksLikeFailure(vm.output)
        let isError = vm.isError || vm.state == .error || failedOutput
        let isRunning = vm.state == .running || vm.state == .inputStreaming
        let inFlight = !isError && outcome == nil && isRunning

        if isError {
            failure(questions: questions)
        } else if inFlight {
            shell(subtitle: "Waiting for your answer…") {
                if !questions.isEmpty {
                    chips(questions.map { $0.header.isEmpty ? $0.question : $0.header })
                }
            }
        } else if questions.isEmpty {
            answersOnly(outcome)
        } else {
            answered(questions: questions, outcome: outcome)
        }
    }

    // MARK: Answered / declined

    private func answered(questions: [QuestionSpec], outcome: AskOutcome?) -> some View {
        let declined = outcome?.declined ?? false
        let picks = (outcome?.answers ?? []).flatMap { $0.selected }.filter { !$0.isEmpty }
        let summary = declined
            ? String(localized: "Declined")
            : (picks.isEmpty ? String(localized: "No selection") : picks.joined(separator: ", "))

        return VStack(alignment: .leading, spacing: 8) {
            capsule(summary: summary)
            if expanded {
                AskQuestionCard(
                    pending: PendingQuestion(questionId: "result", questions: questions),
                    onAnswer: { _ in false },
                    readOnly: true,
                    initialSelections: selections(questions: questions, outcome: outcome),
                    titleOverride: "Question",
                    subtitleOverride: declined ? "Declined" : nil
                )
                // The card seeds its selection @State in `init` only; force a fresh
                // identity (and re-seed) if the answered content changes under a
                // reused node (e.g. the live→persisted handoff at the same tool id).
                .id("ask-\(vm.id)-\(declined ? "declined" : picks.joined(separator: "\u{1f}"))")
            }
        }
    }

    private func capsule(summary: String) -> some View {
        Button {
            withAnimation(Theme.Motion.expand) { expanded.toggle() }
        } label: {
            // No leading question-bubble icon — the timeline gutter marker already
            // shows it for this node.
            HStack(spacing: 8) {
                (Text("Answered:").foregroundColor(Theme.textTertiary)
                    + Text(verbatim: " " + summary).foregroundColor(Theme.textSecondary))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.3), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Match each question's persisted answer (by header+question signature) to a
    /// pre-filled selection for the read-only card.
    private func selections(questions: [QuestionSpec], outcome: AskOutcome?) -> [String: AskQuestionSelection] {
        guard let outcome, !outcome.declined else { return [:] }
        let sep = "\u{1f}"   // unit separator — never in agent text
        var bySig: [String: [String]] = [:]
        for a in outcome.answers { bySig[a.header + sep + a.question] = a.selected }
        var out: [String: AskQuestionSelection] = [:]
        for q in questions {
            let values = bySig[q.header + sep + q.question] ?? []
            let matched = AskQuestionParse.matchSelections(values: values, optionLabels: q.options.map { $0.label })
            out[q.id] = AskQuestionSelection(chosen: matched.selected, otherText: matched.other.joined(separator: ", "))
        }
        return out
    }

    // MARK: Fallbacks (input didn't parse, error, in-flight)

    /// The ask produced no answer: the tool call failed, or codex rejected its
    /// arguments before any question reached the host. Keep the prompt and its
    /// options visible and show the cause underneath — never an empty
    /// "answered" record.
    private func failure(questions: [QuestionSpec]) -> some View {
        shell(subtitle: nil) {
            VStack(alignment: .leading, spacing: 10) {
                if !questions.isEmpty {
                    questionPrompts(questions)
                } else if let raw = vm.input?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !raw.isEmpty {
                    // Parsing failed or the host used a shape we don't know yet.
                    // Never leave the card blank: show the raw ask so the prompt
                    // and its options stay readable.
                    rawBlock(raw)
                }
                Text(verbatim: (vm.output ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func rawBlock(_ text: String) -> some View {
        let cap = 4000
        let shown = text.count > cap ? String(text.prefix(cap)) + "…" : text
        return Text(verbatim: shown)
            .font(.caption2.monospaced())
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Compact, read-only prompt + option rows for the failure state. The live
    /// read-only `AskQuestionCard` would add a second card chrome here.
    private func questionPrompts(_ questions: [QuestionSpec]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(questions) { q in
                VStack(alignment: .leading, spacing: 4) {
                    if !q.header.isEmpty {
                        Text(verbatim: q.header)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    if !q.question.isEmpty {
                        Text(verbatim: q.question)
                            .font(.caption)
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(q.options.enumerated()), id: \.offset) { _, option in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: option.label)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Theme.textSecondary)
                            if !option.description.isEmpty {
                                Text(verbatim: option.description)
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Input didn't parse (e.g. a truncated transcript) but the result did — show
    /// the answers as chips so the record isn't lost.
    @ViewBuilder private func answersOnly(_ outcome: AskOutcome?) -> some View {
        let answers = outcome?.answers ?? []
        if answers.isEmpty {
            // Not an answer envelope — but if there IS output, surface it rather
            // than returning an invisible empty card (the reported "I can't see
            // the question at all" shape).
            let text = (vm.output ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                shell(subtitle: nil) {
                    Text(verbatim: text)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            shell(subtitle: (outcome?.declined ?? false) ? "Declined" : nil) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(answers.enumerated()), id: \.offset) { _, a in
                        VStack(alignment: .leading, spacing: 4) {
                            if !a.question.isEmpty {
                                Text(verbatim: a.question)
                                    .font(.caption).foregroundStyle(Theme.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            let labels = a.selected.filter { !$0.isEmpty }
                            if labels.isEmpty {
                                Text("No selection").font(.caption).foregroundStyle(Theme.textTertiary)
                            } else {
                                chips(labels)
                            }
                        }
                    }
                }
            }
        }
    }

    private func shell<Content: View>(subtitle: LocalizedStringKey?, @ViewBuilder content: () -> Content) -> some View {
        let isError = vm.isError || vm.state == .error
        return VStack(alignment: .leading, spacing: 8) {
            // The gutter marker carries the question-bubble icon for this node, so
            // the card header leads with just the title.
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Question")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer(minLength: 4)
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md, color: isError ? Theme.danger.opacity(0.4) : Theme.accent.opacity(0.3))
    }

    private func chips(_ labels: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                    Text(verbatim: label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
            }
        }
    }
}
