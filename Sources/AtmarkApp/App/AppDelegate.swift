import AppKit
import Logging
import AtmarkCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AtmarkPresentationModel

    private let logger = Logger(label: "atmark.app")
    private let runtime: ServerRuntime

    override init() {
        let runtime = ServerRuntime()
        self.runtime = runtime
        self.model = AtmarkPresentationModel(runtime: runtime)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            await model.start()
            if model.state == .failed {
                logger.error("Startup failed: \(model.errorMessage ?? "unknown error")")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Remove discovery immediately; process teardown closes the listener.
        Endpoint.remove()
    }
}
