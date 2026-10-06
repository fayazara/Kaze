import AppKit
import Carbon.HIToolbox

/// A physical modifier key. Left and right keys are distinct so a lone
/// modifier (e.g. Right ⌥) can be a shortcut without hijacking the other side.
enum ModifierKey: String, Codable, CaseIterable, Hashable {
    case fn
    case leftControl, rightControl
    case leftOption, rightOption
    case leftShift, rightShift
    case leftCommand, rightCommand

    /// Virtual key code reported in `flagsChanged` events for this key.
    var keyCode: Int {
        switch self {
        case .fn: kVK_Function
        case .leftControl: kVK_Control
        case .rightControl: kVK_RightControl
        case .leftOption: kVK_Option
        case .rightOption: kVK_RightOption
        case .leftShift: kVK_Shift
        case .rightShift: kVK_RightShift
        case .leftCommand: kVK_Command
        case .rightCommand: kVK_RightCommand
        }
    }

    /// Device-dependent flag bit (IOKit `NX_DEVICE*KEYMASK`), which tells the
    /// left and right keys apart.
    private var deviceMask: UInt64 {
        switch self {
        case .fn: CGEventFlags.maskSecondaryFn.rawValue
        case .leftControl: 0x0000_0001
        case .rightControl: 0x0000_2000
        case .leftShift: 0x0000_0002
        case .rightShift: 0x0000_0004
        case .leftCommand: 0x0000_0008
        case .rightCommand: 0x0000_0010
        case .leftOption: 0x0000_0020
        case .rightOption: 0x0000_0040
        }
    }

    var generic: GenericModifier {
        switch self {
        case .fn: .fn
        case .leftControl, .rightControl: .control
        case .leftOption, .rightOption: .option
        case .leftShift, .rightShift: .shift
        case .leftCommand, .rightCommand: .command
        }
    }

    init?(keyCode: Int) {
        guard let key = Self.allCases.first(where: { $0.keyCode == keyCode }) else { return nil }
        self = key
    }

    /// The set of modifier keys physically held according to an event's flags.
    static func held(in flags: CGEventFlags) -> Set<ModifierKey> {
        var held = Set<ModifierKey>()
        for key in allCases where flags.rawValue & key.deviceMask != 0 {
            held.insert(key)
        }
        // Some keyboards don't report device-dependent bits; fall back to the
        // generic flags and assume the left key.
        for generic in GenericModifier.allCases where flags.contains(generic.cgFlag) {
            if !held.contains(where: { $0.generic == generic }) {
                held.insert(generic.defaultKey)
            }
        }
        return held
    }

    var symbol: String { generic.symbol }

    var label: String {
        switch self {
        case .fn: "fn"
        case .leftControl, .leftOption, .leftShift, .leftCommand: "Left \(generic.name)"
        case .rightControl, .rightOption, .rightShift, .rightCommand: "Right \(generic.name)"
        }
    }
}

enum GenericModifier: String, Codable, CaseIterable, Hashable {
    case fn, control, option, shift, command

    var cgFlag: CGEventFlags {
        switch self {
        case .fn: .maskSecondaryFn
        case .control: .maskControl
        case .option: .maskAlternate
        case .shift: .maskShift
        case .command: .maskCommand
        }
    }

    var defaultKey: ModifierKey {
        switch self {
        case .fn: .fn
        case .control: .leftControl
        case .option: .leftOption
        case .shift: .leftShift
        case .command: .leftCommand
        }
    }

    var symbol: String {
        switch self {
        case .fn: "fn"
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .command: "⌘"
        }
    }

    var name: String {
        switch self {
        case .fn: "fn"
        case .control: "Control"
        case .option: "Option"
        case .shift: "Shift"
        case .command: "Command"
        }
    }

    static let displayOrder: [GenericModifier] = [.fn, .control, .option, .shift, .command]

    static func set(from flags: CGEventFlags) -> Set<GenericModifier> {
        Set(allCases.filter { flags.contains($0.cgFlag) })
    }

    static func set(from flags: NSEvent.ModifierFlags) -> Set<GenericModifier> {
        var result = Set<GenericModifier>()
        if flags.contains(.function) { result.insert(.fn) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }
}

/// The dictation shortcut: either modifier keys alone (e.g. `fn`, `Right ⌥`)
/// or a regular key with modifiers (e.g. `⌥ Space`).
enum Shortcut: Codable, Equatable, Hashable {
    case modifiers(Set<ModifierKey>)
    case key(code: Int, modifiers: Set<GenericModifier>)

    static let `default` = Shortcut.modifiers([.fn])

    static let suggestions: [Shortcut] = [
        .modifiers([.fn]),
        .modifiers([.rightOption]),
        .modifiers([.rightCommand]),
        .key(code: kVK_Space, modifiers: [.option]),
    ]

    var isValid: Bool {
        switch self {
        case .modifiers(let keys): !keys.isEmpty
        case .key(let code, let modifiers): !modifiers.isEmpty || Self.canStandAlone(code)
        }
    }

    var usesFnKey: Bool {
        switch self {
        case .modifiers(let keys): keys.contains(.fn)
        case .key(_, let modifiers): modifiers.contains(.fn)
        }
    }

    /// Key caps for display, e.g. `["⌥", "Space"]`.
    var keyCaps: [String] {
        switch self {
        case .modifiers(let keys):
            let sorted = keys.sorted { lhs, rhs in
                (GenericModifier.displayOrder.firstIndex(of: lhs.generic) ?? 0) < (GenericModifier.displayOrder.firstIndex(of: rhs.generic) ?? 0)
            }
            if sorted.count == 1, let key = sorted.first {
                switch key {
                case .fn: return ["fn"]
                case .rightControl, .rightOption, .rightShift, .rightCommand: return ["Right \(key.symbol)"]
                default: return [key.symbol]
                }
            }
            return sorted.map(\.symbol)
        case .key(let code, let modifiers):
            return GenericModifier.displayOrder.filter(modifiers.contains).map(\.symbol) + [Self.keyName(for: code)]
        }
    }

    var displayName: String {
        switch self {
        case .modifiers(let keys) where keys.count == 1:
            keys.first!.label
        default:
            keyCaps.joined(separator: " ")
        }
    }

    static func keyName(for keyCode: Int) -> String {
        switch keyCode {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_F13: return "F13"
        case kVK_F14: return "F14"
        case kVK_F15: return "F15"
        case kVK_F16: return "F16"
        case kVK_F17: return "F17"
        case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        default:
            return characterName(for: keyCode) ?? "Key \(keyCode)"
        }
    }

    /// Function keys work on their own; everything else needs a modifier so
    /// the shortcut doesn't swallow normal typing.
    static func canStandAlone(_ keyCode: Int) -> Bool {
        [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
         kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19].contains(keyCode)
    }

    /// Uses the current keyboard layout so e.g. AZERTY users see their letters.
    private static func characterName(for keyCode: Int) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let string = String(utf16CodeUnits: chars, count: length).uppercased()
        return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : string
    }
}
