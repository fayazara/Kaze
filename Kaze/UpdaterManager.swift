import Combine
import Foundation
import Sparkle

/// Manages Sparkle auto-update lifecycle.
///
/// Sparkle's `SPUStandardUpdaterController` must be created early (before
/// `applicationDidFinishLaunching` returns) so that the automatic update
/// check schedule starts correctly.  This class wraps the controller and
/// exposes helpers the rest of the app can call.
@MainActor
final class UpdaterManager: NSObject, ObservableObject {
    /// The underlying Sparkle updater controller.
    /// `startingUpdater: false` defers the initial automatic check until we
    /// explicitly call `startUpdater()` — this avoids a race with other
    /// first-launch work (permissions, onboarding).
    private let controller: SPUStandardUpdaterController

    /// Convenience accessor for the updater instance (used by SwiftUI bindings).
    var updater: SPUUpdater { controller.updater }

    /// Whether the user can trigger "Check for Updates" right now.
    @Published var canCheckForUpdates = false

    /// Whether Sparkle should automatically check for updates on a schedule.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    override init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()

        // Observe Sparkle's `canCheckForUpdates` KVO property and republish
        // it as a Combine-friendly @Published value.
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// Call once after permissions and onboarding are resolved.
    func start() {
        controller.startUpdater()
    }

    /// Programmatically trigger an update check (e.g. from a menu item).
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
