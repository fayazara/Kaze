import AppKit
import SwiftUI

/// Hosts the island in a fixed-size, click-through panel pinned to the top
/// center of the active screen. The window never moves or resizes; only the
/// SwiftUI shape inside it animates, which keeps the motion perfectly smooth.
final class IslandWindowController {
    private let dictation: DictationController
    private let presentation = IslandPresentation()
    private let panel: NSPanel
    private var hideTask: Task<Void, Never>?

    private static let canvasSize = CGSize(width: 720, height: 220)

    init(dictation: DictationController) {
        self.dictation = dictation
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.canvasSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        // Above the menu bar so the island can grow out of the notch.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let host = NSHostingView(rootView: IslandView(dictation: dictation, presentation: presentation))
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: Self.canvasSize)
        panel.contentView = host

        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = dictation.phase
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
    }

    private func update() {
        if dictation.phase == .idle {
            dismiss()
        } else {
            present()
        }
    }

    private func present() {
        hideTask?.cancel()
        hideTask = nil
        guard !presentation.isPresented else { return }

        let screen = NSScreen.main ?? NSScreen.screens.first
        if let screen {
            presentation.geometry = IslandGeometry.forScreen(screen)
            let frame = screen.frame
            panel.setFrame(CGRect(x: frame.midX - Self.canvasSize.width / 2,
                                  y: frame.maxY - Self.canvasSize.height,
                                  width: Self.canvasSize.width,
                                  height: Self.canvasSize.height), display: false)
        }
        panel.orderFrontRegardless()
        // Let the closed (notch-sized) layout render first, then grow from it.
        DispatchQueue.main.async { [presentation] in
            presentation.isPresented = true
        }
    }

    private func dismiss() {
        guard presentation.isPresented else { return }
        presentation.isPresented = false
        hideTask?.cancel()
        hideTask = Task { [panel] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
        }
    }
}
