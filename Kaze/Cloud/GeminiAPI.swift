import Foundation

/// Calls the Gemini API with the user's own key.
nonisolated enum GeminiAPI {
    private static let base = URL(string: "https://generativelanguage.googleapis.com/v1beta/")!

    static func verify(key: String) async throws {
        var request = request(path: "models?pageSize=1", key: key)
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data)
    }

    /// One generateContent call; returns the reply's text.
    static func clean(key: String, model: String, instructions: String, input: String) async throws -> String {
        var request = request(path: "models/\(model):generateContent", key: key)
        request.httpMethod = "POST"
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": instructions]]],
            "contents": [["role": "user", "parts": [["text": input]]]],
            // Cleanup is mechanical; thinking only adds latency and cost.
            "generationConfig": ["thinkingConfig": ["thinkingLevel": thinkingLevel(for: model)]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data)
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CloudKeyError.incompleteResponse(.google)
        }
        if (json["promptFeedback"] as? [String: Any])?["blockReason"] != nil { throw CloudKeyError.declined(.google) }
        guard let candidate = (json["candidates"] as? [[String: Any]])?.first else { throw CloudKeyError.incompleteResponse(.google) }
        switch candidate["finishReason"] as? String {
        case "STOP", nil: break
        case "MAX_TOKENS": throw CloudKeyError.incompleteResponse(.google)
        default: throw CloudKeyError.declined(.google)
        }
        let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        return parts
            .filter { ($0["thought"] as? Bool) != true }
            .compactMap { $0["text"] as? String }
            .joined()
    }

    /// The lowest level each model accepts; 3.8 Flash has no "minimal".
    private static func thinkingLevel(for model: String) -> String {
        model.contains("flash-lite") ? "minimal" : "low"
    }

    private static func request(path: String, key: String) -> URLRequest {
        var request = URLRequest(url: URL(string: path, relativeTo: base)!)
        request.timeoutInterval = 30
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode != 200 else { return }
        let error = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? [String: Any]
        let message = error?["message"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
        // A bad key comes back as 400 API_KEY_INVALID, not 401.
        let details = error?["details"] as? [[String: Any]] ?? []
        if http.statusCode == 401 || http.statusCode == 403 || details.contains(where: { $0["reason"] as? String == "API_KEY_INVALID" }) {
            throw CloudKeyError.invalidKey(.google)
        }
        throw CloudKeyError.requestFailed(.google, http.statusCode, message)
    }
}
