import Foundation
import Observation

/// How the shortcut drives a dictation session.
enum ActivationMode: String, CaseIterable, Identifiable, Codable {
    /// Hold to talk, or tap once to keep listening hands-free until the next tap.
    case automatic
    /// Recording lasts exactly as long as the shortcut is held.
    case hold
    /// Each press starts or stops recording.
    case toggle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Hold or Tap"
        case .hold: "Hold to Talk"
        case .toggle: "Tap to Toggle"
        }
    }

    var shortTitle: String {
        switch self {
        case .automatic: "Hold or Tap"
        case .hold: "Hold"
        case .toggle: "Toggle"
        }
    }

    var symbol: String {
        switch self {
        case .automatic: "hand.tap"
        case .hold: "hand.point.down"
        case .toggle: "switch.2"
        }
    }

    var detail: String {
        switch self {
        case .automatic: "Hold the shortcut while you speak, or tap it once to go hands-free and tap again to finish."
        case .hold: "Recording lasts exactly as long as you hold the shortcut."
        case .toggle: "Tap once to start, tap again to finish."
        }
    }
}

/// Register used by the S1-mini formatter. Values map 1:1 onto the model's
/// trained `Styling` control values.
enum FormatStyle: String, CaseIterable, Identifiable, Codable {
    case casual
    case semiCasual = "semi-casual"
    case semiFormal = "semi-formal"
    case formal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .casual: "Casual"
        case .semiCasual: "Relaxed"
        case .semiFormal: "Standard"
        case .formal: "Formal"
        }
    }

    /// Output of the S1-mini model card for the same input in each register,
    /// used as a static preview in Settings.
    var example: String {
        switch self {
        case .casual: "hmm im gonna be late. theres a cute dog outside. i cant just walk past him"
        case .semiCasual: "hmm, I'm gonna be late. there's a cute dog outside. I can't just walk past him"
        case .semiFormal: "I'm going to be late. There's a cute dog outside. I can't just walk past him."
        case .formal: "I am going to be late. There is a cute dog outside. I cannot just walk past him."
        }
    }
}

/// All user-facing settings, persisted to `UserDefaults`.
@Observable
final class Preferences {
    static let shared = Preferences()

