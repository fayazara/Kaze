#if DEBUG
import AVFoundation
import Foundation

/// Headless checks for development builds, run from the command line:
///
///     "Kaze Dev.app/Contents/MacOS/Kaze Dev" --selftest --model parakeetV2 --say "send it by friday"
///     "Kaze Dev.app/Contents/MacOS/Kaze Dev" --selftest --model apple --audio clip.wav   (path inside the container)
///     "Kaze Dev.app/Contents/MacOS/Kaze Dev" --selftest --format "so um send it friday no thursday"
///
/// Downloads the model if needed, runs it, prints results and timings, exits.
enum SelfTest {
    static var isRequested: Bool { CommandLine.arguments.contains("--selftest") }

    static func run() async -> Int32 {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        let models = AppModel.shared.models

        do {
            if let raw = value("--model"), let model = SpeechModel(rawValue: raw) {
                try await ensureInstalled(model, models: models)
                let samples: [Float]
                if let path = value("--audio") {
                    samples = try loadSamples(URL(fileURLWithPath: path))
                } else {
                    samples = try await synthesize(value("--say") ?? "Hey, can you send me the quarterly report by Thursday? Thanks.")
                }
                print("audio: \(String(format: "%.2f", Double(samples.count) / AudioRecorder.sampleRate))s")

                var started = Date()
                try await models.engine(for: model).prepare()
                print("load: \(String(format: "%.2f", Date().timeIntervalSince(started)))s")

                started = Date()
                let session = try models.engine(for: model).makeSession(options: RecognitionOptions(), onPartial: { _ in })
                // Feed in real-time-sized chunks like the microphone would.
                stride(from: 0, to: samples.count, by: 1600).forEach { start in
                    session.append(Array(samples[start..<min(start + 1600, samples.count)]))
                }
                let text = try await session.finish(audio: samples)
                print("transcribe: \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
                print("TRANSCRIPT: \(TextPolisher.clean(text))")
            }

            if let text = value("--format") {
                if !S1MiniFormatter.isInstalled {
                    print("downloading S1-mini…")
                    try await S1MiniFormatter.download { _ in }
                    models.refresh()
                }
                var started = Date()
                try await models.formatter.prepare()
                print("load: \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
                for style in [FormatStyle.semiFormal, .casual] {
                    started = Date()
                    let output = try await models.formatter.format(text, style: style, allowLists: true, context: .general)
                    print("format[\(style.rawValue)] \(String(format: "%.2f", Date().timeIntervalSince(started)))s: \(output)")
                }
            }
            return 0
        } catch {
            print("SELFTEST FAILED: \(error)")
            return 1
        }
    }

    private static func ensureInstalled(_ model: SpeechModel, models: ModelManager) async throws {
        switch model.family {
        case .apple:
            let locale = try await AppleSpeechEngine.resolveLocale(nil)
            try await AppleSpeechEngine.installAssets(for: locale, progress: nil)
        case .parakeet where !ParakeetEngine.isInstalled(model):
            print("downloading \(model.title)…")
            try await ParakeetEngine.download(model) { _ in }
        case .whisper where !WhisperEngine.isInstalled(model):
            print("downloading \(model.title)…")
            try await WhisperEngine.download(model) { _ in }
        default:
            break
        }
    }

    /// Speaks `text` with the system voice into 16 kHz samples.
    private static func synthesize(_ text: String) async throws -> [Float] {
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate, channels: 1, interleaved: false)!
        var samples: [Float] = []
        var converter: AVAudioConverter?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var finished = false
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    if !finished { finished = true; continuation.resume() }
                    return
                }
                if converter == nil { converter = AVAudioConverter(from: pcm.format, to: target) }
                let capacity = AVAudioFrameCount(Double(pcm.frameLength) * target.sampleRate / pcm.format.sampleRate) + 64
                let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)!
                var consumed = false
                converter?.convert(to: out, error: nil) { _, status in
                    if consumed { status.pointee = .noDataNow; return nil }
                    consumed = true
                    status.pointee = .haveData
                    return pcm
                }
                samples.append(contentsOf: UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
            }
        }
        // Pad with a little silence like a real recording.
        return [Float](repeating: 0, count: 4000) + samples + [Float](repeating: 0, count: 4000)
    }

    private static func loadSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate, channels: 1, interleaved: false)!
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: input)
        let converter = AVAudioConverter(from: file.processingFormat, to: target)!
        let capacity = AVAudioFrameCount(Double(file.length) * target.sampleRate / file.processingFormat.sampleRate) + 1024
        let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)!
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
#endif
