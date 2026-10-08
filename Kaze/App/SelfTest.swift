#if DEBUG
import AppKit
import AVFoundation
import Foundation
import os

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

        if args.contains("--focus") {
            let ax = FocusedApp.accessibilityFocused()
            let front = NSWorkspace.shared.frontmostApplication
            print("AX trusted: \(AXIsProcessTrusted())")
            print("AX focused: \(ax?.localizedName ?? "nil (unavailable)") [\(ax?.processIdentifier ?? 0)]")
            print("frontmost:  \(front?.localizedName ?? "nil") [\(front?.processIdentifier ?? 0)]")
            Logger(subsystem: "com.fayazahmed.Kaze", category: "SelfTest").notice("focus: trusted=\(AXIsProcessTrusted()) ax=\(ax?.localizedName ?? "nil", privacy: .public) front=\(front?.localizedName ?? "nil", privacy: .public)")
            return 0
        }

        if args.contains("--chatgpt-catalog") {
            do {
                let token = try await models.chatGPT.accessToken()
                var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let (data, _) = try await URLSession.shared.data(for: request)
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                for model in json?["models"] as? [[String: Any]] ?? [] {
                    let levels = (model["supported_reasoning_levels"] as? [[String: Any]] ?? []).compactMap { $0["effort"] as? String }
                    print("•", model["slug"] ?? "?", "| \(model["display_name"] ?? "")", "| visibility:", model["visibility"] ?? "", "| default:", model["default_reasoning_level"] ?? "-", "| levels:", levels.joined(separator: ","), "| verbosity:", model["support_verbosity"] ?? "-")
                    for key in ["service_tiers", "additional_speed_tiers", "default_service_tier", "use_responses_lite", "prefer_websockets"] {
                        print("    \(key):", String(describing: model[key] ?? "-").replacingOccurrences(of: "\n", with: " "))
                    }
                }
            } catch {
                print("catalog failed:", error)
            }
            return 0
        }

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
                let engine = CleanUpEngine(rawValue: value("--engine") ?? "") ?? .s1Mini
                if engine == .s1Mini, !S1MiniFormatter.isInstalled {
                    print("downloading S1-mini…")
                    try await S1MiniFormatter.download { _ in }
                    models.refresh()
                }
                if engine == .chatGPT {
                    print("chatgpt: \(models.chatGPT.status) \(models.chatGPT.email ?? "")")
                }
                // Debug-only overrides for comparing ChatGPT settings; the
                // previous values are restored below.
                let savedModel = Preferences.shared.chatGPTModel
                let savedEffort = Preferences.shared.chatGPTReasoning
                if let slug = value("--chatgpt-model") { Preferences.shared.chatGPTModel = slug }
                if let effort = value("--effort") { Preferences.shared.chatGPTReasoning = effort == "lowest" ? nil : effort }
                defer {
                    Preferences.shared.chatGPTModel = savedModel
                    Preferences.shared.chatGPTReasoning = savedEffort
                }
                let cleaner = models.cleaner(for: engine)
                var started = Date()
                try await cleaner.prepare()
                print("load: \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
                // Several inputs separated by "|" to compare engines in one run.
                for input in text.split(separator: "|").map(String.init) {
                    for style in [FormatStyle.semiFormal] {
                        started = Date()
                        do {
                            let output = try await cleaner.format(input, style: style, allowLists: true, context: .general)
                            let verdict = TextPolisher.isPlausibleRewrite(output, of: input) ? "" : "   [REJECTED by guard → raw transcript pasted]"
                            print("[\(String(format: "%.2f", Date().timeIntervalSince(started)))s] \(input)\n   → \(output)\(verdict)")
                        } catch {
                            print("[error] \(input)\n   → \(error)")
                        }
                    }
                }
                print("footprint loaded: \(footprintMB()) MB")
                cleaner.unload()
                try? await Task.sleep(for: .seconds(1))
                print("footprint after unload: \(footprintMB()) MB")
            }
            return 0
        } catch {
            print("SELFTEST FAILED: \(error)")
            return 1
        }
    }

    /// Physical memory footprint, the number Activity Monitor shows.
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
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