    private enum Key {
        static let speechModel = "v1.speechModel"
        static let language = "v1.language"
        static let shortcut = "v1.shortcut"
        static let activationMode = "v1.activationMode"
        static let microphoneID = "v1.microphoneID"
        static let formattingEnabled = "v1.formattingEnabled"
        static let cleanUpEngine = "v1.cleanUpEngine"
        static let chatGPTModel = "v1.chatGPTModel"
        static let chatGPTReasoning = "v1.chatGPTReasoning"
        static let formatStyle = "v1.formatStyle"
        static let allowLists = "v1.allowLists"
        static let emailInMailApps = "v1.emailInMailApps"
        static let restoreClipboard = "v1.restoreClipboard"
        static let addTrailingSpace = "v1.addTrailingSpace"
        static let playSounds = "v1.playSounds"
        static let showLivePreview = "v1.showLivePreview"
        static let saveHistory = "v1.saveHistory"
        static let keepRecordings = "v1.keepRecordings"
        static let hasCompletedOnboarding = "v1.hasCompletedOnboarding"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var speechModel: SpeechModel { didSet { defaults.set(speechModel.rawValue, forKey: Key.speechModel) } }
    /// BCP-47 language code, or `nil` to follow the system language.
    var language: String? { didSet { defaults.set(language, forKey: Key.language) } }
    var shortcut: Shortcut { didSet { defaults.set(try? JSONEncoder().encode(shortcut), forKey: Key.shortcut) } }
    var activationMode: ActivationMode { didSet { defaults.set(activationMode.rawValue, forKey: Key.activationMode) } }
    /// Capture device unique ID, or `nil` for the system default input.
    var microphoneID: String? { didSet { defaults.set(microphoneID, forKey: Key.microphoneID) } }
    var formattingEnabled: Bool { didSet { defaults.set(formattingEnabled, forKey: Key.formattingEnabled) } }
    var cleanUpEngine: CleanUpEngine { didSet { defaults.set(cleanUpEngine.rawValue, forKey: Key.cleanUpEngine) } }
    /// Model slug from the user's ChatGPT plan, or `nil` for the default.
    var chatGPTModel: String? { didSet { defaults.set(chatGPTModel, forKey: Key.chatGPTModel) } }
    /// Reasoning effort for ChatGPT Clean Up, or `nil` for the model's lightest.
    var chatGPTReasoning: String? { didSet { defaults.set(chatGPTReasoning, forKey: Key.chatGPTReasoning) } }
    var formatStyle: FormatStyle { didSet { defaults.set(formatStyle.rawValue, forKey: Key.formatStyle) } }
    var allowLists: Bool { didSet { defaults.set(allowLists, forKey: Key.allowLists) } }
    var emailInMailApps: Bool { didSet { defaults.set(emailInMailApps, forKey: Key.emailInMailApps) } }
    var restoreClipboard: Bool { didSet { defaults.set(restoreClipboard, forKey: Key.restoreClipboard) } }
    var addTrailingSpace: Bool { didSet { defaults.set(addTrailingSpace, forKey: Key.addTrailingSpace) } }
    var playSounds: Bool { didSet { defaults.set(playSounds, forKey: Key.playSounds) } }
    var showLivePreview: Bool { didSet { defaults.set(showLivePreview, forKey: Key.showLivePreview) } }
    var saveHistory: Bool { didSet { defaults.set(saveHistory, forKey: Key.saveHistory) } }
    /// Keep the audio of transcribed dictations too, not only failed ones.
    var keepRecordings: Bool { didSet { defaults.set(keepRecordings, forKey: Key.keepRecordings) } }
    var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.formattingEnabled: false,
            Key.allowLists: true,
            Key.emailInMailApps: true,
            Key.restoreClipboard: true,
            Key.addTrailingSpace: true,
            Key.playSounds: true,
            Key.showLivePreview: true,
            Key.saveHistory: true,
        ])

        speechModel = SpeechModel(rawValue: defaults.string(forKey: Key.speechModel) ?? "") ?? .apple
        language = defaults.string(forKey: Key.language)
        shortcut = defaults.data(forKey: Key.shortcut).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .default
        activationMode = ActivationMode(rawValue: defaults.string(forKey: Key.activationMode) ?? "") ?? .automatic
        microphoneID = defaults.string(forKey: Key.microphoneID)
        formattingEnabled = defaults.bool(forKey: Key.formattingEnabled)
        // On-device by default; ChatGPT only when the user opts in.
        cleanUpEngine = CleanUpEngine(rawValue: defaults.string(forKey: Key.cleanUpEngine) ?? "") ?? .s1Mini
        chatGPTModel = defaults.string(forKey: Key.chatGPTModel)
        chatGPTReasoning = defaults.string(forKey: Key.chatGPTReasoning)
        formatStyle = FormatStyle(rawValue: defaults.string(forKey: Key.formatStyle) ?? "") ?? .semiFormal
        allowLists = defaults.bool(forKey: Key.allowLists)
        emailInMailApps = defaults.bool(forKey: Key.emailInMailApps)
        restoreClipboard = defaults.bool(forKey: Key.restoreClipboard)
        addTrailingSpace = defaults.bool(forKey: Key.addTrailingSpace)
        playSounds = defaults.bool(forKey: Key.playSounds)
        showLivePreview = defaults.bool(forKey: Key.showLivePreview)
        saveHistory = defaults.bool(forKey: Key.saveHistory)
        keepRecordings = defaults.bool(forKey: Key.keepRecordings)
        hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
    }
}
