import AppKit
import Foundation
import Observation
import os

nonisolated struct ChatGPTModel: Identifiable, Hashable, Sendable {
    let slug: String
    let displayName: String
    /// Reasoning efforts the model accepts, lightest first (e.g. low, medium, high).
    let reasoningLevels: [String]
    let supportsVerbosity: Bool
    var id: String { slug }
}

/// Calls the OpenAI API with a ChatGPT-plan access token.
nonisolated enum ChatGPTAPI {
    static func listModels(token: String) async throws -> [ChatGPTModel] {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data)
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = json["models"] as? [[String: Any]] else { throw ChatGPTError.noModels }
        return list.compactMap { model in
            guard model["visibility"] as? String == "list",
                  let slug = model["slug"] as? String, !slug.isEmpty,
                  let name = model["display_name"] as? String, !name.isEmpty else { return nil }
            let levels = (model["supported_reasoning_levels"] as? [[String: Any]] ?? []).compactMap { $0["effort"] as? String }
            let verbosity = (model["support_verbosity"] as? Bool) ?? ((model["support_verbosity"] as? NSNumber)?.boolValue ?? false)
            return ChatGPTModel(slug: slug, displayName: name, reasoningLevels: levels, supportsVerbosity: verbosity)
        }
    }

    /// Runs one Responses API call and returns its text. `store: false`
    /// keeps the transcript out of the user's ChatGPT history.
    static func respond(token: String, model: String, effort: String?, lowVerbosity: Bool, instructions: String, input: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        var body: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": [["role": "user", "content": input]],
            "store": false,
            "stream": true,
        ]
        // Cleanup is mechanical; reasoning only adds latency and plan usage.
        if let effort { body["reasoning"] = ["effort": effort] }
        if lowVerbosity { body["text"] = ["verbosity": "low"] }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var body = Data()
            for try await byte in bytes { body.append(byte); if body.count > 64_000 { break } }
            try check(response, body)
        }

        var text = ""
        var completed = false
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", let data = payload.data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "response.output_text.delta":
                text += event["delta"] as? String ?? ""
            case "response.completed":
                completed = true
            case "response.failed", "error":
                let error = (event["response"] as? [String: Any])?["error"] as? [String: Any] ?? event["error"] as? [String: Any]
                throw ChatGPTError.requestFailed(0, error?["message"] as? String ?? "The request failed.")
            case "response.incomplete":
                throw ChatGPTError.incompleteResponse
            default:
                break
            }
            if completed { break }
        }
        guard completed else { throw ChatGPTError.incompleteResponse }
        return text
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 { throw ChatGPTError.sessionExpired }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = (json?["error"] as? [String: Any])?["message"] as? String
                ?? json?["error"] as? String
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw ChatGPTError.requestFailed(http.statusCode, message)
        }
    }
}

/// The user's ChatGPT connection, observed by Settings and onboarding.
@Observable
final class ChatGPTAccount {
    enum Status: Equatable {
        case signedOut
        case signingIn
        case signedIn
        case failed(String)
    }

    private(set) var status: Status = .signedOut
    private(set) var email: String?
    private(set) var models: [ChatGPTModel] = []

    @ObservationIgnored private var credentials: ChatGPTCredentials?
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var refreshing: Task<ChatGPTCredentials, Error>?
    @ObservationIgnored private let log = Logger(subsystem: "com.fayazahmed.Kaze", category: "ChatGPT")

    var isSignedIn: Bool { status == .signedIn }

    init() {
        if let saved = ChatGPTKeychain.load() {
            credentials = saved
            email = saved.email
            status = .signedIn
            Task { await loadModels() }
        }
    }

    func signIn() {
        signInTask?.cancel()
        status = .signingIn
        let previous = credentials
        signInTask = Task {
            do {
                let new = try await ChatGPTOAuth.signIn(
                    previousClientId: previous?.clientId,
                    loginHint: previous?.email,
                    open: { url in Task { @MainActor in NSWorkspace.shared.open(url) } }
                )
                ChatGPTKeychain.save(new)
                credentials = new
                email = new.email
                status = .signedIn
                // Picking ChatGPT started this sign-in, so turn Clean Up on.
                if Preferences.shared.cleanUpEngine == .chatGPT { Preferences.shared.formattingEnabled = true }
                NSApp.activate()
                await loadModels()
            } catch is CancellationError {
                status = credentials == nil ? .signedOut : .signedIn
            } catch ChatGPTError.cancelled {
                status = credentials == nil ? .signedOut : .signedIn
            } catch {
                log.error("Sign-in failed: \(error.localizedDescription, privacy: .public)")
                status = .failed(error.localizedDescription)
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        status = credentials == nil ? .signedOut : .signedIn
    }

    func signOut() {
        let old = credentials
        credentials = nil
        email = nil
        models = []
        status = .signedOut
        ChatGPTKeychain.delete()
        if let old { Task { await ChatGPTOAuth.revoke(old) } }
    }

    /// A fresh access token, refreshed shortly before it expires.
    func accessToken() async throws -> String {
        guard let current = credentials else { throw ChatGPTError.notSignedIn }
        if current.expiresAt.timeIntervalSinceNow > 60 { return current.accessToken }
        if let refreshing { return try await refreshing.value.accessToken }
        let task = Task { try await ChatGPTOAuth.refresh(current) }
        refreshing = task
        defer { refreshing = nil }
        do {
            let renewed = try await task.value
            credentials = renewed
            ChatGPTKeychain.save(renewed)
            return renewed.accessToken
        } catch ChatGPTError.sessionExpired {
            signOut()
            status = .failed(ChatGPTError.sessionExpired.localizedDescription)
            throw ChatGPTError.sessionExpired
        }
    }

    func loadModels() async {
        do {
            models = try await ChatGPTAPI.listModels(token: try await accessToken())
        } catch {
            log.error("Couldn't list models: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The model to use: the user's pick if offered, else Luna, a small, fast
    /// model that handles cleanup well without spending much of the plan.
    /// Larger models (Sol, Astra) are slower and costlier for no gain here.
    func resolvedModel(preferred: String?) -> ChatGPTModel? {
        if let preferred, let model = models.first(where: { $0.slug == preferred }) { return model }
        return models.first { $0.slug.localizedCaseInsensitiveContains("luna") }
            ?? models.first { $0.slug.localizedCaseInsensitiveContains("mini") }
            ?? models.first
    }

    /// The effort to send: the user's pick if this model supports it,
    /// otherwise the lightest level it offers.
    static func effort(for model: ChatGPTModel, preferred: String?) -> String? {
        if let preferred, model.reasoningLevels.contains(preferred) { return preferred }
        return model.reasoningLevels.first
    }
}
