import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Reads the text selected in the focused app, for voice edits.
enum SelectionReader {
    /// The selection, or `nil` when nothing is selected or it can't be read.
    static func read() async -> String? {
        switch accessibilitySelection() {
        case .text(let text): return text.isEmpty ? nil : text
        case .unsupported: return await copySelection()
        }
    }

    private enum AXResult {
        case text(String)
        /// The focused element doesn't expose its selection (common in
        /// Electron apps and browsers' web content).
        case unsupported
    }

    private static func accessibilitySelection() -> AXResult {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return .unsupported }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String else { return .unsupported }
        return .text(text)
    }

    /// Falls back to ⌘C, then puts the clipboard back the way it was.
    private static func copySelection() async -> String? {
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        let before = pasteboard.changeCount
        postCommandC()

        // Apps answer ⌘C within a few frames; with no selection nothing changes.
        var text: String?
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(20))
            guard pasteboard.changeCount != before else { continue }
            // VS Code and friends copy the whole line when nothing is
            // selected, and mark it as such; that isn't a selection.
            if let data = pasteboard.data(forType: NSPasteboard.PasteboardType("vscode-editor-data")),
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               json["isFromEmptySelection"] as? Bool == true {
                break
            }
            text = pasteboard.string(forType: .string)
            break
        }
        if pasteboard.changeCount != before {
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    private static func postCommandC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCode = CGKeyCode(TextInserter.keyCode(for: "c", fallback: kVK_ANSI_C))
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
