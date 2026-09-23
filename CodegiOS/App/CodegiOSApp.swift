import SwiftUI

@main
struct CodegiOSApp: App {
    init() {
        HangProbe.startCapturingStdout()   // TEMPORARY (hang triage)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
