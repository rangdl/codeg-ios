import Foundation

// Pure parsing for the historical (read-only) `ask_user_question` record in the
// transcript, ported from the web client's `ask-question.ts`. The tool input is
// the agent's raw `{ questions: [...] }`; the output is the companion's
// structured `{ answers, declined }` envelope (with a human-text fallback for
// hosts that persist `content` instead of `structuredContent`).

/// One question's answer as persisted: the user's raw picks (each entry is one
/// offered option label or a free-text "Other" answer). Partition with
/// `matchSelections`.
struct AskAnswer {
    let header: String
    let question: String
    let selected: [String]
}

struct AskOutcome {
    let declined: Bool
    let answers: [AskAnswer]
}

enum AskQuestionParse {

    /// The question set, shaped as `QuestionSpec` (synthetic ids when the input
    /// carries none). Tolerant of partial input — returns `[]` rather than
    /// throwing so callers fall back gracefully.
    ///
    /// Codex's `request_user_input(_async)` tool names the prompt `title` (not
    /// `question`) and Codex-acp may wrap the args as `{ arguments: { questions } }`;
    /// both shapes still describe a question and must parse, or the card would
    /// hide the very text the user was asked.
    static func parseInput(_ input: String?) -> [QuestionSpec] {
        guard let root = CompanionJSON.object(from: input),
              let questions = questionArray(in: root) else {
            return []
        }
        var out: [QuestionSpec] = []
        for (i, item) in questions.enumerated() {
            guard let q = item as? [String: Any] else { continue }
            let options = parseOptions(q["options"])
            let question = nonEmpty(q["question"]) ?? nonEmpty(q["title"])
                ?? nonEmpty(q["prompt"]) ?? ""
            if question.isEmpty && options.isEmpty { continue }      // empty noise
            let multi = (CompanionJSON.bool(q["multiSelect"]) == true)
                || (CompanionJSON.bool(q["multi_select"]) == true)
                || (CompanionJSON.bool(q["isMultiSelect"]) == true)
                || (CompanionJSON.bool(q["is_multi_select"]) == true)
            out.append(QuestionSpec(id: nonEmpty(q["id"]) ?? "q\(i)", question: question,
                                    header: nonEmpty(q["header"]) ?? "",
                                    multiSelect: multi, options: options))
        }
        return out
    }

    /// Locate the `questions` array, peeling the host wrapper codex-acp puts
    /// around MCP arguments (`{ server, tool, arguments: { questions } }`).
    private static func questionArray(in obj: [String: Any], depth: Int = 0) -> [Any]? {
        guard depth <= 3 else { return nil }
        if let arr = obj["questions"] as? [Any] { return arr }
        for key in ["arguments", "input", "params", "payload"] {
            if let child = obj[key] as? [String: Any],
               let arr = questionArray(in: child, depth: depth + 1) {
                return arr
            }
            if let s = obj[key] as? String, let child = ToolJSONFormat.parseObject(s),
               let arr = questionArray(in: child, depth: depth + 1) {
                return arr
            }
        }
        // A single-question object (`title`/`question` + `options`) is the same
        // ask without the `questions` wrapper.
        if (obj["title"] is String || obj["question"] is String), obj["options"] is [Any] {
            return [obj]
        }
        return nil
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
    }

