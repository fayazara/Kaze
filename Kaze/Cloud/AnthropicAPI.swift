import Foundation

/// Calls the Claude API with the user's own key. There's no official Swift
/// SDK, so this speaks the Messages API over HTTP directly.
nonisolated enum AnthropicAPI {
    /// Trailing slash matters: relative paths replace the last segment otherwise.
    private static let base = URL(string: "https://api.anthropic.com/v1/")!

    static func verify(key: String) async throws {
        var request = request(path: "models?limit=1", key: key)
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data)
    }

    /// One Messages API call; returns the reply's text.
    static func clean(key: String, model: String, instructions: String, input: String) async throws -> String {
        var request = request(path: "messages", key: key)
        request.httpMethod = "POST"
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": instructions,
            "messages": [["role": "user", "content": input]],
            // Cleanup is mechanical; thinking only adds latency and cost.
            "output_config": ["effort": "low"],
        ]
        // Each model has a different lowest thinking setting: Haiku can turn
        // it off, Sonnet's off switch is `between_tools`, and Opus always
        // thinks adaptively (low effort keeps it short).
        switch model {
        case let id where id.hasPrefix("claude-haiku"):
            body["thinking"] = ["type": "disabled"]
        case let id where id.hasPrefix("claude-sonnet"):
            body["thinking"] = ["type": "between_tools"]
        default:
            break
        }
        // Sonnet and Opus can have a declined request re-run on another model
        // server-side; Haiku has no fallback.
        if !model.hasPrefix("claude-haiku") {
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data)
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CloudKeyError.incompleteResponse(.anthropic)
        }
        switch json["stop_reason"] as? String {
        case "refusal": throw CloudKeyError.declined(.anthropic)
        case "max_tokens": throw CloudKeyError.incompleteResponse(.anthropic)
        default: break
        }
        // Read blocks by type: a reply can start with a thinking block.
        let blocks = json["content"] as? [[String: Any]] ?? []
        return blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
    }

    private static func request(path: String, key: String) -> URLRequest {
        var request = URLRequest(url: URL(string: path, relativeTo: base)!)
        request.timeoutInterval = 30
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode != 200 else { return }
        if http.statusCode == 401 || http.statusCode == 403 { throw CloudKeyError.invalidKey(.anthropic) }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = (json?["error"] as? [String: Any])?["message"] as? String
            ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
        throw CloudKeyError.requestFailed(.anthropic, http.statusCode, message)
    }
}
