import SwiftUI

/// One insertable reference for the composer's **References** picker.
///
/// A reference is inserted as **plain Markdown**, because that is exactly what
/// the web composer serializes before sending: the transcript badge and the
/// routing anchor (`codeg://agent/…`, `codeg://session/…`, `codeg://commit/…`)
/// are recovered from that text by the backend and by the transcript renderer.
/// The iOS composer is a plain `TextField`, so the Markdown *is* the wire format
/// — there is no badge node to build, and nothing has to travel out of band.
///
/// Ported from the web composer: the URIs and their meanings come from
/// `composer/suggestion/adapters.ts`, the serialization and its escaping from
/// `composer/reference-text.ts` + `lib/reference-link.ts`. The escaping is not
/// decorative — a file name may contain `[`, `)` or a space, and an unescaped
/// one would break out of the link it sits in.
struct MentionReference: Identifiable, Hashable, Sendable {
    /// Which picker group the reference came from. Case order is the panel's
    /// group order (files → agents → sessions → commits), matching the web.
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case files, agents, sessions, commits

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .files: return "Files"
            case .agents: return "Agents"
            case .sessions: return "Sessions"
            case .commits: return "Commits"
            }
        }

        var systemImage: String {
            switch self {
            case .files: return "doc"
            case .agents: return "person.2"
            case .sessions: return "bubble.left.and.bubble.right"
            case .commits: return "arrow.triangle.branch"
            }
        }
    }

    let kind: Kind
    /// Stable identity: the reference's uri. Also what the duplicate check keys
    /// on, and what `ForEach` uses — two rows for the same file can't coexist.
    let uri: String
    /// Link text: file name, agent name, session title, short hash.
    let label: String
    /// Secondary row text (relative path, agent description, commit subject).
    let detail: String?
    /// The exact text inserted into the draft.
    let markdown: String

    var id: String { uri }
}

// MARK: - Builders

extension MentionReference {
    /// A workspace file or directory. `path` is the workspace-relative path
    /// `list_workspace_files` returns; the uri carries the absolute path so the
    /// agent (and the transcript's file actions) can resolve it directly.
    static func file(root: String, path: String, name: String) -> MentionReference {
        let uri = fileURI(absolutePath: joinPath(root: root, relative: path))
        return MentionReference(
            kind: .files,
            uri: uri,
            label: name,
            detail: path,
            markdown: markdownLink(text: name, uri: uri)
        )
    }

    /// An ACP agent — `[@label](codeg://agent/<type>)`. The `@` lives *inside*
    /// the link text, where GFM cannot autolink it; the readable link doubles as
    /// the routing anchor the backend derives its delegation reminder from
    /// (web `agentToSuggestion`).
    static func agent(type: AgentType, name: String, description: String) -> MentionReference {
        let uri = "codeg://agent/\(type.wireValue)"
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = trimmedName.isEmpty ? type.displayName : trimmedName
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return MentionReference(
            kind: .agents,
            uri: uri,
            label: label,
            detail: trimmedDescription.isEmpty ? nil : trimmedDescription,
            markdown: markdownLink(text: "@\(label)", uri: uri)
        )
    }

    /// A conversation — `[label](codeg://session/<id>)`. The numeric conversation
    /// id is the stable key the server's `get_session_info` tool resolves (it
    /// then reads the row's bound external id + agent type server-side).
    static func session(id: Int, title: String) -> MentionReference {
        let uri = "codeg://session/\(id)"
        // Fold any inline reference badges in the title down to their bracket
        // text so the row and the inserted badge read like the sidebar's title
        // rather than leaking serialized Markdown (web `sessionToSuggestion`).
        let folded = foldedReferenceBadges(in: title).trimmingCharacters(in: .whitespacesAndNewlines)
        let label = folded.isEmpty ? "#\(id)" : folded
        return MentionReference(
            kind: .sessions,
            uri: uri,
            label: label,
            detail: nil,
            markdown: markdownLink(text: label, uri: uri)
        )
    }

    /// A git commit — `[shortHash](codeg://commit/<repoKey>@<fullHash>)`.
    /// `repoKey` identifies the repository (its path, as the web passes it) and
    /// is percent-encoded so a path with `/` or spaces stays one uri segment.
    static func commit(repoKey: String, fullHash: String, shortHash: String, subject: String) -> MentionReference {
        let uri = "codeg://commit/\(encodeURIComponent(repoKey))@\(fullHash)"
        let trimmedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return MentionReference(
            kind: .commits,
            uri: uri,
            label: shortHash,
            detail: trimmedSubject.isEmpty ? nil : trimmedSubject,
            markdown: markdownLink(text: shortHash, uri: uri)
        )
    }
}

