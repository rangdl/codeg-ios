import Foundation

/// A client-only install/upgrade/uninstall action (mirrors the web's UI-only
/// `UiFixAction` kinds — distinct from the server's ``FixActionKind``). The raw
/// value matches the web action string; the `binary`/`npx` split tells the model
/// layer which endpoint to call.
enum AgentInstallAction: String, Hashable, Sendable {
    case downloadBinary = "download_binary"
    case upgradeBinary = "upgrade_binary"
    case installNpx = "install_npx"
    case upgradeNpx = "upgrade_npx"
    case uninstallBinary = "uninstall_binary"
    case uninstallNpx = "uninstall_npx"
    case customInstall = "custom_install"
    /// Install an unreviewed upstream release (newer than codeg's pinned
    /// version). Reuses the custom-install path with the offered version.
    case upgradeLatest = "upgrade_latest"
    /// Run a `system` agent's own updater (`acp_update_system_agent`).
    case upgradeSystem = "upgrade_system"
    /// Open the vendor install page for a missing `system` agent.
    case openInstallGuide = "open_install_guide"

    var isUninstall: Bool { self == .uninstallBinary || self == .uninstallNpx }
    /// Upgrades clear the binary cache before (re)installing (web `runBinaryAction`
    /// `clearCache = mode === "upgrade"`); custom installs do too, handled by the
    /// caller via the explicit version override.
    var isUpgrade: Bool {
        self == .upgradeBinary || self == .upgradeNpx
            || self == .upgradeLatest || self == .upgradeSystem
    }
    var isInstall: Bool { self == .downloadBinary || self == .installNpx }
}

/// One synthesized version-row button.
struct AgentVersionAction: Hashable, Sendable, Identifiable {
    let label: String
    let action: AgentInstallAction
    /// Target version for `.upgradeLatest`, URL for `.openInstallGuide`.
    var payload: String? = nil
    var disabled: Bool = false
    var id: String { "\(action.rawValue)|\(label)|\(payload ?? "")" }
}

/// The synthesized "Version Status" row: a pass/warn/fail status, a
/// `Remote: … · Local: …` message, and the install/upgrade/uninstall/custom
/// buttons appropriate to the current state.
struct AgentVersionCheck: Hashable, Sendable {
    enum Status: String, Sendable { case pass, warn, fail }
    let status: Status
    let message: String
    let actions: [AgentVersionAction]
    /// Offered separately from `actions` so the UI can render it with the web's
    /// warning tone instead of burying it in the overflow menu.
    var latestFix: AgentVersionAction? = nil
}

/// Newest upstream release of an agent, newer than codeg's pinned version and
/// fetchable through Custom install (`acp_fetch_agent_latest_release`).
struct AgentLatestRelease: Decodable, Hashable, Sendable {
    let version: String
}

/// Pure version helpers + the synthetic version-status row, ported 1:1 from the
/// web `acp-agent-settings.tsx` (`compareVersion`, `hasComparableVersion`,
/// `isValidCustomVersion`, `buildVersionCheck`). Kept free of UI/networking so it
/// can be exercised directly in checks.
enum AgentVersion {

    private static func isDigit(_ c: Character) -> Bool { ("0"..."9").contains(c) }

