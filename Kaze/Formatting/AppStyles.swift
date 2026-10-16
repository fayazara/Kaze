import AppKit

/// How Clean Up writes for one app: one of the four registers, or Code for
/// editors and terminals.
enum AppStyle: String, CaseIterable, Identifiable, Codable {
    case casual
    case semiCasual
    case semiFormal
    case formal
    case code

    var id: String { rawValue }

    init(_ style: FormatStyle) {
        switch style {
        case .casual: self = .casual
        case .semiCasual: self = .semiCasual
        case .semiFormal: self = .semiFormal
        case .formal: self = .formal
        }
    }

    var title: String {
        switch self {
        case .code: "Code"
        default: formatStyle.title
        }
    }

    /// The register to clean up in. Code keeps the speaker's relaxed phrasing,
    /// since it's mostly prompts, comments and commit messages.
    var formatStyle: FormatStyle {
        switch self {
        case .casual: .casual
        case .semiCasual, .code: .semiCasual
        case .semiFormal: .semiFormal
        case .formal: .formal
        }
    }
}

/// A style the user picked for one app.
struct AppStyleRule: Codable, Identifiable, Hashable {
    var bundleID: String
    var name: String
    var style: AppStyle

    var id: String { bundleID }

    var icon: NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}

enum AppStyleSuggestions {
    /// Well-known apps and the style that suits them.
    static let all: [(bundleID: String, style: AppStyle)] = [
        // Chat
        ("com.apple.MobileSMS", .semiCasual),
        ("com.tinyspeck.slackmacgap", .semiCasual),
        ("net.whatsapp.WhatsApp", .semiCasual),
        ("com.hnc.Discord", .casual),
        ("ru.keepcoder.Telegram", .semiCasual),
        ("com.microsoft.teams2", .semiCasual),
        // Mail
        ("com.apple.mail", .semiFormal),
        ("com.microsoft.Outlook", .semiFormal),
        ("com.superhuman.electron", .semiFormal),
        // Code
        ("com.apple.dt.Xcode", .code),
        ("com.microsoft.VSCode", .code),
        ("com.todesktop.230313mzl4w4u92", .code),   // Cursor
        ("dev.zed.Zed", .code),
        ("com.apple.Terminal", .code),
        ("com.mitchellh.ghostty", .code),
        ("com.googlecode.iterm2", .code),
        ("dev.warp.Warp-Stable", .code),
    ]

    /// Suggestions for apps installed on this Mac that have no rule yet.
    static func available(excluding rules: [AppStyleRule]) -> [AppStyleRule] {
        let taken = Set(rules.map(\.bundleID))
        return all.compactMap { suggestion in
            guard !taken.contains(suggestion.bundleID),
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: suggestion.bundleID) else { return nil }
            return AppStyleRule(bundleID: suggestion.bundleID, name: appName(at: url), style: suggestion.style)
        }
    }

    static func appName(at url: URL) -> String {
        let bundle = Bundle(url: url)
        return bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
    }
}