// MARK: - Serialization helpers

private extension MentionReference {
    /// `[text](uri)` with both halves escaped. The only shape this picker emits
    /// that carries a uri; the skill/command form has no uri and is handled by
    /// the compose insert model instead.
    static func markdownLink(text: String, uri: String) -> String {
        "[\(escapeMarkdownText(text))](\(escapeLinkDestination(uri)))"
    }

    /// Collapse newline runs to a single space so a reference stays one inline
    /// token (a label carrying a newline would split the link across lines).
    static func collapseNewlines(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s*[\\r\\n]+\\s*", with: " ", options: .regularExpression)
    }

    /// Backslash-escape every inline-significant ASCII punctuation character so
    /// a crafted label cannot inject Markdown structure — links `[]()`,
    /// autolinks `<>`, code spans `` ` ``, emphasis `* _`, strikethrough `~`, or
    /// escapes `\`. Inside `[...]` link text GFM does not nest links, so escaping
    /// is sufficient there (unlike free-standing text, which the web additionally
    /// code-spans when it could autolink — this picker never emits free-standing
    /// text, so that branch is not ported).
    static func escapeMarkdownText(_ text: String) -> String {
        let significant: Set<Character> = ["\\", "`", "*", "_", "~", "[", "]", "(", ")", "<", ">"]
        let flat = collapseNewlines(text)
        return String(flat.flatMap { ch -> [Character] in
            significant.contains(ch) ? ["\\", ch] : [ch]
        })
    }

    /// Render a Markdown link destination safely. URIs containing spaces,
    /// parentheses, angle brackets or backslashes are wrapped in `<…>` so a `)`
    /// or a trailing `\` can't terminate the link early; inside `<…>` CommonMark
    /// still interprets backslash escapes, so `\`, `<` and `>` are escaped too.
    /// Clean URLs stay bare (web `escapeLinkDestination`).
    static func escapeLinkDestination(_ uri: String) -> String {
        let needsWrapping = uri.rangeOfCharacter(from: CharacterSet(charactersIn: " ()<>\\")) != nil
        guard needsWrapping else { return uri }
        let escaped = uri
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "<", with: "\\<")
            .replacingOccurrences(of: ">", with: "\\>")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        return "<\(escaped)>"
    }

    /// `file://` uri for an absolute path, percent-encoding each segment so a
    /// space or `#` in a file name can't break the link (web `buildFileUri`).
    /// A leading `/` yields `file:///…` — the three slashes are the empty
    /// authority plus the absolute path, not a typo.
    static func fileURI(absolutePath: String) -> String {
        let normalized = absolutePath.replacingOccurrences(of: "\\", with: "/")
        let encoded = normalized
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { encodeURIComponent(String($0)) }
            .joined(separator: "/")
        return normalized.hasPrefix("/") ? "file://\(encoded)" : "file:///\(encoded)"
    }

    /// The workspace root joined with a workspace-relative path, without
    /// doubling or dropping the separator (`/` and `\` both accepted).
    static func joinPath(root: String, relative: String) -> String {
        let left = root.replacingOccurrences(of: "[/\\\\]+$", with: "", options: .regularExpression)
        let right = relative.replacingOccurrences(of: "^[/\\\\]+", with: "", options: .regularExpression)
        return left.isEmpty ? right : "\(left)/\(right)"
    }

    /// Strip inline reference badges (`[label](scheme://…)`) down to their
    /// bracket text, so a session title that itself contains a reference reads
    /// as prose instead of raw Markdown (web `formatConversationTitle`).
    static func foldedReferenceBadges(in title: String) -> String {
        title.replacingOccurrences(
            of: "\\[([^\\]]*)\\]\\([a-z][a-z0-9+.\\-]*:[^)]*\\)",
            with: "$1",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    /// `encodeURIComponent` — unreserved marks only. Deliberately the JS set
    /// (which keeps `!'()*`), so a uri built here is byte-identical to the one
    /// the web composer would emit for the same reference.
    static func encodeURIComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
