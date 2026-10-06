import AppKit
import SwiftUI

/// Opens Kaze's two real windows (Settings, Onboarding) and flips the app
/// between menu-bar-only and a regular app while one is visible, so it can
/// take focus and show in ⌘-Tab.
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()

    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    let navigation = SettingsNavigation()

    func showSettings(_ pane: SettingsPane? = nil) {
        if let pane { navigation.selection = pane }
        if settingsWindow == nil {
            let window = makeWindow(
                size: CGSize(width: 820, height: 600),
                content: SettingsView(navigation: navigation),
                title: "Kaze Settings"
            )
            window.minSize = CGSize(width: 720, height: 480)
            window.setFrameAutosaveName("KazeSettings")
            window.toolbarStyle = .unified
            settingsWindow = window
        }
        present(settingsWindow)
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let window = makeWindow(
                size: CGSize(width: 680, height: 560),
                content: OnboardingView(onFinish: { [weak self] in self?.finishOnboarding() }),
                title: "Welcome to Kaze"
            )
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.remove(.resizable)
            window.isMovableByWindowBackground = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            onboardingWindow = window
        }
        present(onboardingWindow)
    }

    private func finishOnboarding() {
        AppModel.shared.preferences.hasCompletedOnboarding = true
        onboardingWindow?.close()
    }

    private func makeWindow(size: CGSize, content: some View, title: String) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: content.environment(AppModel.shared))
        window.setContentSize(size)
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        guard let window else { return }
        NSApp.setActivationPolicy(.regular)
        // Cooperative activation can leave a background app's window behind
        // others, so order it front explicitly before activating.
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === onboardingWindow {
            onboardingWindow = nil
            AppModel.shared.permissions.endWatching()
        }
        if window === settingsWindow { settingsWindow = nil }
        DispatchQueue.main.async { [self] in
            if settingsWindow == nil, onboardingWindow == nil {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
