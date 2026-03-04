import Foundation
import AVFoundation
import CoreAudio
import Accelerate
import Combine
import WhisperKit

// MARK: - Whisper Model Variant

enum WhisperModelVariant: String, CaseIterable, Identifiable {
    case tiny
    case base
    case small
    case largev3turbo

    var id: String { rawValue }

    /// The variant string WhisperKit expects for download.
    var whisperKitVariant: String {
        switch self {
        case .tiny: return "tiny"
        case .base: return "base"
        case .small: return "small"
        case .largev3turbo: return "large-v3-turbo"
        }
    }

    var title: String {
        switch self {
        case .tiny: return "Tiny"
        case .base: return "Base"
        case .small: return "Small"
        case .largev3turbo: return "Large v3 Turbo"
        }
    }

    var sizeDescription: String {
        switch self {
        case .tiny: return "~75 MB"
        case .base: return "~142 MB"
        case .small: return "~466 MB"
        case .largev3turbo: return "~1.5 GB"
        }
    }

    var qualityDescription: String {
        switch self {
        case .tiny: return "Fastest, good for quick notes"
        case .base: return "Balanced speed and accuracy"
        case .small: return "High accuracy, moderate speed"
        case .largev3turbo: return "Best accuracy, requires more memory"
        }
    }
}

// MARK: - WhisperModelManager

/// Manages Whisper model download state, exposed to the settings UI.
/// Supports multiple model variants with per-variant storage.
@MainActor
class WhisperModelManager: ObservableObject {
    enum ModelState: Equatable {
        case notDownloaded
        case downloading(progress: Double)
        case downloaded
        case loading
        case ready
        case error(String)
    }

    @Published var state: ModelState = .notDownloaded
    /// Cached model size string to avoid recursive directory enumeration in view body (Fix #12).
    @Published private(set) var modelSizeOnDiskCached: String = ""

    @Published var selectedVariant: WhisperModelVariant {
        didSet {
            guard oldValue != selectedVariant else { return }
            UserDefaults.standard.set(selectedVariant.rawValue, forKey: AppPreferenceKey.whisperModelVariant)
            // When switching variants, invalidate the current WhisperKit instance
            whisperKit = nil
            checkExistingModel()
        }
    }

