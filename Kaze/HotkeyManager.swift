import Foundation
import Carbon
import AppKit
import os

/// Monitors a configurable global hotkey via a CGEvent tap.
/// Supports two modes:
/// - **Hold to Talk**: Press and hold both keys → `onKeyDown`; release either → `onKeyUp`
/// - **Toggle**: First press of combo → `onKeyDown`; second press → `onKeyUp`
@MainActor
class HotkeyManager {
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    /// The current hotkey mode. Can be changed at runtime.
    var mode: HotkeyMode = .holdToTalk
    var shortcut: HotkeyShortcut = .default {
        didSet { updateFilterSnapshot() }
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isKeyDown = false

    /// Tracks whether a toggle session is active (only used in toggle mode).
    private var isToggleActive = false

    /// `true` if the event tap was successfully created (i.e. Accessibility permission is granted).
    private(set) var isAccessibilityGranted = false

    // MARK: - Early event filtering (Fix: CPU heating when idle)
    //
    // The CGEvent tap callback fires on an arbitrary thread for *every* keyboard
    // event system-wide. Previously, every event was dispatched to the main queue
    // even when it couldn't possibly match the configured hotkey. This kept the
    // main thread constantly awake, preventing the CPU from entering low-power
    // states and causing the laptop to heat up even when idle.
    //
    // The fix: store a lightweight snapshot of the hotkey filter criteria that can
    // be safely read from the event tap's thread. The callback checks the snapshot
    // and only dispatches to main when the event could plausibly be the hotkey.
    // This eliminates ~95%+ of unnecessary main queue wake-ups.

    /// Lightweight, thread-safe snapshot of the hotkey's filter criteria.
    /// Read from the event tap callback thread; written only from the main thread.
    private struct FilterSnapshot: Sendable {
        /// The expected key code, or `nil` for modifier-only shortcuts.
        let keyCode: Int32
        /// Whether this is a modifier-only shortcut (no key code).
        let isModifierOnly: Bool
        /// The required modifier flags as a raw CGEventFlags value.
        let requiredModifierFlags: UInt64
        /// Mask of all modifier flags we care about (to ignore irrelevant bits).
        let supportedFlagsMask: UInt64
        /// Whether the shortcut is valid at all.
        let isValid: Bool

        static let empty = FilterSnapshot(
            keyCode: -1, isModifierOnly: true,
            requiredModifierFlags: 0, supportedFlagsMask: 0, isValid: false
        )
    }

    /// Thread-safe filter snapshot. Written on main thread, read from the event
    /// tap callback thread. Uses OSAllocatedUnfairLock for safe cross-thread access.
    private let filterLock = OSAllocatedUnfairLock(initialState: FilterSnapshot.empty)

    /// Updates the filter snapshot from the current shortcut. Called on main thread.
    private func updateFilterSnapshot() {
        let s = shortcut
        let snapshot = FilterSnapshot(
            keyCode: Int32(s.keyCode ?? -1),
            isModifierOnly: s.keyCode == nil,
            requiredModifierFlags: s.modifiers.cgEventFlags.rawValue,
            supportedFlagsMask: HotkeyShortcut.Modifiers.supportedCGFlagsMask.rawValue,
            isValid: s.isValid
        )
        filterLock.withLock { $0 = snapshot }
    }

    /// Returns `true` if the app currently has Accessibility permission.
    static func checkAccessibilityPermission() -> Bool {
        return AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        )
    }

