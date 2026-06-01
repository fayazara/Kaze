//
//  SettingsWindowController.swift
//  Kaze
//
//  A singleton NSWindowController that creates the settings window with
//  .fullSizeContentView for liquid glass rendering on macOS 26.
//
//  Usage:
//    SettingsWindowController.configure(...)   // once, at launch
//    SettingsWindowController.show(tab: .general)
//

import AppKit
import SwiftUI

// MARK: - Activation Policy

/// Manages the app's activation policy so regular windows (settings) show the
/// Dock icon and appear in Cmd-Tab, then revert to a menu-bar-only accessory
/// once the last managed window closes. Reference counted.
@MainActor
enum AppActivationPolicy {
    private static var activeWindowCount = 0

    static func enter() {
        activeWindowCount += 1
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func leave() {
        activeWindowCount = max(0, activeWindowCount - 1)
        guard activeWindowCount == 0 else { return }
        Task { @MainActor in
            guard activeWindowCount == 0 else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - Navigation State

/// Singleton so external code (menu bar, AppDelegate) can drive the selected tab.
@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()

    var selectedTab: SettingsTab? = .general

    private init() {}
}

// MARK: - Window Controller

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    /// Long-lived dependencies owned by the AppDelegate, injected once at launch.
    struct Dependencies {
        let whisperModelManager: WhisperModelManager
        let parakeetModelManager: FluidAudioModelManager
        let historyManager: TranscriptionHistoryManager
        let customWordsManager: CustomWordsManager
        let updaterManager: UpdaterManager
        let restartOnboarding: () -> Void
    }

    private static var shared: SettingsWindowController?
    private static var dependencies: Dependencies?

    /// Inject the app's managers. Call once from `applicationDidFinishLaunching`.
    static func configure(_ dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// Show the settings window, optionally jumping to a specific tab.
    static func show(tab: SettingsTab? = nil) {
        if let tab {
            SettingsNavigation.shared.selectedTab = tab
        }

        if shared == nil {
            shared = SettingsWindowController()
        }

        shared?.showWindow(nil)
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: CGSize(width: 760, height: 620)),
            styleMask: [
                .titled,
                .closable,
                .resizable,
                .miniaturizable,
                .fullSizeContentView, // Required for liquid glass rounded corners
            ],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)
        configureWindow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureWindow() {
        guard let window else { return }

        window.title = "Settings"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .automatic
        window.isMovableByWindowBackground = true
        window.setFrameAutosaveName("KazeSettingsWindow")
        window.minSize = NSSize(width: 720, height: 560)
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false

        let rootView = SettingsView(dependencies: Self.dependencies)
        window.contentViewController = NSHostingController(rootView: rootView)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        AppActivationPolicy.enter()
    }

    func windowWillClose(_ notification: Notification) {
        AppActivationPolicy.leave()
        Self.shared = nil
    }
}