    /// `< 0` if `a` is older than `b`. Strips leading non-digits, splits on ".",
    /// numeric-compares part by part (missing parts = 0). Only meaningful when
    /// both inputs pass ``hasComparable(_:)``.
    static func compare(_ a: String, _ b: String) -> Int {
        func toParts(_ value: String) -> [Int] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized: Substring
            if let firstDigit = trimmed.firstIndex(where: isDigit) {
                normalized = trimmed[firstDigit...]
            } else {
                normalized = ""
            }
            return normalized
                .split(separator: ".", omittingEmptySubsequences: false)
                .map { part in Int(part.prefix(while: isDigit)) ?? 0 }
        }
        let left = toParts(a), right = toParts(b)
        let len = max(left.count, right.count)
        for i in 0..<len {
            let lv = i < left.count ? left[i] : 0
            let rv = i < right.count ? right[i] : 0
            if lv != rv { return lv > rv ? 1 : -1 }
        }
        return 0
    }

    /// Web `Boolean(value && /\d/.test(value) && value.includes("."))`.
    static func hasComparable(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        return value.contains(where: isDigit) && value.contains(".")
    }

    /// Web `sanitize_custom_version` mirror: tolerate a leading `v`, must start
    /// with a digit, must be dotted, only `[0-9A-Za-z.\-+]`. Rejects `latest`,
    /// bare majors, anything with spaces/`@`.
    static func isValidCustom(_ value: String) -> Bool {
        var normalized = Substring(value.trimmingCharacters(in: .whitespacesAndNewlines))
        if let f = normalized.first, f == "v" || f == "V" { normalized = normalized.dropFirst() }
        guard let first = normalized.first, isDigit(first) else { return false }
        let ok = normalized.allSatisfy { c in
            isDigit(c) || ("A"..."Z").contains(c) || ("a"..."z").contains(c)
                || c == "." || c == "-" || c == "+"
        }
        return ok && normalized.contains(".")
    }

    /// Whether the settings page should ask the backend for an unreviewed
    /// latest release. Mirrors the web `canCheckLatestRelease`: only managed
    /// npx/binary agents that can fetch a custom version, are available, and
    /// are not manual definitions.
    static func canCheckLatestRelease(_ agent: AcpAgentInfo) -> Bool {
        guard let dist = agent.distributionType, dist == "npx" || dist == "binary" else { return false }
        guard agent.supportsCustomVersion == true else { return false }
        guard agent.customSource != "manual" else { return false }
        guard agent.available, agent.registryVersion != nil else { return false }
        return true
    }

    /// The unreviewed latest version to offer, or nil once the installed
    /// version reaches it. The backend already vouches that the release is
    /// newer than the pinned version and that Custom install accepts it.
    static func latestReleaseOffer(_ agent: AcpAgentInfo, _ release: AgentLatestRelease?) -> String? {
        guard let release, canCheckLatestRelease(agent) else { return nil }
        if let installed = agent.installedVersion, hasComparable(installed),
           compare(installed, release.version) >= 0 {
            return nil
        }
        return release.version
    }

    /// The synthetic version-status row. `system` agents report their own
    /// installer state; managed binary/npx/uvx agents compare against codeg's
    /// recommended version and may also offer an unreviewed upstream release.
    static func check(
        _ agent: AcpAgentInfo,
        uvReady: Bool = true,
        latestRelease: AgentLatestRelease? = nil,
        systemCliFound: Bool? = nil
    ) -> AgentVersionCheck? {
        let dist = agent.distributionType ?? ""

        // ── system agents (Kiro CLI etc.): codeg launches but never installs.
        if dist == "system" {
            let found = systemCliFound ?? (agent.installedVersion != nil)
            let local = agent.installedVersion.map { "Local: \($0)" }
                ?? "Local: version not detected"
            if !found {
                var actions: [AgentVersionAction] = []
                if let url = agent.installUrl {
                    actions.append(AgentVersionAction(
                        label: "Install guide", action: .openInstallGuide, payload: url))
                }
                return AgentVersionCheck(
                    status: .fail,
                    message: "Not found on this machine. Install it with the official installer, then refresh.",
                    actions: actions
                )
            }
            if agent.supportsSelfUpdate == true {
                return AgentVersionCheck(
                    status: .pass,
                    message: "\(local). Installed with the official installer; Upgrade runs its own updater.",
                    actions: [AgentVersionAction(label: "Upgrade", action: .upgradeSystem)]
                )
            }
            return AgentVersionCheck(
                status: .pass,
                message: "\(local). Installed and updated by its own installer; Codeg launches it as-is.",
                actions: []
            )
        }

        guard dist == "binary" || dist == "npx" || dist == "uvx" else { return nil }

        let manual = agent.customSource == "manual"
        let remote = agent.registryVersion ?? "unknown"
        let local = agent.installedVersion ?? "Not installed"
        let versionText = manual
            ? "Local: \(local)"
            : "Remote: \(remote) · Local: \(local)"

        let installAction: AgentInstallAction = dist == "binary" ? .downloadBinary : .installNpx
        let upgradeAction: AgentInstallAction = dist == "binary" ? .upgradeBinary : .upgradeNpx
        let uninstallAction: AgentInstallAction = dist == "binary" ? .uninstallBinary : .uninstallNpx

        // uvx runtime missing → blocked, but uninstall stays available.
        if dist == "uvx" && !uvReady {
            var fixes = [AgentVersionAction(label: "Install", action: installAction, disabled: true)]
            if agent.installedVersion != nil {
                fixes.append(AgentVersionAction(label: "Uninstall", action: uninstallAction))
            }
            return AgentVersionCheck(
                status: .warn,
                message: "\(versionText). The uv runtime isn't installed — install it from the uv check below to use this agent.",
                actions: fixes
            )
        }

        // Only binary agents can be genuinely platform-unsupported.
        if !agent.available && dist != "uvx" {
            return AgentVersionCheck(
                status: .fail,
                message: "\(versionText). This platform doesn't support this agent.",
                actions: []
            )
        }

        let supportsCustom = agent.supportsCustomVersion
            ?? (dist == "npx" || (dist == "binary" && agent.registryVersion != nil))
        let customFix = AgentVersionAction(label: "Custom install", action: .customInstall)
        func withCustom(_ fixes: [AgentVersionAction]) -> [AgentVersionAction] {
            supportsCustom ? fixes + [customFix] : fixes
        }

        let latestVersion = latestReleaseOffer(agent, latestRelease)
        let latestFix = latestVersion.map {
            AgentVersionAction(
                label: "Upgrade to unreviewed latest \($0)",
                action: .upgradeLatest,
                payload: $0
            )
        }
        func make(_ status: AgentVersionCheck.Status, _ message: String, _ actions: [AgentVersionAction]) -> AgentVersionCheck {
            AgentVersionCheck(status: status, message: message, actions: actions, latestFix: latestFix)
        }

        // Not installed (manual definitions included).
        if agent.installedVersion == nil {
            return make(.fail, "\(versionText). Tap Install to set it up.",
                        withCustom([AgentVersionAction(label: "Install", action: installAction)]))
        }

        // Manual definitions stop here: installed is the whole story, and the
        // registry-comparison branches would only manufacture "upgrade
        // available" noise against a user-typed version.
        if manual {
            return make(.pass, "\(versionText). Installed.",
                        withCustom([AgentVersionAction(label: "Uninstall", action: uninstallAction)]))
        }

        // Remote comparable, local not → suggest upgrade-to-overwrite.
        if let reg = agent.registryVersion, hasComparable(reg), !hasComparable(agent.installedVersion) {
            return make(.warn, "\(versionText). The local version isn't comparable; Upgrade to overwrite the install.",
                        withCustom([
                            AgentVersionAction(label: "Upgrade", action: upgradeAction),
                            AgentVersionAction(label: "Uninstall", action: uninstallAction),
                        ]))
        }

        // Both comparable and local is behind → upgrade available.
        if hasComparable(agent.registryVersion), hasComparable(agent.installedVersion),
           let reg = agent.registryVersion, let inst = agent.installedVersion,
           compare(inst, reg) < 0 {
            return make(.warn, "\(versionText). Upgrade available.",
                        withCustom([
                            AgentVersionAction(label: "Upgrade", action: upgradeAction),
                            AgentVersionAction(label: "Uninstall", action: uninstallAction),
                        ]))
        }

        // Remote unknown but something is installed.
        if agent.registryVersion == nil {
            return make(.warn, "\(versionText). The remote version is currently unavailable.",
                        withCustom([AgentVersionAction(label: "Uninstall", action: uninstallAction)]))
        }

        // Up to date.
        return make(.pass, "\(versionText). Already on the latest version.",
                    withCustom([AgentVersionAction(label: "Uninstall", action: uninstallAction)]))
    }
}