    /// Root path where all models are stored in Application Support.
    static var modelsRootDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("com.fayazahmed.Kaze/WhisperModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Per-variant download directory to avoid collisions between models.
    var modelDirectory: URL {
        let dir = Self.modelsRootDirectory.appendingPathComponent(selectedVariant.rawValue, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var whisperKit: WhisperKit?

    init() {
        let raw = UserDefaults.standard.string(forKey: AppPreferenceKey.whisperModelVariant)
        self.selectedVariant = WhisperModelVariant(rawValue: raw ?? "") ?? .tiny
        checkExistingModel()
    }

    func checkExistingModel() {
        let fm = FileManager.default

        // Most reliable check: we stored the model path after a successful download
        if let storedPath = UserDefaults.standard.string(forKey: modelPathKey),
           fm.fileExists(atPath: storedPath) {
            state = .downloaded
            refreshModelSizeOnDisk()
            return
        }

        // Fallback: scan the variant directory for model files
        let modelDir = modelDirectory
        if let contents = try? fm.contentsOfDirectory(at: modelDir, includingPropertiesForKeys: nil),
           contents.contains(where: { $0.hasDirectoryPath && $0.lastPathComponent.lowercased().contains("whisper") }) {
            state = .downloaded
            refreshModelSizeOnDisk()
        } else {
            let hubDir = modelDir.appendingPathComponent("huggingface")
            if fm.fileExists(atPath: hubDir.path) {
                state = .downloaded
                refreshModelSizeOnDisk()
            } else {
                state = .notDownloaded
                modelSizeOnDiskCached = ""
            }
        }
    }

    /// Downloads the selected Whisper model variant. Progress updates are published.
    func downloadModel() async {
        guard case .notDownloaded = state else { return }

        state = .downloading(progress: 0)

        do {
            let modelFolder = try await WhisperKit.download(
                variant: selectedVariant.whisperKitVariant,
                downloadBase: modelDirectory,
                progressCallback: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.state = .downloading(progress: progress.fractionCompleted)
                    }
                }
            )

            // Store the path for this variant
            UserDefaults.standard.set(modelFolder.path, forKey: modelPathKey)
            state = .downloaded
            refreshModelSizeOnDisk()
        } catch {
            state = .error("Download failed: \(error.localizedDescription)")
        }
    }

    /// Initializes WhisperKit with the downloaded model. Returns the ready instance.
    func loadModel() async throws -> WhisperKit {
        if let existing = whisperKit {
            return existing
        }

        state = .loading

        // Try stored path first
        let modelPath: String? = UserDefaults.standard.string(forKey: modelPathKey)

        let config = WhisperKitConfig(
            model: selectedVariant.whisperKitVariant,
            downloadBase: modelDirectory,
            modelFolder: modelPath,
            verbose: false,
            logLevel: .none,
            prewarm: true,
            load: true,
            download: modelPath == nil
        )

        let kit = try await WhisperKit(config)
        whisperKit = kit
        state = .ready
        refreshModelSizeOnDisk()
        return kit
    }

    /// Deletes the currently selected model's files.
    func deleteModel() {
        whisperKit = nil
        try? FileManager.default.removeItem(at: modelDirectory)
        UserDefaults.standard.removeObject(forKey: modelPathKey)
        state = .notDownloaded
        modelSizeOnDiskCached = ""
    }

    /// The cached WhisperKit instance, if loaded.
    var loadedKit: WhisperKit? { whisperKit }

    /// Size of the currently selected model on disk (cached, not computed on every view redraw).
    var modelSizeOnDisk: String { modelSizeOnDiskCached }

    /// Recalculates model size on disk and updates the cached value. (Fix #12)
    func refreshModelSizeOnDisk() {
        let dir = modelDirectory
        Task.detached(priority: .utility) {
            let sizeString: String
            if let size = try? FileManager.default.allocatedSizeOfDirectory(at: dir), size > 0 {
                let formatter = ByteCountFormatter()
                formatter.allowedUnits = [.useMB, .useGB]
                formatter.countStyle = .file
                sizeString = formatter.string(fromByteCount: Int64(size))
            } else {
                sizeString = ""
            }
            await MainActor.run { [sizeString] in
                self.modelSizeOnDiskCached = sizeString
            }
        }
    }

    /// UserDefaults key for the stored model path, unique per variant.
    private var modelPathKey: String {
        "whisperModelPath_\(selectedVariant.rawValue)"
    }
}

// MARK: - WhisperTranscriber

/// Transcriber that uses WhisperKit (OpenAI Whisper) for speech recognition.
/// Records audio into a buffer while the hotkey is held, then transcribes all at once on release.
@MainActor
class WhisperTranscriber: ObservableObject, TranscriberProtocol {
    @Published var isRecording = false
    @Published var audioLevel: Float = 0.0
    @Published var transcribedText = ""
    @Published var isEnhancing = false

    var onTranscriptionFinished: ((String) -> Void)?
    var selectedDeviceID: AudioDeviceID?

    /// Custom words to bias recognition toward (names, abbreviations, etc.)
    var customWords: [String] = []

    private let audioEngine = AVAudioEngine()
    private let modelManager: WhisperModelManager

    /// Thread-safe audio buffer protected by a serial queue.
    /// The audio tap callback writes from the audio thread; stopRecording reads from the main thread.
    private let bufferQueue = DispatchQueue(label: "com.kaze.whisper.audioBuffer")
    private var _audioBuffer: [Float] = []
    private var _inputSampleRate: Double = 16000

    /// Maximum recording duration in seconds (prevents unbounded memory growth).
    private static let maxRecordingSeconds: Double = 300 // 5 minutes
    /// Pre-allocated capacity for expected recording duration at typical sample rate (48kHz × 60s).
    private static let initialBufferCapacity: Int = 48000 * 60

    init(modelManager: WhisperModelManager) {
        self.modelManager = modelManager
    }

    func requestPermissions() async -> Bool {
        // Whisper only needs microphone access (no SFSpeechRecognizer authorization needed)
        let micStatus = await AVCaptureDevice.requestAccess(for: .audio)
        return micStatus
    }

