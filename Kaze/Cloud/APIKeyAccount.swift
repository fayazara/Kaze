import Foundation
import Observation
import os

/// A cloud model the user reaches with their own API key.
nonisolated struct CloudModel: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let note: String
}

/// A provider Clean Up talks to with a key the user pastes in. Neither
/// Anthropic nor Google lets third-party apps sign in to the user's
/// subscription, so these are bring-your-own-key and billed to the user's
/// own API account.
nonisolated enum KeyProvider: String, Sendable {
    case anthropic
    case google

    var name: String {
        switch self {
        case .anthropic: "Anthropic"
        case .google: "Google"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .anthropic: "sk-ant-…"
        case .google: "AIza…"
        }
    }

    /// Where the user creates a key.
    var consoleURL: URL {
        switch self {
        case .anthropic: URL(string: "https://platform.claude.com/settings/keys")!
        case .google: URL(string: "https://aistudio.google.com/apikey")!
        }
    }

    /// Lightest first; the first is the default. Cleanup is mechanical, so
    /// the smallest model is as good as the big ones here, and much faster.
    var models: [CloudModel] {
        switch self {
        case .anthropic: [
            CloudModel(id: "claude-haiku-5-5", name: "Claude Haiku 5.5", note: "Fastest"),
            CloudModel(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", note: "Balanced"),
            CloudModel(id: "claude-opus-5-5", name: "Claude Opus 5.5", note: "Most capable, slowest"),
        ]
        case .google: [
            CloudModel(id: "gemini-3.5-flash-lite", name: "Gemini 3.5 Flash-Lite", note: "Fastest"),
            CloudModel(id: "gemini-3.8-flash", name: "Gemini 3.8 Flash", note: "More capable"),
        ]
        }
    }

    /// The model to use: the user's pick if still offered, else the lightest.
    func resolvedModel(preferred: String?) -> CloudModel {
        models.first { $0.id == preferred } ?? models[0]
    }

    fileprivate var keychainService: String {
        switch self {
        case .anthropic: "com.fayazahmed.Kaze.anthropic"
        case .google: "com.fayazahmed.Kaze.gemini"
        }
    }

    /// Checks the key with a free call before it's saved.
    func verify(key: String) async throws {
        switch self {
        case .anthropic: try await AnthropicAPI.verify(key: key)
        case .google: try await GeminiAPI.verify(key: key)
        }
    }

    func clean(key: String, model: String, instructions: String, input: String) async throws -> String {
        switch self {
        case .anthropic: try await AnthropicAPI.clean(key: key, model: model, instructions: instructions, input: input)
        case .google: try await GeminiAPI.clean(key: key, model: model, instructions: instructions, input: input)
        }
    }
}

nonisolated enum CloudKeyError: LocalizedError {
    case noKey(KeyProvider)
    case invalidKey(KeyProvider)
    case requestFailed(KeyProvider, Int, String)
    case declined(KeyProvider)
    case incompleteResponse(KeyProvider)

    var errorDescription: String? {
        switch self {
        case .noKey(let provider): "Add your \(provider.name) API key first."
        case .invalidKey(let provider): "\(provider.name) didn't accept this API key."
        case .requestFailed(let provider, let status, let detail): "\(provider.name) request failed (\(status)): \(detail)"
        case .declined(let provider): "\(provider.name) declined to clean up this text."
        case .incompleteResponse(let provider): "\(provider.name) stopped before finishing."
        }
    }
}

/// The user's key for one provider, observed by Settings and onboarding.
@Observable
final class APIKeyAccount {
    let provider: KeyProvider
    private(set) var hasKey = false
    private(set) var isVerifying = false
    /// Why the last key the user entered was rejected.
    private(set) var error: String?

    @ObservationIgnored private var key: String?
    @ObservationIgnored private var verifyTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.fayazahmed.Kaze", category: "APIKey")

    init(provider: KeyProvider) {
        self.provider = provider
        key = APIKeyKeychain.load(service: provider.keychainService)
        hasKey = key != nil
    }

    /// Verifies `raw` and stores it in the Keychain if the provider accepts it.
    func save(_ raw: String, turnOnFor engine: CleanUpEngine) {
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }
        verifyTask?.cancel()
        isVerifying = true
        error = nil
        verifyTask = Task {
            do {
                try await provider.verify(key: candidate)
                try Task.checkCancellation()
                APIKeyKeychain.save(candidate, service: provider.keychainService)
                key = candidate
                hasKey = true
                // Adding the key for the picked engine is the opt-in.
                if Preferences.shared.cleanUpEngine == engine { Preferences.shared.formattingEnabled = true }
            } catch is CancellationError {
                return
            } catch {
                log.error("\(self.provider.name, privacy: .public) key rejected: \(error.localizedDescription, privacy: .public)")
                self.error = error.localizedDescription
            }
            isVerifying = false
        }
    }

    func removeKey() {
        verifyTask?.cancel()
        isVerifying = false
        key = nil
        hasKey = false
        error = nil
        APIKeyKeychain.delete(service: provider.keychainService)
    }

    func apiKey() throws -> String {
        guard let key else { throw CloudKeyError.noKey(provider) }
        return key
    }
}

/// Stores an API key in the login Keychain.
nonisolated enum APIKeyKeychain {
    private static let account = "api-key"

    static func load(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String, service: String) {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if SecItemUpdate(match as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            SecItemAdd(match.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }

    static func delete(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
