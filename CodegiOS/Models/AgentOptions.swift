import Foundation

/// The agent's configurable options as enumerated by `acp_describe_agent_options`
/// (Rust `AgentOptionsSnapshot`). Decode-only.
///
/// IMPORTANT: this catalog comes from a server-side *probe* agent the route
/// spawns on demand, NOT from the live chat connection. So `modes.currentModeId`
/// and a select's `currentValue` are the probe's fresh-session **defaults** — a
/// reasonable initial highlight, but not a claim about the live session's state.
/// Applying a choice (`acp_set_mode` / `acp_set_config_option`) targets the chat
/// connection separately.
///
/// Responses are decoded with `.convertFromSnakeCase`, so wire keys like
/// `config_options` arrive here already camelCased — properties are spelled in
/// camelCase and must NOT carry snake_case `CodingKeys` (that would double-convert).
struct AgentOptionsSnapshot: Hashable, Sendable, Decodable {
    let modes: SessionModeState?
    let configOptions: [SessionConfigOption]

    private enum CodingKeys: String, CodingKey {
        case modes, configOptions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modes = try c.decodeIfPresent(SessionModeState.self, forKey: .modes)
        // Rust always serializes the Vec, but default to empty defensively so a
        // server that omits it can't fail the whole decode.
        configOptions = try c.decodeIfPresent([SessionConfigOption].self, forKey: .configOptions) ?? []
    }

    /// Direct initializer for previews / tests.
    init(modes: SessionModeState?, configOptions: [SessionConfigOption]) {
        self.modes = modes
        self.configOptions = configOptions
    }

    /// True when there is nothing the user can pick — used to show an
    /// "no configurable options" state instead of empty pickers.
    var isEmpty: Bool {
        (modes?.availableModes.isEmpty ?? true) && configOptions.isEmpty
    }
}

/// Mode state for the session (Rust `SessionModeStateInfo`): the current mode id
/// plus the list of selectable modes.
struct SessionModeState: Hashable, Sendable, Decodable {
    let currentModeId: String
    let availableModes: [SessionModeInfo]
}

/// The subset of the live session snapshot (`acp_get_session_snapshot_by_conversation`
/// → Rust `LiveSessionSnapshot`) we care about: the AUTHORITATIVE current
/// mode/config for the conversation's live chat session. Unlike the probe
/// (`describe_agent_options`), this reflects the real session state, so it's used
/// both to load the sheet and to reconcile after an apply. Decode-only; the many
/// other snapshot fields are ignored.
struct SessionSnapshot: Hashable, Sendable, Decodable {
    let modes: SessionModeState?
    let currentMode: String?
    let configOptions: [SessionConfigOption]?
    let selectorsReady: Bool
    /// Slash commands the live agent advertises (`available_commands`). Empty
    /// until a connection is bound to the conversation; surfaced in the "+" menu.
    let availableCommands: [AvailableCommandInfo]
    /// Whether the agent advertised the ACP `session/fork` method
    /// (snapshot wire `fork_supported`, probed from `session_capabilities.fork`
    /// at agent init). nil when the field is absent (an older server without
    /// it) — callers treat nil as "unknown" and gate fail-closed, matching the
    /// web client's latch-once `supportsFork`.
    let forkSupported: Bool?

    private enum CodingKeys: String, CodingKey {
        case modes, currentMode, configOptions, selectorsReady, availableCommands, forkSupported
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modes = try c.decodeIfPresent(SessionModeState.self, forKey: .modes)
        currentMode = try c.decodeIfPresent(String.self, forKey: .currentMode)
        configOptions = try c.decodeIfPresent([SessionConfigOption].self, forKey: .configOptions)
        selectorsReady = try c.decodeIfPresent(Bool.self, forKey: .selectorsReady) ?? false
        availableCommands = try c.decodeIfPresent([AvailableCommandInfo].self, forKey: .availableCommands) ?? []
        forkSupported = try? c.decodeIfPresent(Bool.self, forKey: .forkSupported)
    }

    /// True when the snapshot actually carries selectable options (a live session
    /// whose selectors have populated).
    var hasSelectors: Bool {
        !(modes?.availableModes.isEmpty ?? true) || !(configOptions?.isEmpty ?? true)
    }

    /// View as the catalog shape the sheet renders.
    var asOptionsSnapshot: AgentOptionsSnapshot {
        AgentOptionsSnapshot(modes: modes, configOptions: configOptions ?? [])
    }
}

/// One selectable agent mode (Rust `SessionModeInfo`), e.g. Claude's
/// "default" / "plan" modes.
struct SessionModeInfo: Hashable, Sendable, Decodable, Identifiable {
    let id: String
    let name: String
    let description: String?
}

/// One configurable option (Rust `SessionConfigOptionInfo`), e.g. a model
/// selector. `kind` carries the concrete control (currently only `select`).
struct SessionConfigOption: Hashable, Sendable, Decodable, Identifiable {
    let id: String
    let name: String
    let description: String?
    let category: String?
    let kind: SessionConfigKind
}

/// The control behind a `SessionConfigOption` (Rust `SessionConfigKindInfo`,
/// internally tagged by `type`). Only `select` is modeled; unknown future kinds
/// decode to `.unknown` rather than throwing.
enum SessionConfigKind: Hashable, Sendable, Decodable {
    case select(currentValue: String, options: [SessionConfigSelectOption], groups: [SessionConfigSelectGroup])
    case unknown(type: String)

    private enum CodingKeys: String, CodingKey {
        case type, currentValue, options, groups
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "select":
            self = .select(
                currentValue: try c.decodeIfPresent(String.self, forKey: .currentValue) ?? "",
                options: try c.decodeIfPresent([SessionConfigSelectOption].self, forKey: .options) ?? [],
                groups: try c.decodeIfPresent([SessionConfigSelectGroup].self, forKey: .groups) ?? []
            )
        default:
            self = .unknown(type: type)
        }
    }

    /// Convenience: the flat option list for a `select` (ignoring grouping),
    /// nil for any other kind.
    var selectOptions: [SessionConfigSelectOption]? {
        if case .select(_, let options, _) = self { return options }
        return nil
    }

    /// The grouped option list for a `select`, nil for any other kind. When this
    /// is non-empty the UI must render groups and IGNORE `selectOptions` (the web
    /// renders `groups.length > 0 ? groups : options`, never both).
    var selectGroups: [SessionConfigSelectGroup]? {
        if case .select(_, _, let groups) = self { return groups }
        return nil
    }

    /// The current value of a `select`, nil for any other kind.
    var selectCurrentValue: String? {
        if case .select(let value, _, _) = self { return value }
        return nil
    }

    /// Every selectable value (flat + grouped) — used to validate a cached
    /// preference against the live catalog before pre-selecting it.
    var allSelectValues: [String] {
        guard case .select(_, let options, let groups) = self else { return [] }
        return options.map(\.value) + groups.flatMap { $0.options.map(\.value) }
    }
}

/// One choice in a `select` config option (Rust `SessionConfigSelectOptionInfo`).
struct SessionConfigSelectOption: Hashable, Sendable, Decodable, Identifiable {
    let value: String
    let name: String
    let description: String?

    var id: String { value }
}

/// A named grouping of select options (Rust `SessionConfigSelectGroupInfo`).
struct SessionConfigSelectGroup: Hashable, Sendable, Decodable, Identifiable {
    let group: String
    let name: String
    let options: [SessionConfigSelectOption]

    var id: String { group }
}
