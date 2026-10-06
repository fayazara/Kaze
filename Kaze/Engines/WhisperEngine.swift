import Foundation
@preconcurrency import WhisperKit
import os

/// OpenAI Whisper through Argmax's WhisperKit (Core ML).
final class WhisperEngine: SpeechEngine {
    let model: SpeechModel
    private var kit: WhisperKit?
    private var loading: Task<WhisperKit, Error>?
    private let log = Logger(subsystem: "com.fayazahmed.Kaze", category: "Whisper")

    init(model: SpeechModel) {
        precondition(model.family == .whisper)
        self.model = model
    }

    nonisolated private static let pathKeyPrefix = "v1.whisperFolder."

    /// Folder WhisperKit downloaded the model into, recorded after download.
    nonisolated static func folder(for model: SpeechModel) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: pathKeyPrefix + model.rawValue),
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    nonisolated static func isInstalled(_ model: SpeechModel) -> Bool {
        folder(for: model) != nil
    }

    nonisolated static func download(_ model: SpeechModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let variant = model.whisperVariant else { return }
        let base = StorageLocations.ensure(StorageLocations.whisperModels)
        let folder = try await WhisperKit.download(variant: variant, downloadBase: base) { update in
            progress(update.fractionCompleted)
        }
        UserDefaults.standard.set(folder.path, forKey: pathKeyPrefix + model.rawValue)
    }

    nonisolated static func delete(_ model: SpeechModel) {
        if let folder = folder(for: model) {
            try? FileManager.default.removeItem(at: folder)
        }
        UserDefaults.standard.removeObject(forKey: pathKeyPrefix + model.rawValue)
    }

    func prepare() async throws {
        _ = try await loadedKit()
    }

    private func loadedKit() async throws -> WhisperKit {
        if let kit { return kit }
        if let loading { return try await loading.value }
        guard let folder = Self.folder(for: model) else { throw SpeechEngineError.modelNotInstalled(model) }

        let task = Task.detached(priority: .userInitiated) { () throws -> WhisperKit in
            let config = WhisperKitConfig(
                modelFolder: folder.path,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: false
            )
            return try await WhisperKit(config)
        }
        loading = task
        defer { loading = nil }
        let started = Date()
        let kit = try await task.value
        self.kit = kit
        log.info("Loaded \(self.model.title, privacy: .public) in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s")
        return kit
    }

    func makeSession(options: RecognitionOptions, onPartial: @escaping @Sendable (String) -> Void) throws -> any TranscriptionSession {
        let englishOnly = model.isEnglishOnly
        let kitTask = Task { try await self.loadedKit() }
        return BatchSession { samples in
            let kit = try await kitTask.value
            var decode = DecodingOptions(
                task: .transcribe,
                language: englishOnly ? "en" : options.language.map { String($0.prefix(2)) },
                temperature: 0,
                usePrefillPrompt: true,
                detectLanguage: englishOnly ? false : options.language == nil,
                skipSpecialTokens: true,
                withoutTimestamps: true
            )
            decode.chunkingStrategy = .vad
            if !options.vocabulary.isEmpty, let tokenizer = kit.tokenizer {
                // Whisper treats the prompt as preceding context, which biases
                // spelling toward these terms.
                let prompt = " " + options.vocabulary.joined(separator: ", ")
                decode.promptTokens = tokenizer.encode(text: prompt).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            }
            let results = try await kit.transcribe(audioArray: samples, decodeOptions: decode)
            return results.map(\.text).joined(separator: " ")
        }
    }

    func unload() {
        loading?.cancel()
        loading = nil
        kit = nil
    }
}
