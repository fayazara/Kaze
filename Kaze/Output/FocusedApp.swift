import AppKit
import ApplicationServices

/// Finds the app that really has keyboard focus.
///
/// `NSWorkspace.frontmostApplication` reports the *active* app, which isn't
/// always where typing goes: drop-down terminals such as Ghostty's quick
/// terminal ("visor") take keyboard focus in a panel without activating
/// their app, so the app underneath still counts as frontmost. The
/// Accessibility system-wide element knows the real focus owner.
enum FocusedApp {
    static func current() -> NSRunningApplication? {
        accessibilityFocused() ?? NSWorkspace.shared.frontmostApplication
    }

    /// The focus owner according to Accessibility, or `nil` if it can't be read.
    static func accessibilityFocused() -> NSRunningApplication? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(value as! AXUIElement, &pid) == .success, pid > 0 else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }
}