    /// A result that means the ask itself never happened — codex rejected the
    /// tool arguments before any host question request. The history parser
    /// persists this text with `is_error = false`, so the card must recognize
    /// it here or it would render as an answered question with no selection.
    static func looksLikeFailure(_ output: String?) -> Bool {
        guard let output else { return false }
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return false }
        if text.hasPrefix("failed to parse function arguments") { return true }
        if text.contains("invalid type:") && text.contains("expected") { return true }
        return false
    }

    /// Reconstruct the answered / declined outcome from the persisted result.
    /// Structured `{ answers, declined }` envelope first (top-level or under
    /// `structuredContent`), then the companion's human-readable text. Returns
    /// nil when there's no output yet (call still in flight).
    static func parseOutcome(_ output: String?) -> AskOutcome? {
        guard let output, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        if let fromJSON = parseOutcomeJSON(output) { return fromJSON }

        if output.range(of: #"\bdismissed the question"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return AskOutcome(declined: true, answers: [])
        }
        if output.range(of: #"did not answer the questions"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return AskOutcome(declined: true, answers: [])
        }

        // Fallback text shape:
        //   "The user answered your question(s):\n1. [Header] Question\n   → a, b\n…"
        // A header line pushes an answer (selected empty); the following "→" line
        // fills its selection (split on ", ", lossy for a label with a comma — the
        // structured envelope keeps such labels intact).
        var answers: [AskAnswer] = []
        var hasCurrent = false
        let lines = output.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for line in lines {
            if let m = Rx.capture(line, #"^\s*\d+\.\s*\[([^\]]*)\]\s*(.*)$"#, groups: 2) {
                answers.append(AskAnswer(header: m[0].trimmingCharacters(in: .whitespaces),
                                         question: m[1].trimmingCharacters(in: .whitespaces),
                                         selected: []))
                hasCurrent = true
                continue
            }
            if hasCurrent, let m = Rx.capture(line, #"^\s*→\s*(.*)$"#, groups: 1) {
                let joined = m[0].trimmingCharacters(in: .whitespaces)
                let selected = (!joined.isEmpty && joined != noSelection) ? joined.components(separatedBy: ", ") : []
                let last = answers.count - 1
                answers[last] = AskAnswer(header: answers[last].header, question: answers[last].question, selected: selected)
                hasCurrent = false
            }
        }
        // No answer record at all: the output is some other text (e.g. a tool
        // failure), NOT an empty answered set. Returning nil keeps the card from
        // claiming "No selection" for a question that was never asked.
        return answers.isEmpty ? nil : AskOutcome(declined: false, answers: answers)
    }

    /// Partition raw picks into chosen offered-option labels (`selected`) and
    /// free-text "Other" answers (`other`), order-preserving.
    static func matchSelections(values: [String], optionLabels: [String]) -> (selected: [String], other: [String]) {
        let labels = Set(optionLabels.filter { !$0.isEmpty })
        var selected: [String] = []
        var other: [String] = []
        for raw in values {
            let value = raw.trimmingCharacters(in: .whitespaces)
            if value.isEmpty || value == noSelection { continue }
            if labels.contains(value) { selected.append(value) } else { other.append(value) }
        }
        return (selected, other)
    }

    /// Strip a trailing " (Recommended)" so it can render as a badge while the
    /// value keeps the agent's original label.
    static func splitRecommended(_ label: String) -> (text: String, recommended: Bool) {
        if let m = Rx.capture(label, #"^(.*?)\s*\(recommended\)\s*$"#, groups: 1, caseInsensitive: true) {
            let text = m[0].trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return (text, true) }
        }
        return (label, false)
    }

    // MARK: helpers

    /// The companion's marker for an answered-but-empty selection (English, not localized).
    private static let noSelection = "(no selection)"

    private static func parseOptions(_ raw: Any?) -> [QuestionOption] {
        guard let arr = raw as? [Any] else { return [] }
        return arr.compactMap { item in
            if let s = item as? String {
                let label = s.trimmingCharacters(in: .whitespaces)
                return label.isEmpty ? nil : QuestionOption(label: label, description: "")
            }
            guard let o = item as? [String: Any], let label = o["label"] as? String, !label.isEmpty else { return nil }
            return QuestionOption(label: label, description: (o["description"] as? String) ?? "")
        }
    }

    private static func parseOutcomeJSON(_ output: String) -> AskOutcome? {
        guard let top = ToolJSONFormat.parseObject(output) else { return nil }
        // Resolve an answer envelope from a record: the record itself when it
        // carries `answers`/`declined`, otherwise its `structuredContent`.
        func envelope(_ r: [String: Any]?) -> [String: Any]? {
            guard let r else { return nil }
            if (r["answers"] as? [Any]) != nil || CompanionJSON.bool(r["declined"]) != nil { return r }
            return r["structuredContent"] as? [String: Any]
        }
        // Prefer the bare top-level shape (Claude / the history parser) first, so a
        // valid top-level envelope is never shadowed by an unrelated `result` key.
        // codex's live ACP path wraps the MCP result as `{result, error}`, where
        // `result` is the CallToolResult — sometimes tagged again under an `Ok`
        // serde variant — so fall through those layers when the top level yields
        // nothing. Mirrors the web `ask-question.ts::parseOutcomeJson`.
        let result = top["result"] as? [String: Any]
        let resultOk = result.flatMap { ($0["Ok"] as? [String: Any]) ?? ($0["ok"] as? [String: Any]) }
        guard let env = envelope(top) ?? envelope(result) ?? envelope(resultOk) else { return nil }
        let hasAnswers = (env["answers"] as? [Any]) != nil
        let declined = CompanionJSON.bool(env["declined"])
        if !hasAnswers && declined == nil { return nil }
        if declined == true { return AskOutcome(declined: true, answers: []) }
        return AskOutcome(declined: false, answers: parseAnswers(env["answers"]))
    }

    private static func parseAnswers(_ raw: Any?) -> [AskAnswer] {
        guard let arr = raw as? [Any] else { return [] }
        return arr.compactMap { item in
            guard let o = item as? [String: Any] else { return nil }
            let selected = (o["selected"] as? [Any])?.compactMap { $0 as? String } ?? []
            return AskAnswer(header: (o["header"] as? String) ?? "",
                             question: (o["question"] as? String) ?? "",
                             selected: selected)
        }
    }
}
