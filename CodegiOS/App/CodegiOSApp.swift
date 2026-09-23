import SwiftUI

@main
struct CodegiOSApp: App {
    init() {
        // TEMPORARY (hang triage): the watchdog reports carry the shared cache as
        // one opaque image, so they can only ever name the app's own frames. This
        // samples the main thread from a background thread and resolves each PC to
        // its image. See `MainThreadSampler`.
        MainThreadSampler.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
