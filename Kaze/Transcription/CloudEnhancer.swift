import Foundation

/// Sends transcription text directly to the selected cloud AI provider for
/// smart formatting. Supports OpenAI, Google Gemini, and Anthropic.
@MainActor
class CloudEnhancer {

    private static let openAIURL = URL(string: "https://api.openai.com/v1/chat/completions")!
    private static let anthropicURL = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let geminiBaseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!

    /// Sends a text formatting request to the cloud AI model.
    /// - Parameters:
    ///   - text: The transcription text to process.
    ///   - systemPrompt: The system prompt instructing the model how to process the text.
    ///   - userPrompt: The user message wrapping the text (e.g. "Clean up this transcription:\n\n<text>").
    ///   - provider: The cloud AI provider to use.
    ///   - modelID: The model identifier string.
    /// - Returns: The processed text, or the original text if the request fails.
    func process(
        _ text: String,
        systemPrompt: String,
        userPrompt: String,
        provider: CloudAIProvider,
        modelID: String
    ) async throws -> String {
        guard let apiKey = KeychainManager.getAPIKey(for: provider), !apiKey.isEmpty else {
            throw CloudEnhancerError.missingAPIKey(provider)
        }

        let nativeModelID = provider.nativeModelID(from: modelID)
        let request = try Self.makeRequest(
            provider: provider,
            modelID: nativeModelID,
            apiKey: apiKey,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudEnhancerError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CloudEnhancerError.httpError(
                provider: provider,
                statusCode: httpResponse.statusCode,
                body: body
            )
        }

        guard let content = try Self.decodeResponse(data, provider: provider) else {
            throw CloudEnhancerError.emptyResponse
        }

        let result = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? text : result
    }

    /// Convenience: format transcription text using the smart formatting prompt.
    func format(
        _ text: String,
        provider: CloudAIProvider,
        modelID: String,
        customWords: [String] = []
    ) async throws -> String {
        var systemPrompt = AppPreferenceKey.smartFormattingPrompt
        if !customWords.isEmpty {
            systemPrompt += "\n\nIMPORTANT: Preserve the exact spelling and casing of these custom words, names, or abbreviations: \(customWords.joined(separator: ", "))."
        }

        return try await process(
            text,
            systemPrompt: systemPrompt,
            userPrompt: "Format this transcription:\n\n\(text)",
            provider: provider,
            modelID: modelID
        )
    }

    private static func makeRequest(
        provider: CloudAIProvider,
        modelID: String,
        apiKey: String,
        systemPrompt: String,
        userPrompt: String
    ) throws -> URLRequest {
        switch provider {
        case .openAI:
            return try makeOpenAIRequest(
                modelID: modelID,
                apiKey: apiKey,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt
            )
        case .google:
            return try makeGeminiRequest(
                modelID: modelID,
                apiKey: apiKey,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt
            )
        case .anthropic:
            return try makeAnthropicRequest(
                modelID: modelID,
                apiKey: apiKey,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt
            )
        }
    }

