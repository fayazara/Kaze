import AppKit
import SwiftUI

/// Click to record a new shortcut. Accepts modifier keys alone (fn, Right ⌥,
/// ⌥⌘…) or a key with modifiers. Escape cancels.
struct ShortcutRecorderView: View {
    let shortcut: Shortcut
    /// Large centered key caps with a separate Change button, for onboarding.
    var prominent = false
    let onChange: (Shortcut) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var heldMax = Set<ModifierKey>()
    @State private var liveHeld = Set<ModifierKey>()

    var body: some View {
        if prominent { heroBody } else { compactBody }
    }

    private var heroBody: some View {
        VStack(spacing: 14) {
            ZStack {
                if isRecording && liveHeld.isEmpty {
                    Text("Press the keys you want to use")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                        .transition(.blurReplace)
                } else {
                    ShortcutCaps(shortcut: isRecording ? .modifiers(liveHeld) : shortcut, size: .large)
                        .transition(.blurReplace)
                }
            }
            .frame(height: 56)
            .motion(.kazeQuick, value: liveHeld)
            .motion(value: isRecording)

            GlassCapsuleButton(title: isRecording ? "Cancel" : "Change Shortcut",
                               systemImage: isRecording ? "xmark" : "keyboard",
                               height: 30) {
                isRecording ? stopRecording() : startRecording()
            }
        }
        .onDisappear { stopRecording() }
    }

    private var compactBody: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .trailing) {
                if isRecording && liveHeld.isEmpty {
                    Text("Press keys…")
                        .foregroundStyle(.secondary)
                        .transition(.blurReplace)
                } else {
                    ShortcutCaps(shortcut: isRecording ? .modifiers(liveHeld) : shortcut)
                        .transition(.blurReplace)
                }
            }
            .motion(.kazeQuick, value: liveHeld)
            .motion(value: isRecording)

            GlassCapsuleButton(title: isRecording ? "Cancel" : "Change", height: 28) {
                isRecording ? stopRecording() : startRecording()
            }
        }
        .onDisappear { stopRecording() }
        .help("Click Change, then press the keys you want to use")
    }

    private func startRecording() {
        isRecording = true
        heldMax = []
        liveHeld = []
        AppModel.shared.dictation.isPaused = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            handle(event)
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        liveHeld = []
        AppModel.shared.dictation.isPaused = false
    }

    private func handle(_ event: NSEvent) {
        let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
        switch event.type {
        case .flagsChanged:
            let held = ModifierKey.held(in: flags)
            liveHeld = held
            if held.isEmpty {
                // All modifiers released without another key: modifier-only shortcut.
                if !heldMax.isEmpty { finish(.modifiers(heldMax)) }
            } else {
                heldMax.formUnion(held)
            }
        case .keyDown:
            if event.keyCode == 53, heldMax.isEmpty {   // Escape
                stopRecording()
                return
            }
            let modifiers = GenericModifier.set(from: event.modifierFlags).subtracting(Shortcut.canStandAlone(Int(event.keyCode)) ? [.fn] : [])
            let candidate = Shortcut.key(code: Int(event.keyCode), modifiers: modifiers)
            if candidate.isValid {
                finish(candidate)
            } else {
                NSSound.beep()
            }
        default:
            break
        }
    }

    private func finish(_ new: Shortcut) {
        stopRecording()
        onChange(new)
    }
}
