import SwiftUI

/// System settings: HTTP proxy, reply/UI language, default terminal shell, and a
/// read-only update check. Proxy / language / terminal each persist through their
/// own coalescing serial sender (one request in flight, latest value wins, never
/// drops the final value; reconcile to server truth on failure). The wrapped
/// `{settings:{snake_case}}` bodies are built raw by the client.
@MainActor
final class SystemSettingsModel: ObservableObject {
    enum Phase: Equatable { case loading, loaded, failed(String) }

    @Published private(set) var phase: Phase = .loading

    // Proxy
    @Published var proxyEnabled = false
    @Published var proxyUrl = ""

    // Language
    @Published var languageMode = "system"   // "system" | "manual"
    @Published var language = "en"

    // Terminal
    @Published private(set) var shellOptions: [TerminalShellOption] = []
    @Published private(set) var resolvedShell = ""
    @Published var selectedShellId = "system"
    @Published var customShellPath = ""
    @Published var probeResult: Bool?
    @Published var probing = false

    // Update (check + in-place server self-update)
    @Published private(set) var updateInfo: AppUpdateCheckResult?
    @Published private(set) var updateState: AppUpdateState?
    @Published var checkingUpdate = false
    @Published private(set) var startingUpdate = false
    @Published private(set) var restartingUpdate = false
    @Published private(set) var verifyingUpdate = false
    @Published private(set) var restartCountdown: Int?
    /// Highest snapshot seq applied. The backend owns the state and can answer a
    /// slow poll after a fresher one; never let an older snapshot win.
    private var updateSeq: UInt64 = 0

    @Published var saveError: String?
    @Published var toast: String?

    private let client: CodegClient?

    init(client: CodegClient?) { self.client = client }

    /// This app can drive an in-place server update only when the server both
    /// supports it and speaks the detached snapshot protocol. Older servers
    /// answer `perform_app_update` with a legacy blocking shape the app can't
    /// decode, so they keep the read-only "update available" state.
    var canInstallInPlace: Bool {
        guard let info = updateInfo, info.update != nil, info.selfUpdateSupported else { return false }
        return info.liveProgress ?? false
    }

    /// Any update action is in flight — used to keep the check button from
    /// racing a download/restart.
    var updateBusy: Bool {
        if checkingUpdate || startingUpdate || restartingUpdate { return true }
        switch updateState?.status {
        case .some(.downloading), .some(.installing), .some(.restarting): return true
        default: return false
        }
    }

    private var customOption: TerminalShellOption? { shellOptions.first { $0.acceptsCustomPath } }