    private static func makeOpenAIRequest(
        modelID: String,
        apiKey: String,
        systemPrompt: String,
        userPrompt: String
    ) throws -> URLRequest {
        let requestBody = OpenAIChatCompletionRequest(
            model: modelID,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userPrompt),
            ],
            reasoning_effort: CloudAIProvider.openAI.reasoningEffort
        )

        var request = URLRequest(url: openAIURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)
        request.timeoutInterval = 30
        return request
    }

    private static func makeGeminiRequest(
        modelID: String,
        apiKey: String,
        systemPrompt: String,
        userPrompt: String
    ) throws -> URLRequest {
        guard let encodedModelID = modelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(geminiBaseURL.absoluteString)/\(encodedModelID):generateContent") else {
            throw CloudEnhancerError.invalidRequestURL
        }

        let requestBody = GeminiGenerateContentRequest(
            systemInstruction: .init(parts: [.init(text: systemPrompt)]),
            contents: [
                .init(role: "user", parts: [.init(text: userPrompt)])
            ],
            generationConfig: .init(temperature: 0.1)
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)
        request.timeoutInterval = 30
        return request
    }

    private static func makeAnthropicRequest(
        modelID: String,
        apiKey: String,
        systemPrompt: String,
        userPrompt: String
    ) throws -> URLRequest {
        let requestBody = AnthropicMessagesRequest(
            model: modelID,
            max_tokens: 4096,
            system: systemPrompt,
            messages: [
                .init(role: "user", content: userPrompt)
            ],
            temperature: 0.1
        )

        var request = URLRequest(url: anthropicURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)
        request.timeoutInterval = 30
        return request
    }

    private static func decodeResponse(_ data: Data, provider: CloudAIProvider) throws -> String? {
        switch provider {
        case .openAI:
            let decoded = try JSONDecoder().decode(OpenAIChatCompletionResponse.self, from: data)
            return decoded.choices.first?.message.content
        case .google:
            let decoded = try JSONDecoder().decode(GeminiGenerateContentResponse.self, from: data)
            return decoded.text
        case .anthropic:
            let decoded = try JSONDecoder().decode(AnthropicMessagesResponse.self, from: data)
            return decoded.text
        }
    }
}

// MARK: - Request / Response Types

private struct OpenAIChatCompletionRequest: Encodable {
    let model: String
    let messages: [Message]
    let reasoning_effort: String?

    struct Message: Encodable {
        let role: String
        let content: String
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, reasoning_effort
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(messages, forKey: .messages)
        // Only include reasoning_effort when non-nil to avoid sending null
        // to providers that don't support it.
        if let effort = reasoning_effort {
            try container.encode(effort, forKey: .reasoning_effort)
        }
    }
}

private struct OpenAIChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String?
    }
}

private struct GeminiGenerateContentRequest: Encodable {
    let systemInstruction: GeminiContent
    let contents: [GeminiContent]
    let generationConfig: GenerationConfig

    struct GeminiContent: Encodable {
        let role: String?
        let parts: [Part]

        init(role: String? = nil, parts: [Part]) {
            self.role = role
            self.parts = parts
        }

        struct Part: Encodable {
            let text: String
        }

        enum CodingKeys: String, CodingKey {
            case role, parts
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            if let role {
                try container.encode(role, forKey: .role)
            }
            try container.encode(parts, forKey: .parts)
        }
    }

    struct GenerationConfig: Encodable {
        let temperature: Double
    }
}

private struct GeminiGenerateContentResponse: Decodable {
    let candidates: [Candidate]?

    var text: String? {
        candidates?.first?.content.parts.compactMap(\.text).joined()
    }

    struct Candidate: Decodable {
        let content: Content
    }

    struct Content: Decodable {
        let parts: [Part]
    }

    struct Part: Decodable {
        let text: String?
    }
}

private struct AnthropicMessagesRequest: Encodable {
    let model: String
    let max_tokens: Int
    let system: String
    let messages: [Message]
    let temperature: Double

    struct Message: Encodable {
        let role: String
        let content: String
    }
}

private struct AnthropicMessagesResponse: Decodable {
    let content: [ContentBlock]

    var text: String? {
        content.compactMap(\.text).joined()
    }

    struct ContentBlock: Decodable {
        let type: String?
        let text: String?
    }
}

// MARK: - Errors

enum CloudEnhancerError: LocalizedError {
    case missingAPIKey(CloudAIProvider)
    case invalidRequestURL
    case invalidResponse
    case httpError(provider: CloudAIProvider, statusCode: Int, body: String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "No API key configured for \(provider.title). Add your key in Settings."
        case .invalidRequestURL:
            return "Could not build a valid AI provider request URL."
        case .invalidResponse:
            return "Received an invalid response from the AI provider."
        case .httpError(let provider, let statusCode, let body):
            return "\(provider.title) returned HTTP \(statusCode): \(body)"
        case .emptyResponse:
            return "AI model returned an empty response."
        }
    }
}
