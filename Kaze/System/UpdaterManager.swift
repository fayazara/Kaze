import Foundation
import Observation
import Sparkle

/// Sparkle auto-updates. Disabled in Debug builds so development builds never
/// replace themselves.
@Observable
final class UpdaterManager {
    @ObservationIgnored private let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func start() {
        #if !DEBUG
        controller.startUpdater()
        #endif
    }

    func checkForUpdates() {
        #if !DEBUG
        controller.checkForUpdates(nil)
        #endif
    }

    var isAvailable: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }
}