    func load() async {
        guard let client else { phase = .failed("No server selected."); return }
        do {
            async let proxy = client.systemProxySettings()
            async let lang = client.systemLanguageSettings()
            async let term = client.systemTerminalSettings()
            async let shells = client.availableTerminalShells()

            let p = try await proxy
            proxyEnabled = p.enabled
            proxyUrl = p.proxyUrl ?? ""

            let l = try await lang
            languageMode = l.mode
            language = l.language

            let sh = try await shells
            shellOptions = sh.options
            resolvedShell = sh.resolvedShell

            applyTerminal((try await term).defaultShell)
            phase = .loaded
            // Recover an update that is already downloading / staged (started
            // before this page opened, possibly from another client). Keep
            // polling an in-flight one so the progress and the eventual
            // "Restart Now" still appear without another manual check.
            if let snap = try? await client.appUpdateState() {
                applyUpdateState(snap)
                switch snap.status {
                case .downloading, .installing: await pollUpdateState()
                default: break
                }
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Map a stored `default_shell` to the picker selection + custom path.
    private func applyTerminal(_ defaultShell: String?) {
        guard let ds = defaultShell, !ds.isEmpty else {
            selectedShellId = shellOptions.first { $0.id == "system" }?.id ?? "system"
            customShellPath = ""
            return
        }
        if let match = shellOptions.first(where: { $0.value == ds }) {
            selectedShellId = match.id
            customShellPath = ""
        } else {
            selectedShellId = customOption?.id ?? "custom"
            customShellPath = ds
        }
    }

    // MARK: - Proxy (coalescing)

    @Published private var proxySaving = false
    @Published private var proxyPending = false

    func scheduleProxySave() {
        // When enabling, require a URL first (the server rejects enabled+empty);
        // once a URL is typed the next change persists it.
        if proxyEnabled && proxyUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        proxyPending = true
        Task { await drainProxy() }
    }

    private func drainProxy() async {
        guard !proxySaving, let client else { return }
        proxySaving = true
        defer { proxySaving = false }
        while proxyPending {
            proxyPending = false
            let enabled = proxyEnabled
            let url = proxyUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            do { try await client.updateSystemProxySettings(enabled: enabled, proxyUrl: url.isEmpty ? nil : url) }
            catch {
                saveError = error.localizedDescription
                // Reconcile to server truth ONLY if no newer edit is queued (checked
                // around the await); otherwise let the loop send it, so a failure
                // during a concurrent edit can't drop that edit. Don't return.
                if !proxyPending, let p = try? await client.systemProxySettings(), !proxyPending {
                    proxyEnabled = p.enabled
                    proxyUrl = p.proxyUrl ?? ""
                }
            }
        }
    }

    // MARK: - Language (coalescing)

    @Published private var languageSaving = false
    @Published private var languagePending = false

    func scheduleLanguageSave() {
        languagePending = true
        Task { await drainLanguage() }
    }

    private func drainLanguage() async {
        guard !languageSaving, let client else { return }
        languageSaving = true
        defer { languageSaving = false }
        while languagePending {
            languagePending = false
            let mode = languageMode
            let lang = language
            do { try await client.updateSystemLanguageSettings(mode: mode, language: lang) }
            catch {
                saveError = error.localizedDescription
                // Reconcile only when no newer edit is queued; never drop a
                // concurrent edit. Don't return — let the loop drain it.
                if !languagePending, let l = try? await client.systemLanguageSettings(), !languagePending {
                    languageMode = l.mode
                    language = l.language
                }
            }
        }
    }

    // MARK: - Terminal (coalescing)

    @Published private var terminalSaving = false
    @Published private var terminalPending = false

    /// The default_shell value for the current selection, or `.some(nil)` for the
    /// system default. Returns nil (don't save) when a custom path is required but
    /// empty.
    private func terminalValue() -> String?? {
        guard let opt = shellOptions.first(where: { $0.id == selectedShellId }) else { return .some(nil) }
        if opt.acceptsCustomPath {
            let p = customShellPath.trimmingCharacters(in: .whitespacesAndNewlines)
            return p.isEmpty ? nil : .some(p)
        }
        // System option carries no value; concrete shells carry their path.
        return .some(opt.value)
    }

    func scheduleTerminalSave() {
        guard terminalValue() != nil else { return }   // custom path required but empty
        terminalPending = true
        Task { await drainTerminal() }
    }

    private func drainTerminal() async {
        guard !terminalSaving, let client else { return }
        terminalSaving = true
        defer { terminalSaving = false }
        while terminalPending {
            terminalPending = false
            guard let value = terminalValue() else { continue }   // became empty-custom
            do { try await client.updateSystemTerminalSettings(defaultShell: value) }
            catch {
                saveError = error.localizedDescription
                // Reconcile only when no newer edit is queued; never drop a
                // concurrent edit. Don't return — let the loop drain it.
                if !terminalPending, let t = try? await client.systemTerminalSettings(), !terminalPending {
                    applyTerminal(t.defaultShell)
                }
            }
        }
    }

    func probeCustomShell() async {
        guard let client else { return }
        let path = customShellPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        probing = true
        defer { probing = false }
        probeResult = try? await client.probeTerminalShellPath(path)
    }

    // MARK: - Update check + in-place install

    func checkUpdate() async {
        guard let client else { return }
        checkingUpdate = true
        defer { checkingUpdate = false }
        do {
            updateInfo = try await client.checkAppUpdate()
            // A staged update survives page visits; pick it up so "Restart Now"
            // appears even when the check itself reports no newer release.
            if let snap = try? await client.appUpdateState() { applyUpdateState(snap) }
        }
        catch { toast = "Update check failed: \(error.localizedDescription)" }
    }

    /// Kick off the backend's detached download/verify/swap, then poll its
    /// snapshot until it settles. The download keeps running server-side even if
    /// the settings page is left; `startUpdate` only owns the visible polling.
    func startServerUpdate() async {
        guard let client, !updateBusy else { return }
        // A Retry after reopening the page has no fresh check result, so accept
        // a restored snapshot as authority that this server speaks the protocol.
        guard canInstallInPlace || updateState != nil else { return }
        startingUpdate = true
        do {
            applyUpdateState(try await client.performAppUpdate())
        } catch {
            startingUpdate = false
            toast = "Couldn’t start the update: \(error.localizedDescription)"
            return
        }
        startingUpdate = false
        await pollUpdateState()
    }

    private func pollUpdateState() async {
        guard let client else { return }
        // A large server tarball on a slow link can take a while; this cap only
        // stops a wedged poll from spinning forever. Progress itself is
        // backend-owned, so leaving the page loses nothing.
        let deadline = Date().addingTimeInterval(15 * 60)
        while !Task.isCancelled {
            switch updateState?.status {
            case .some(.readyToRestart), .some(.error), .some(.idle): return
            default: break
            }
            if Date() >= deadline { return }
            try? await Task.sleep(for: .milliseconds(700))
            if Task.isCancelled { return }
            guard let snap = try? await client.appUpdateState() else { continue }
            applyUpdateState(snap)
        }
    }

    /// Relaunch into the staged update, then confirm the new version actually
    /// came up (and survived the supervisor's probation window) before telling
    /// the user it succeeded.
    func restartForUpdate() async {
        guard let client, !restartingUpdate else { return }
        restartingUpdate = true
        defer {
            restartingUpdate = false
            verifyingUpdate = false
            restartCountdown = nil
        }

        let target = updateState?.version ?? updateInfo?.update?.version
        // Local version before the relaunch. The supervisor restores this exact
        // build if the new one can't boot, so a post-restart match means a
        // silent rollback rather than success.
        let baseline = try? await client.healthProbe().version

        let result: AppUpdateActionResult
        do { result = try await client.restartApp() }
        catch {
            toast = "Couldn’t restart the server: \(error.localizedDescription)"
            return
        }

        // The server answers just before exiting; wait out its flush/relaunch
        // delay, counting down for the user, then poll until it answers again.
        let delaySeconds = max(1, Int((Double(result.restartDelayMs) / 1000).rounded(.up)) + 1)
        await runCountdown(seconds: delaySeconds)
        guard await waitForServerHealthy(timeout: 90) else {
            toast = "The server didn’t come back in time. Check it from the web UI."
            return
        }

        var running = (try? await client.healthProbe())?.version
        if rolledBack(running: running, baseline: baseline, target: target) {
            clearUpdateState()
            await checkUpdate()
            toast = "The update rolled back; the server is still on v\(running ?? baseline ?? "its previous version")."
            return
        }

        // Supervised mode keeps a probation window: a build that boots but then
        // crashes is reverted within it. Wait it out so a crash-loop isn't
        // reported as a successful update.
        let trialSeconds = result.capability == "supervised" ? result.trialSeconds : 0
        if trialSeconds > 0 {
            verifyingUpdate = true
            let deadline = Date().addingTimeInterval(TimeInterval(trialSeconds) + 3)
            while Date() < deadline && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }
                guard let v = try? await client.healthProbe().version else { continue }
                running = v
                if rolledBack(running: v, baseline: baseline, target: target) {
                    verifyingUpdate = false
                    clearUpdateState()
                    await checkUpdate()
                    toast = "The update rolled back; the server is still on v\(v)."
                    return
                }
            }
            verifyingUpdate = false
        }

        clearUpdateState()
        await checkUpdate()
        toast = "Server updated to v\(running ?? target ?? "the new version")."
    }

    /// A post-restart version that still matches the pre-update baseline means
    /// the supervisor reverted a build that couldn't stay up.
    private func rolledBack(running: String?, baseline: String?, target: String?) -> Bool {
        guard let running, let baseline, running == baseline else { return false }
        guard let target else { return true }
        return target != baseline
    }

    private func runCountdown(seconds: Int) async {
        for remaining in stride(from: seconds, through: 0, by: -1) {
            restartCountdown = remaining
            if remaining > 0 {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        restartCountdown = nil
    }

    private func waitForServerHealthy(timeout: TimeInterval) async -> Bool {
        guard let client else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !Task.isCancelled {
            if (try? await client.healthProbe()) != nil { return true }
            try? await Task.sleep(for: .seconds(1.5))
        }
        return false
    }

    private func applyUpdateState(_ state: AppUpdateState) {
        guard state.seq >= updateSeq else { return }
        updateSeq = state.seq
        updateState = state
    }

    /// Drop every trace of the finished operation. Also resets `seq`: the
    /// restarted server's snapshot counter starts over, and keeping the old high
    /// watermark would discard the fresh process's first snapshots.
    private func clearUpdateState() {
        updateSeq = 0
        updateState = nil
    }
}
