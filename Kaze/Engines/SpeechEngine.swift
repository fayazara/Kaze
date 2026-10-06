import Foundation

/// Per-session inputs that shape recognition.
struct RecognitionOptions: Sendable {
    /// Names and jargon the engine should favor.
    var vocabulary: [String] = []
    /// BCP-47 code, or `nil` to follow the system / auto-detect.
    var language: String?
}

/// One dictation, from the first audio chunk to the final transcript.
nonisolated protocol TranscriptionSession: AnyObject, Sendable {
    /// Receives 16 kHz mono audio as it is captured (capture queue).
    func append(_ samples: [Float])
    /// Produces the final transcript. `audio` is the complete recording,
    /// for engines that transcribe in one pass.
    func finish(audio: [Float]) async throws -> String
    /// Abandons the session; `finish` will not be called.
    func cancel()
}

/// A speech-to-text backend.
protocol SpeechEngine: AnyObject {
    var model: SpeechModel { get }
    /// Loads the model into memory. Safe to call repeatedly.
    func prepare() async throws
    /// Starts a session. `onPartial` receives live text for engines that stream.
    func makeSession(options: RecognitionOptions, onPartial: @escaping @Sendable (String) -> Void) throws -> any TranscriptionSession
    /// Frees memory; the next `prepare` reloads.
    func unload()
}

/// Session for engines that transcribe the whole recording at once.
nonisolated final class BatchSession: TranscriptionSession, @unchecked Sendable {
    private let transcribe: @Sendable ([Float]) async throws -> String

    init(transcribe: @escaping @Sendable ([Float]) async throws -> String) {
        self.transcribe = transcribe
    }

    func append(_ samples: [Float]) {}

    func finish(audio: [Float]) async throws -> String {
        try await transcribe(audio)
    }

    func cancel() {}
}

enum SpeechEngineError: LocalizedError {
    case modelNotInstalled(SpeechModel)
    case unsupportedLanguage
    case unavailableOnThisMac

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled(let model): "\(model.title) isn't downloaded yet."
        case .unsupportedLanguage: "Apple Speech doesn't support this language."
        case .unavailableOnThisMac: "Apple Speech isn't available on this Mac."
        }
    }
}
