import CoreML
import Foundation
import PhononCoreML
import os

/// Fermion Research's Phonon-2, a low-bit Parakeet TDT 0.6B v3 for English,
/// run through its Core ML package: the encoder on the Neural Engine, the
/// greedy TDT decoder on the CPU.
final class PhononEngine: SpeechEngine {
    let model: SpeechModel
    private var transcriber: PhononTranscriber?
    private var loading: Task<PhononTranscriber, Error>?
    private let log = Logger(subsystem: "com.fayazahmed.Kaze", category: "Phonon")

    init(model: SpeechModel) {
        precondition(model.family == .phonon)
        self.model = model
    }

    nonisolated static func directory(for model: SpeechModel) -> URL {
        StorageLocations.phononModels.appendingPathComponent(PhononModel.folder, isDirectory: true)
    }

    nonisolated static func isInstalled(_ model: SpeechModel) -> Bool {
        let dir = directory(for: model)
        return PhononModel.files.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    nonisolated static func download(_ model: SpeechModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        let base = URL(string: "https://huggingface.co/\(PhononModel.repo)/resolve/\(PhononModel.revision)/")!
        let items = PhononModel.files.map { FileDownloader.Item(url: base.appendingPathComponent($0), fileName: $0) }
        _ = StorageLocations.ensure(StorageLocations.phononModels)
        try await FileDownloader.download(items, to: directory(for: model), progress: progress)
    }

    func prepare() async throws {
        _ = try await loadedTranscriber()
    }

    private func loadedTranscriber() async throws -> PhononTranscriber {
        if let transcriber { return transcriber }
        if let loading { return try await loading.value }

        let model = model
        guard Self.isInstalled(model) else { throw SpeechEngineError.modelNotInstalled(model) }
        let task = Task.detached(priority: .userInitiated) { () throws -> PhononTranscriber in
            let bundle = Self.directory(for: model)
            try Self.compileIfNeeded(bundle: bundle)
            var options = Transcriber.Options()
            // Load every encoder window up front so the first dictation of
            // each length never waits on a Neural Engine compile.
            options.eagerFunctions = PhononModel.encoderWindows
            return PhononTranscriber(try Transcriber(bundle: bundle, options: options))
        }
        loading = task
        defer { loading = nil }
        let started = Date()
        let transcriber = try await task.value
        self.transcriber = transcriber
        log.info("Loaded \(model.title, privacy: .public) in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s")
        return transcriber
    }

    /// Compiles the package beside it, where `Transcriber` looks first, so the
    /// compiled copy is deleted along with the model.
    private nonisolated static func compileIfNeeded(bundle: URL) throws {
        let fm = FileManager.default
        let package = bundle.appendingPathComponent(PhononModel.package)
        let compiled = package.deletingPathExtension().appendingPathExtension("mlmodelc")
        guard !fm.fileExists(atPath: compiled.path) else { return }
        let temporary = try MLModel.compileModel(at: package)
        try fm.moveItem(at: temporary, to: compiled)
    }

    func makeSession(options: RecognitionOptions, onPartial: @escaping @Sendable (String) -> Void) throws -> any TranscriptionSession {
        let transcriberTask = Task { try await self.loadedTranscriber() }
        return BatchSession { samples in
            let transcriber = try await transcriberTask.value
            guard !samples.isEmpty else { return "" }
            return try await transcriber.transcribe(samples)
        }
    }

    func unload() {
        loading?.cancel()
        loading = nil
        transcriber = nil
    }
}

/// Runs the blocking `Transcriber` off the caller's thread. Kaze transcribes
/// one recording at a time, and `Transcriber` guards its own shared state.
private nonisolated final class PhononTranscriber: @unchecked Sendable {
    private let transcriber: Transcriber

    init(_ transcriber: Transcriber) {
        self.transcriber = transcriber
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try self.transcriber.transcribe(samples).text
        }.value
    }
}
