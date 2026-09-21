import SwiftUI

/// The inline card for Grok's native `exit_plan_mode`. When the agent finishes
/// planning it BLOCKS on the user's decision, so this is pinned above the compose
/// bar with the plan and Grok's own three outcomes (mirroring its TUI approval
/// bar): approve and build, request changes, or abandon the plan.
///
/// Distinct from ``PermissionRequestCard``, which handles Claude's ExitPlanMode —
/// that arrives as an ordinary permission with an option list, while Grok's is its
/// own request with a fixed set of outcomes plus freeform revision notes.
///
/// Follows `AskQuestionCard`'s in-flight pattern: on success the backend's
/// `plan_approval_resolved` clears the pending state and unmounts this card, so
/// the controls stay disabled rather than flashing back on.
struct PlanApprovalCard: View {
    let pending: PendingPlanApproval
    /// Submit the decision. Returns true on success — the model then clears the
    /// card; false keeps it and re-enables the controls.
    let onAnswer: (PlanApprovalDecision, String?) async -> Bool

    @State private var submitting = false
    @State private var failed = false
    @State private var changesOpen = false
    @State private var feedback = ""
    /// Measured height of the rendered plan. A bare `ScrollView` always takes the
    /// full height offered, so a three-line plan would sit in a 320pt void; this
    /// lets the card shrink to the content and only scroll once it overflows.
    @State private var planHeight: CGFloat = 0

    private static let maxPlanHeight: CGFloat = 320

    private var plan: String { pending.planMarkdown.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var notes: String { feedback.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            planBody
            if changesOpen { notesField }
            if failed {
                Label("Couldn’t submit. Please try again.", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
            }
            actions
        }
        .padding(14)
        .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .hairlineBorder(Theme.Radius.lg)
        .shadow(color: .black.opacity(0.14), radius: 12, y: 3)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: Header / body

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checklist")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Plan ready for review")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Approve to start building, or send notes to have the plan revised.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
        }
    }

    /// An empty plan still opens the approval surface (the turn is blocked either
    /// way), so it gets an explicit notice instead of a blank card.
    @ViewBuilder private var planBody: some View {
        if plan.isEmpty {
            Text("The agent didn’t include a plan.")
                .font(.subheadline)
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView {
                MarkdownContent(raw: plan)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .codegOnHeightChange { planHeight = $0 }
            }
            .frame(height: min(max(planHeight, 1), Self.maxPlanHeight))
        }
    }

    private var notesField: some View {
        TextField("What should change?", text: $feedback, axis: .vertical)
            .font(.subheadline)
            .lineLimit(2...5)
            .padding(8)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            .hairlineBorder(Theme.Radius.sm)
            .disabled(submitting)
    }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    if changesOpen {
                        Task { await submit(.requestChanges, notes) }
                    } else {
                        withAnimation(Theme.Motion.expand) { changesOpen = true }
                    }
                } label: {
                    Text(changesOpen ? "Send Notes" : "Request Changes")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .foregroundStyle(Theme.textPrimary)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                }
                .buttonStyle(.plain)
                // Opening the notes field is free; sending them needs text.
                .disabled(submitting || (changesOpen && notes.isEmpty))

                Button { Task { await submit(.approve, nil) } } label: {
                    HStack(spacing: 6) {
                        if submitting { ProgressView().controlSize(.mini).tint(Theme.onAccent) }
                        Text("Approve & Build").font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .foregroundStyle(Theme.onAccent)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(submitting)
            }

            Button { Task { await submit(.abandon, nil) } } label: {
                Text("Abandon Plan")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(submitting)
        }
    }

    private func submit(_ decision: PlanApprovalDecision, _ feedback: String?) async {
        guard !submitting else { return }
        submitting = true
        failed = false
        let ok = await onAnswer(decision, feedback)
        if !ok {
            failed = true
            submitting = false
        }
    }
}
