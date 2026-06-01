import Foundation
import Combine

enum TranscriptionEngine: String, CaseIterable, Identifiable {
    case dictation
    case whisper
    case parakeet

    static let onboardingOrder: [Self] = [.parakeet, .whisper, .dictation]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: return "Direct Dictation"
        case .whisper: return "Whisper (OpenAI)"
        case .parakeet: return "Parakeet v3 (NVIDIA)"
        }
    }

    var description: String {
        switch self {
        case .dictation: return "Uses Apple's built-in speech recognition. Works immediately with no setup."
        case .whisper: return "Uses OpenAI's Whisper model running locally on your Mac. Requires a one-time download."
        case .parakeet: return "NVIDIA's Parakeet TDT 0.6B v3 via CoreML. Top-ranked accuracy, blazing fast. English only."
        }
    }

    var onboardingDescription: String {
        switch self {
        case .parakeet:
            return "Best accuracy, blazing fast. English only. ~600 MB download."
        case .whisper:
            return "OpenAI's Whisper running locally. Multiple sizes available."
        case .dictation:
            return "Apple's built-in speech recognition. No download required."
        }
    }

    var requiresModelDownload: Bool {
        switch self {
        case .dictation:
            return false
        case .whisper, .parakeet:
            return true
        }
    }

    func isModelReady(
        whisperManager: WhisperModelManager,
        parakeetManager: FluidAudioModelManager
    ) -> Bool {
        switch self {
        case .dictation:
            return true
        case .whisper:
            return whisperManager.isAvailableForTranscription
        case .parakeet:
            return parakeetManager.isAvailableForTranscription
        }
    }

    func isModelDownloading(
        whisperManager: WhisperModelManager,
        parakeetManager: FluidAudioModelManager
    ) -> Bool {
        switch self {
        case .dictation:
            return false
        case .whisper:
            return whisperManager.isDownloading
        case .parakeet:
            return parakeetManager.isDownloading
        }
    }
}

enum HotkeyMode: String, CaseIterable, Identifiable {
    case holdToTalk
    case toggle
    case hybrid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .holdToTalk: return "Hold to Talk"
        case .toggle: return "Press to Toggle"
        case .hybrid: return "Hybrid"
        }
    }

    var description: String {
        switch self {
        case .holdToTalk: return "Hold the hotkey to record, release to stop."
        case .toggle: return "Press the hotkey once to start, press again to stop."
        case .hybrid: return "Hold the hotkey to record, or double-press it to toggle recording on and off."
        }
    }
}

// MARK: - Cloud AI Provider & Models

enum CloudAIProvider: String, CaseIterable, Identifiable {
    case openAI
    case google
    case anthropic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAI: return "OpenAI"
        case .google: return "Google Gemini"
        case .anthropic: return "Anthropic Claude"
        }
    }

    /// The Keychain account identifier for this provider's API key.
    var keychainAccount: String {
        "cloudai-apikey-\(rawValue)"
    }

    /// The reasoning effort level to pass in the request, or nil if unsupported.
    /// OpenAI: "low" disables deep reasoning on reasoning-capable models.
    /// Anthropic/Google: nil (not supported by the app's direct provider requests).
    var reasoningEffort: String? {
        switch self {
        case .openAI: return "low"
        case .google, .anthropic: return nil
        }
    }

    /// URL for the user to obtain an API key.
    var apiKeyURL: URL? {
        switch self {
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")
        case .google: return URL(string: "https://aistudio.google.com/apikey")
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")
        }
    }

    /// Available models for this provider.
    var models: [CloudAIModel] {
        switch self {
        case .openAI:
            return [
                CloudAIModel(id: "gpt-5.4", title: "GPT-5.4", provider: .openAI),
                CloudAIModel(id: "gpt-5.4-mini", title: "GPT-5.4 Mini", provider: .openAI),
                CloudAIModel(id: "gpt-5.4-nano", title: "GPT-5.4 Nano", provider: .openAI),
            ]
        case .google:
            return [
                CloudAIModel(id: "gemini-3.1-pro-preview", title: "Gemini 3.1 Pro", provider: .google),
                CloudAIModel(id: "gemini-3-flash-preview", title: "Gemini 3 Flash", provider: .google),
                CloudAIModel(id: "gemini-3.1-flash-lite-preview", title: "Gemini 3.1 Flash Lite", provider: .google),
            ]
        case .anthropic:
            return [
                CloudAIModel(id: "claude-sonnet-4-6", title: "Claude Sonnet 4.6", provider: .anthropic),
                CloudAIModel(id: "claude-opus-4-6", title: "Claude Opus 4.6", provider: .anthropic),
                CloudAIModel(id: "claude-haiku-4-5", title: "Claude Haiku 4.5", provider: .anthropic),
            ]
        }
    }

    /// The default (first) model for this provider.
    var defaultModel: CloudAIModel {
        models[0]
    }

    /// Converts older provider-prefixed model IDs into native provider IDs.
    func nativeModelID(from modelID: String) -> String {
        let prefixes: [String]

        switch self {
        case .openAI:
            prefixes = ["openai/"]
        case .google:
            prefixes = ["google-ai-studio/"]
        case .anthropic:
            prefixes = ["anthropic/"]
        }

        for prefix in prefixes where modelID.hasPrefix(prefix) {
            return String(modelID.dropFirst(prefix.count))
        }

        return modelID
    }

    /// Returns a picker-safe native model ID, falling back to the provider default
    /// when a stale value belongs to a different provider.
    func supportedModelID(from modelID: String) -> String {
        let nativeID = nativeModelID(from: modelID)
        return models.contains { $0.id == nativeID } ? nativeID : defaultModel.id
    }
}

struct CloudAIModel: Identifiable, Equatable, Hashable {
    let id: String
    let title: String
    let provider: CloudAIProvider
}
