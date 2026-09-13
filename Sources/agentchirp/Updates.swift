import Cocoa
import Sparkle
import AgentChirpCore

final class AppUpdates {
    private var controller: SPUStandardUpdaterController?
    private(set) var message = "Updates are available in the downloaded app."
    var available: Bool { controller != nil }
    var automatic: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }
    func start() {
        guard !isDevBuild else { return }
        let candidate = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        do {
            try candidate.updater.start()
            controller = candidate
            message = "Updates are checked securely. Session data stays on your Mac."
        } catch {
            message = "Updates could not start: \(error.localizedDescription)"
        }
    }
    func check() {
        guard let controller, controller.updater.canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }
}
