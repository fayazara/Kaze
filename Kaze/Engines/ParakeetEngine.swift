import Foundation
import FluidAudio
import os

/// NVIDIA Parakeet TDT 0.6B, run through FluidAudio's Core ML build on the
/// Neural Engine.
final class ParakeetEngine: SpeechEngine {
    let model: SpeechModel
    private var manager: AsrManager?
    private var loading: Task<AsrManager, Error>?
    private let log = Logger(subsystem: "com.fayazahmed.Kaze", category: "Parakeet")

    init(model: SpeechModel) {
        precondition(model.family == .parakeet)
        self.model = model
    }

    nonisolated static func version(for model: SpeechModel) -> AsrModelVersion {
        model == .parakeetV2 ? .v2 : .v3
    }

    nonisolated static func directory(for model: SpeechModel) -> URL {
        AsrModels.defaultCacheDirectory(for: version(for: model))
    }

    nonisolated static func isInstalled(_ model: SpeechModel) -> Bool {
        AsrModels.modelsExist(at: directory(for: model), version: version(for: model))
    }

    nonisolated static func download(_ model: SpeechModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await AsrModels.download(version: version(for: model)) { update in
            progress(update.fractionCompleted)
        }
    }

    func prepare() async throws {
        _ = try await loadedManager()
    }

    private func loadedManager() async throws -> AsrManager {
        if let manager { return manager }
        if let loading { return try await loading.value }

        let model = model
        guard Self.isInstalled(model) else { throw SpeechEngineError.modelNotInstalled(model) }
        let task = Task.detached(priority: .userInitiated) { () throws -> AsrManager in
            let version = Self.version(for: model)
            let models = try await AsrModels.load(from: Self.directory(for: model), version: version)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
        loading = task
        defer { loading = nil }
        let started = Date()
        let manager = try await task.value
        self.manager = manager
        log.info("Loaded \(model.title, privacy: .public) in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s")
        return manager
    }

    func makeSession(options: RecognitionOptions, onPartial: @escaping @Sendable (String) -> Void) throws -> any TranscriptionSession {
        let model = model
        let managerTask = Task { try await self.loadedManager() }
        return BatchSession { samples in
            let manager = try await managerTask.value
            // Parakeet expects at least one second of audio.
            var audio = samples
            let minimum = Int(AudioRecorder.sampleRate)
            if audio.count < minimum {
                audio.append(contentsOf: [Float](repeating: 0, count: minimum - audio.count))
            }
            var state = try TdtDecoderState(decoderLayers: Self.version(for: model).decoderLayers)
            let result = try await manager.transcribe(audio, decoderState: &state)
            return result.text
        }
    }

    func unload() {
        loading?.cancel()
        loading = nil
        manager = nil
    }
}
