import AppKit
import Carbon.HIToolbox
import os

/// Watches the keyboard system-wide through a Core Graphics event tap and
/// reports raw shortcut transitions. Interpreting them (hold vs. tap) is the
/// dictation controller's job, so all session logic lives in one place.
final class HotkeyMonitor {
    enum Event {
        /// The shortcut went down.
        case pressed
        /// The shortcut came back up.
        case released
        /// Another key was typed while a modifier-only shortcut was held,
        /// meaning the user was typing a chord such as fn+← rather than dictating.
        case interrupted
        /// Escape was pressed while `capturesEscape` is on.
        case escape
    }

    var onEvent: ((Event) -> Void)?

    var shortcut: Shortcut = .default {
        didSet { if oldValue != shortcut { isDown = false } }
    }

    /// While a session is active, Escape cancels it instead of reaching the
    /// frontmost app (when the tap is allowed to filter events).
    var capturesEscape = false

    private(set) var isRunning = false
    /// `false` when macOS only granted a listen-only tap, so keys can't be swallowed.
    private(set) var canFilterEvents = false

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isDown = false
    private let log = Logger(subsystem: "com.fayazahmed.Kaze", category: "Hotkey")

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        // Prefer an active tap so the shortcut's own keystrokes (e.g. ⌥Space)
        // and Escape-to-cancel don't leak into the frontmost app.
        if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                       eventsOfInterest: mask, callback: hotkeyTapCallback, userInfo: refcon) {
            self.tap = tap
            canFilterEvents = true
        } else if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                              eventsOfInterest: mask, callback: hotkeyTapCallback, userInfo: refcon) {
            self.tap = tap
            canFilterEvents = false
        } else {
            log.error("Could not create event tap; Accessibility permission is missing")
            return false
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap!, enable: true)
        isRunning = true
        log.info("Event tap started (filtering: \(self.canFilterEvents))")
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        isRunning = false
        isDown = false
    }

    /// Returns `true` to swallow the event.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        // macOS disables taps whose callbacks are slow or when secure input
        // toggles. Without re-enabling, the shortcut silently stops working.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            log.notice("Event tap was disabled by the system; re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            isDown = false
            return false
        }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))

        if type == .keyDown, keyCode == kVK_Escape, capturesEscape {
            onEvent?(.escape)
            return canFilterEvents
        }

        switch shortcut {
        case .modifiers(let keys):
            return handleModifierShortcut(keys, type: type, event: event)
        case .key(let code, let modifiers):
            return handleKeyShortcut(code: code, modifiers: modifiers, type: type, event: event, keyCode: keyCode)
        }
    }

    private func handleModifierShortcut(_ keys: Set<ModifierKey>, type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .flagsChanged:
            let held = ModifierKey.held(in: event.flags)
            if !isDown, held == keys {
                isDown = true
                onEvent?(.pressed)
            } else if isDown, !keys.isSubset(of: held) {
                isDown = false
                onEvent?(.released)
            }
        case .keyDown:
            if isDown { onEvent?(.interrupted) }
        default:
            break
        }
        return false
    }

    private func handleKeyShortcut(code: Int, modifiers: Set<GenericModifier>, type: CGEventType, event: CGEvent, keyCode: Int) -> Bool {
        switch type {
        case .keyDown where keyCode == code:
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                return isDown && canFilterEvents
            }
            guard Self.modifiersMatch(modifiers, event.flags) else { return false }
            if !isDown {
                isDown = true
                onEvent?(.pressed)
            }
            return canFilterEvents
        case .keyUp where keyCode == code:
            guard isDown else { return false }
            isDown = false
            onEvent?(.released)
            return canFilterEvents
        case .flagsChanged:
            // Letting go of the modifiers before the key still ends the hold.
            if isDown, !modifiers.isSubset(of: GenericModifier.set(from: event.flags)) {
                isDown = false
                onEvent?(.released)
            }
            return false
        default:
            return false
        }
    }

    /// Arrow and function keys carry the fn flag implicitly, so fn is only
    /// compared when the shortcut itself uses it.
    private static func modifiersMatch(_ required: Set<GenericModifier>, _ flags: CGEventFlags) -> Bool {
        var actual = GenericModifier.set(from: flags)
        if !required.contains(.fn) { actual.remove(.fn) }
        return actual == required
    }

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }
}

nonisolated private func hotkeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    // The tap's run loop source is on the main run loop.
    let swallow = MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
