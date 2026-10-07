import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers
import os

/// Destination-dependent layout, mapping onto S1-mini's `Context` axis.
enum FormatContext: String {
    case general
    case email
}

/// Rewrites raw transcripts into clean written text with "S1-mini" by
/// "Superwhisper", a Qwen3-0.6B fine-tune run locally with MLX on the GPU.
///
/// The model is trained on one exact input shape (system prompt, control
/// line, transcript, empty think block), so the prompt is built by hand
/// rather than through a chat template.
final class S1MiniFormatter {
    private var container: ModelContainer?
    private var loading: Task<ModelContainer, Error>?
    private var unloadTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.fayazahmed.Kaze", category: "Formatter")

    /// The model holds ~1.2 GB and reloads in under a second, so release it
    /// soon after the last use. (ModelManager also frees it on memory pressure.)
    private static let idleUnloadDelay: Duration = .seconds(3 * 60)

    private static let systemPrompt = "You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text."

    static var directory: URL { StorageLocations.formatterModel }

    nonisolated static var isInstalled: Bool {
        let dir = StorageLocations.formatterModel
        return FormatterModel.files.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    nonisolated static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        let base = URL(string: "https://huggingface.co/\(FormatterModel.repo)/resolve/\(FormatterModel.revision)/")!
        let items = FormatterModel.files.map { FileDownloader.Item(url: base.appendingPathComponent($0), fileName: $0) }
        _ = StorageLocations.ensure(StorageLocations.root)
        try await FileDownloader.download(items, to: StorageLocations.formatterModel, progress: progress)
    }

    var isLoaded: Bool { container != nil }

    func prepare() async throws {
        _ = try await loadedContainer()
    }

    func unload() {
        loading?.cancel()
        loading = nil
        container = nil
        unloadTask?.cancel()
        unloadTask = nil
        MLX.Memory.clearCache()
    }

    private func loadedContainer() async throws -> ModelContainer {
        scheduleIdleUnload()
        if let container { return container }
        if let loading { return try await loading.value }
        guard Self.isInstalled else { throw FormatterError.notInstalled }

        let directory = Self.directory
        let task = Task.detached(priority: .userInitiated) { () throws -> ModelContainer in
            try await LLMModelFactory.shared.loadContainer(from: directory, using: TransformersTokenizerLoader())
        }
        loading = task
        defer { loading = nil }
        let started = Date()
        let container = try await task.value
        self.container = container
        log.info("Loaded S1-mini in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s")
        return container
    }

    private func scheduleIdleUnload() {
        unloadTask?.cancel()
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: Self.idleUnloadDelay)
            guard !Task.isCancelled else { return }
            self?.unload()
        }
    }

    /// Formats `transcript`. Long transcripts are split at sentence
    /// boundaries, since the model is tuned for dictation-length input.
    func format(_ transcript: String, style: FormatStyle, allowLists: Bool, context: FormatContext) async throws -> String {
        let container = try await loadedContainer()
        let control = "[Styling: \(style.rawValue)] [Structure: \(allowLists ? "lists" : "prose")] [Context: \(context.rawValue)]"
        var outputs: [String] = []
        for chunk in Self.chunks(of: transcript) {
            outputs.append(try await run(chunk, control: control, container: container))
        }
        return outputs.filter { !$0.isEmpty }.joined(separator: context == .email ? "\n\n" : " ")
    }

    private func run(_ transcript: String, control: String, container: ModelContainer) async throws -> String {
        let prompt = "<|im_start|>system\n\(Self.systemPrompt)<|im_end|>\n"
            + "<|im_start|>user\n\(control)\n\(transcript)<|im_end|>\n"
            + "<|im_start|>assistant\n<think>\n\n</think>\n\n"

        let tokenizer = await container.tokenizer
        let promptTokens = tokenizer.encode(text: prompt, addSpecialTokens: false)
        let transcriptTokens = tokenizer.encode(text: transcript, addSpecialTokens: false).count
        // Output tracks input length; the model card suggests 1.3x + 32.
        let parameters = GenerateParameters(maxTokens: Int(Double(transcriptTokens) * 1.3) + 32, temperature: 0)

        let input = LMInput(tokens: MLXArray(promptTokens.map(Int32.init)))
        var output = ""
        for await event in try await container.generate(input: input, parameters: parameters) {
            if case .chunk(let text) = event { output += text }
        }
        return output
            .replacingOccurrences(of: "<|im_end|>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits text into pieces of at most ~400 words at sentence boundaries.
    static func chunks(of text: String, maxWords: Int = 400) -> [String] {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count > maxWords else { return [text] }

        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let sentence { sentences.append(sentence.trimmingCharacters(in: .whitespaces)) }
        }
        var chunks: [String] = []
        var current: [String] = []
        var count = 0
        for sentence in sentences {
            let sentenceWords = sentence.split(whereSeparator: \.isWhitespace).count
            if count + sentenceWords > maxWords, !current.isEmpty {
                chunks.append(current.joined(separator: " "))
                current = []
                count = 0
            }
            current.append(sentence)
            count += sentenceWords
        }
        if !current.isEmpty { chunks.append(current.joined(separator: " ")) }
        return chunks
    }
}

enum FormatterError: LocalizedError {
    case notInstalled

    var errorDescription: String? {
        switch self {
        case .notInstalled: "S1-mini isn't downloaded yet."
        }
    }
}

/// Adapts swift-transformers' tokenizer to mlx-swift-lm's protocol.
private struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(try await AutoTokenizer.from(modelFolder: directory))
    }
}

private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] {
        try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }
}
