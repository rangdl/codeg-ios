import Foundation

/// URL schemes accepted by the app.
///
/// Mention links in prompts are a backend data format and stay on the canonical
/// `codeg://` scheme. The dev app separately registers `codeg-dev://` for OS
/// navigation so it can be installed beside the formal app without competing
/// for the same incoming links.
enum CodegURLScheme {
    static let canonical = "codeg"
    static let development = "codeg-dev"

    /// The scheme generated into this build's Info.plist, with a safe fallback
    /// for previews and tests that do not have an app bundle.
    static var current: String {
        let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes")
            as? [[String: Any]]
        let schemes = urlTypes?
            .compactMap { $0["CFBundleURLSchemes"] as? [String] }
            .flatMap { $0 }
        return schemes?.first(where: { !$0.isEmpty }) ?? canonical
    }

    static func accepts(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == current.lowercased()
            || scheme == canonical
            || scheme == development
    }
}