    @discardableResult
    func start() -> Bool {
        // Ensure the filter snapshot is current before starting the tap.
        updateFilterSnapshot()

        let eventMask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()

                // --- Early filter: discard events that cannot match the hotkey ---
                // This runs on the event tap's thread, avoiding a main queue dispatch
                // for the vast majority of system keyboard events.
                let snapshot = manager.filterLock.withLock { $0 }
                guard snapshot.isValid else { return Unmanaged.passUnretained(event) }

                if snapshot.isModifierOnly {
                    // Modifier-only shortcut: only flagsChanged events matter.
                    guard type == .flagsChanged else { return Unmanaged.passUnretained(event) }
                } else {
                    // Key-based shortcut: check the event type and key code.
                    switch type {
                    case .keyDown, .keyUp:
                        let eventKeyCode = Int32(event.getIntegerValueField(.keyboardEventKeycode))
                        guard eventKeyCode == snapshot.keyCode else {
                            return Unmanaged.passUnretained(event)
                        }
                        // Also check that at least one of the required modifiers is present
                        // (avoids dispatching for every press of the hotkey's letter key
                        // without modifiers, e.g. pressing "K" while typing normally).
                        if snapshot.requiredModifierFlags != 0 {
                            let relevantFlags = event.flags.rawValue & snapshot.supportedFlagsMask
                            // For keyDown, require exact modifier match.
                            // For keyUp, allow dispatch even if modifiers were released
                            // (the user may release the modifier before the key).
                            if type == .keyDown && relevantFlags != snapshot.requiredModifierFlags {
                                return Unmanaged.passUnretained(event)
                            }
                        }
                    case .flagsChanged:
                        // In key-based mode, flagsChanged only matters when the key is
                        // already held (to detect modifier release during hold-to-talk).
                        // We can't cheaply check isKeyDown here without a lock, so let
                        // these through — they're infrequent compared to keyDown/keyUp.
                        break
                    default:
                        return Unmanaged.passUnretained(event)
                    }
                }

                manager.handleEvent(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("[HotkeyManager] Failed to create event tap. Grant Accessibility permission.")
            isAccessibilityGranted = false
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isAccessibilityGranted = true
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    /// Called from the CGEvent tap callback after the early filter passes.
    /// Dispatches all mutable state access and callbacks to the main queue
    /// to avoid data races with @MainActor-isolated properties. (Fix #2)
    private func handleEvent(type: CGEventType, event: CGEvent) {
        DispatchQueue.main.async { [self] in
            let currentShortcut = shortcut
            guard currentShortcut.isValid else { return }

            if let keyCode = currentShortcut.keyCode {
                handleKeyBasedShortcut(type: type, event: event, keyCode: keyCode, shortcut: currentShortcut)
            } else {
                handleModifierOnlyShortcut(type: type, event: event, shortcut: currentShortcut)
            }
        }
    }

    private func handleModifierOnlyShortcut(type: CGEventType, event: CGEvent, shortcut: HotkeyShortcut) {
        guard type == .flagsChanged else { return }
        let comboIsDown = shortcut.matchesExactModifiers(event.flags)

        switch mode {
        case .holdToTalk:
            if comboIsDown && !isKeyDown {
                isKeyDown = true
                onKeyDown?()
            } else if !comboIsDown && isKeyDown {
                isKeyDown = false
                onKeyUp?()
            }

        case .toggle:
            // Detect the rising edge: combo was not pressed, now it is
            if comboIsDown && !isKeyDown {
                isKeyDown = true
                if !isToggleActive {
                    // First press: start recording
                    isToggleActive = true
                    onKeyDown?()
                } else {
                    // Second press: stop recording
                    isToggleActive = false
                    onKeyUp?()
                }
            } else if !comboIsDown && isKeyDown {
                // Keys released — just reset the edge detector, don't fire callbacks
                isKeyDown = false
            }
        }
    }

    private func handleKeyBasedShortcut(type: CGEventType, event: CGEvent, keyCode: Int, shortcut: HotkeyShortcut) {
        let eventKeyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        switch type {
        case .keyDown:
            // Ignore key repeat so hold mode doesn't retrigger.
            let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) == 1
            guard !isAutoRepeat else { return }
            guard eventKeyCode == keyCode else { return }
            guard shortcut.matchesExactModifiers(event.flags) else { return }

            switch mode {
            case .holdToTalk:
                guard !isKeyDown else { return }
                isKeyDown = true
                onKeyDown?()
            case .toggle:
                guard !isKeyDown else { return }
                isKeyDown = true
                if !isToggleActive {
                    isToggleActive = true
                    onKeyDown?()
                } else {
                    isToggleActive = false
                    onKeyUp?()
                }
            }

        case .keyUp:
            guard eventKeyCode == keyCode else { return }
            if mode == .holdToTalk && isKeyDown {
                isKeyDown = false
                onKeyUp?()
            } else if mode == .toggle {
                isKeyDown = false
            }

        case .flagsChanged:
            // If modifier state changes while the key is held in hold mode,
            // stop as soon as the configured modifiers are no longer held.
            guard mode == .holdToTalk, isKeyDown else { return }
            if !shortcut.matchesExactModifiers(event.flags) {
                isKeyDown = false
                onKeyUp?()
            }

        default:
            return
        }
    }
}
