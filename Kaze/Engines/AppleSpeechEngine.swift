@preconcurrency import AVFoundation
import Speech
import Synchronization
import os

/// Apple's on-device SpeechAnalyzer / SpeechTranscriber (macOS 26+). Streams
/// live text while you speak, and needs no download beyond the system's own
/// language assets.
final class AppleSpeechEngine: SpeechEngine {
    let model = SpeechModel.apple

    static var isSupported: Bool { SpeechTranscriber.isAvailable }

    func prepare() async throws {
        guard Self.isSupported else { throw SpeechEngineError.unavailableOnThisMac }
        let locale = try await Self.resolveLocale(Preferences.shared.language)
        try await Self.installAssets(for: locale, progress: nil)
    }

    func makeSession(options: RecognitionOptions, onPartial: @escaping @Sendable (String) -> Void) throws -> any TranscriptionSession {
        guard Self.isSupported else { throw SpeechEngineError.unavailableOnThisMac }
        return AppleSpeechSession(options: options, onPartial: onPartial)
    }

    func unload() {}

    // MARK: - Locale & assets

    nonisolated static func resolveLocale(_ code: String?) async throws -> Locale {
        let requested = code.map { Locale(identifier: $0) } ?? Locale.current
        if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) {
            return locale
        }
        // Following the system language: fall back to English rather than failing.
        if code == nil, let english = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) {
            return english
        }
        throw SpeechEngineError.unsupportedLanguage
    }

    nonisolated static func assetStatus(for code: String?) async -> AssetInventory.Status {
        guard let locale = try? await resolveLocale(code) else { return .unsupported }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        return await AssetInventory.status(forModules: [transcriber])
    }

    nonisolated static func installAssets(for locale: Locale, progress: (@Sendable (Double) -> Void)?) async throws {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
        let observation = progress.map { report in
            request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, _ in
                report(progress.fractionCompleted)
            }
        }
        defer { observation?.invalidate() }
        try await request.downloadAndInstall()
    }

    /// Languages Apple Speech can transcribe, for the language picker.
    nonisolated static func supportedLanguages() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }
}

/// A live SpeechAnalyzer session. Audio that arrives while the analyzer is
/// still spinning up is buffered and fed in once it's ready, so the first
/// words are never lost.
nonisolated final class AppleSpeechSession: TranscriptionSession, @unchecked Sendable {
    private struct State {
        var continuation: AsyncStream<AnalyzerInput>.Continuation?
        var pending: [[Float]] = []
        var analyzerFormat: AVAudioFormat?
        var converter: AVAudioConverter?
        var finalized = ""
        var volatile = ""
        var isClosed = false
    }

    private let state = Mutex(State())
    private var setup: Task<(SpeechAnalyzer, Task<Void, Never>), Error>!
    private let log = Logger(subsystem: "com.fayazahmed.Kaze", category: "AppleSpeech")
    private static let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate, channels: 1, interleaved: false)!

    init(options: RecognitionOptions, onPartial: @escaping @Sendable (String) -> Void) {
        setup = Task { [self] in try await start(options: options, onPartial: onPartial) }
    }

    private func start(options: RecognitionOptions, onPartial: @escaping @Sendable (String) -> Void) async throws -> (SpeechAnalyzer, Task<Void, Never>) {
        let locale = try await AppleSpeechEngine.resolveLocale(options.language)
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        try await AppleSpeechEngine.installAssets(for: locale, progress: nil)

        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) ?? Self.sourceFormat
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)

        let context = AnalysisContext()
        if !options.vocabulary.isEmpty {
            context.contextualStrings[.general] = options.vocabulary
        }

        let analyzer = SpeechAnalyzer(
            inputSequence: stream,
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime),
            analysisContext: context
        )

        let results = Task { [self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let combined = state.withLock { state -> String in
                        if result.isFinal {
                            state.finalized += text
                            state.volatile = ""
                        } else {
                            state.volatile = text
                        }
                        return state.finalized + state.volatile
                    }
                    onPartial(combined.trimmingCharacters(in: .whitespaces))
                }
            } catch {
                // The sequence ends with an error when the analyzer is cancelled.
            }
        }

        // Hand over to live feeding, flushing whatever was captured meanwhile.
        state.withLock { state in
            state.analyzerFormat = format
            if state.isClosed {
                continuation.finish()
                return
            }
            state.continuation = continuation
            for chunk in state.pending {
                if let input = Self.makeInput(chunk, state: &state) { continuation.yield(input) }
            }
            state.pending = []
        }
        log.debug("Analyzer ready for \(locale.identifier, privacy: .public)")
        return (analyzer, results)
    }

    func append(_ samples: [Float]) {
        state.withLock { state in
            guard !state.isClosed else { return }
            if let continuation = state.continuation {
                if let input = Self.makeInput(samples, state: &state) { continuation.yield(input) }
            } else {
                state.pending.append(samples)
            }
        }
    }

    func finish(audio: [Float]) async throws -> String {
        let (analyzer, results) = try await setup.value
        let continuation = state.withLock { state in
            state.isClosed = true
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.finish()
        // Without this call the analyzer never delivers its final results.
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        await results.value
        return state.withLock { ($0.finalized + $0.volatile).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func cancel() {
        let continuation = state.withLock { state in
            state.isClosed = true
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.finish()
        let setup = self.setup
        Task {
            guard let (analyzer, _) = try? await setup?.value else { return }
            await analyzer.cancelAndFinishNow()
        }
    }

    private static func makeInput(_ samples: [Float], state: inout State) -> AnalyzerInput? {
        guard !samples.isEmpty, let target = state.analyzerFormat,
              let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }

        if target == sourceFormat { return AnalyzerInput(buffer: source) }

        if state.converter == nil {
            state.converter = AVAudioConverter(from: sourceFormat, to: target)
        }
        guard let converter = state.converter else { return nil }
        let capacity = AVAudioFrameCount(Double(samples.count) * target.sampleRate / sourceFormat.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return source
        }
        guard error == nil, output.frameLength > 0 else { return nil }
        return AnalyzerInput(buffer: output)
    }
}
