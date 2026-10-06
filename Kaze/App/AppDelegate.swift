import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let app = AppModel.shared
    private var menuBar: MenuBarController?
    private var island: IslandWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        #if DEBUG
        if SelfTest.isRequested {
            Task {
                let status = await SelfTest.run()
                fflush(stdout)
                exit(status)
            }
            return
        }
        #endif

        menuBar = MenuBarController(app: app)
        island = IslandWindowController(dictation: app.dictation)

        #if DEBUG
        if CommandLine.arguments.contains("--preview-island") {
            Task {
                try? await Task.sleep(for: .seconds(1))
                await app.dictation.runIslandPreview()
            }
            return
        }
        #endif

        app.startShortcutMonitoring()
        app.models.warmUp(app.preferences.speechModel)
        app.updater.start()

        #if DEBUG
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--settings"), index + 1 < args.count {
            WindowManager.shared.showSettings(SettingsPane(rawValue: args[index + 1]))
            return
        }
        if args.contains("--onboarding-step") {
            WindowManager.shared.showOnboarding()
            return
        }
        #endif

        if !app.preferences.hasCompletedOnboarding {
            WindowManager.shared.showOnboarding()
        } else if !app.isShortcutActive {
            // Accessibility was revoked (or the app was re-signed): surface it.
            WindowManager.shared.showSettings(.general)
        }
    }

    /// Re-opening Kaze from Finder or Spotlight shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowManager.shared.showSettings() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