    func startRecording() {
        guard !isRecording else { return }

        // Reset buffer with pre-allocation (Fix #3: avoid repeated reallocations)
        bufferQueue.sync {
            _audioBuffer = []
            _audioBuffer.reserveCapacity(Self.initialBufferCapacity)
        }
        transcribedText = ""
        audioLevel = 0

        do {
            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            let sampleRate = recordingFormat.sampleRate
            let maxSamples = Int(sampleRate * Self.maxRecordingSeconds)

            // Capture sample rate before recording starts (Fix #10)
            bufferQueue.sync { _inputSampleRate = sampleRate }

            // We need 16kHz mono for Whisper. We'll convert at the end.
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                guard let self else { return }

                if let channelData = buffer.floatChannelData?[0] {
                    let frameLength = Int(buffer.frameLength)

                    // Fix #1: Thread-safe buffer access via serial queue
                    self.bufferQueue.sync {
                        // Fix #3: Enforce max recording duration
                        guard self._audioBuffer.count < maxSamples else { return }
                        let remaining = maxSamples - self._audioBuffer.count
                        let samplesToAppend = min(frameLength, remaining)
                        self._audioBuffer.append(contentsOf: UnsafeBufferPointer(start: channelData, count: samplesToAppend))
                    }

                    // Compute audio level for waveform visualization
                    if frameLength > 0 {
                        var rms: Float = 0
                        for i in 0..<frameLength {
                            rms += channelData[i] * channelData[i]
                        }
                        rms = sqrt(rms / Float(frameLength))
                        let normalized = min(rms * 20, 1.0)
                        Task { @MainActor [weak self] in
                            self?.audioLevel = normalized
                        }
                    }
                }
            }

            applyInputDevice(selectedDeviceID, to: audioEngine)
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
        } catch {
            print("WhisperTranscriber: Failed to start recording: \(error)")
        }
    }

    func stopRecording() {
        guard isRecording else { return }

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        isRecording = false

        // Fix #1: Thread-safe buffer extraction
        let (capturedAudio, sampleRate) = bufferQueue.sync {
            let audio = _audioBuffer
            let rate = _inputSampleRate
            _audioBuffer = []
            return (audio, rate)
        }

        guard !capturedAudio.isEmpty else {
            onTranscriptionFinished?("")
            return
        }

        Task {
            await transcribeAudio(capturedAudio, inputSampleRate: sampleRate)
        }
    }

    private func transcribeAudio(_ samples: [Float], inputSampleRate: Double) async {
        do {
            let kit = try await modelManager.loadModel()

            let targetSampleRate = Double(WhisperKit.sampleRate) // 16000

            // Fix #5: Move resampling off the main thread using vDSP
            let audioForWhisper: [Float]
            if abs(inputSampleRate - targetSampleRate) > 1.0 {
                audioForWhisper = await Task.detached(priority: .userInitiated) {
                    Self.resample(samples, from: inputSampleRate, to: targetSampleRate)
                }.value
            } else {
                audioForWhisper = samples
            }

            // Build decoding options with custom vocabulary as initial prompt
            var decodeOptions = DecodingOptions()
            if !customWords.isEmpty, let tokenizer = kit.tokenizer {
                let prompt = customWords.joined(separator: ", ")
                let promptTokens = tokenizer.encode(text: prompt)
                decodeOptions.promptTokens = promptTokens
            }

            let results: [TranscriptionResult] = try await kit.transcribe(audioArray: audioForWhisper, decodeOptions: decodeOptions)
            let text = results.compactMap { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

            transcribedText = text
            onTranscriptionFinished?(text)
        } catch {
            print("WhisperTranscriber: Transcription failed: \(error)")
            onTranscriptionFinished?("")
        }
    }

    /// Resampling using Accelerate/vDSP for SIMD-accelerated performance.
    /// Runs off the main thread. (Fix #5)
    private nonisolated static func resample(_ samples: [Float], from sourceSampleRate: Double, to targetSampleRate: Double) -> [Float] {
        let ratio = targetSampleRate / sourceSampleRate
        let outputLength = Int(Double(samples.count) * ratio)
        guard outputLength > 0 else { return [] }
        var output = [Float](repeating: 0, count: outputLength)

        // Use vDSP linear interpolation
        var control = (0..<outputLength).map { Float(Double($0) / ratio) }
        vDSP_vlint(samples, &control, 1, &output, 1, vDSP_Length(outputLength), vDSP_Length(samples.count))

        return output
    }
}

// MARK: - FileManager helper

extension FileManager {
    /// Calculates the total allocated size of a directory and its contents.
    nonisolated func allocatedSizeOfDirectory(at url: URL) throws -> UInt64 {
        var totalSize: UInt64 = 0
        let enumerator = self.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        while let fileURL = enumerator?.nextObject() as? URL {
            let resourceValues = try fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            totalSize += UInt64(resourceValues.totalFileAllocatedSize ?? resourceValues.fileAllocatedSize ?? 0)
        }
        return totalSize
    }
}
