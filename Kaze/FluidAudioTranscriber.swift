import Foundation
import AVFoundation
import CoreAudio
import Combine
import FluidAudio

// MARK: - FluidAudio Model Type

enum FluidAudioModel: String, CaseIterable, Identifiable {
    case parakeet
    case qwen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .parakeet: return "Parakeet TDT 0.6B v3"
        case .qwen: return "Qwen3 ASR 0.6B"
        }
    }

    var sizeDescription: String {
        switch self {
        case .parakeet: return "~600 MB"
        case .qwen: return "~2.5 GB"
        }
    }

    var qualityDescription: String {
        switch self {
        case .parakeet: return "Top-ranked accuracy, blazing fast. English only."
        case .qwen: return "Fast multilingual transcription, 30+ languages."
        }
    }

    var provider: String {
        switch self {
        case .parakeet: return "NVIDIA"
        case .qwen: return "Alibaba"
        }
    }

    /// HuggingFace repo ID used for download.
    var repoId: String {
        switch self {
        case .parakeet: return "FluidInference/parakeet-tdt-0.6b-v3-coreml"
        case .qwen: return "FluidInference/qwen3-asr-0.6b-coreml"
        }
    }

    /// Subfolder within the HuggingFace repo (if any).
    var repoSubfolder: String? {
        switch self {
        case .parakeet: return nil
        case .qwen: return "f32"
        }
    }
}

// MARK: - FluidAudioModelManager

/// Manages FluidAudio model download state for Parakeet and Qwen models.
@MainActor
class FluidAudioModelManager: ObservableObject {
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

    let model: FluidAudioModel

    // Loaded runtime objects
    private var parakeetManager: AsrManager?
    private var qwen3Manager: Qwen3AsrManager?
    private var loadTask: Task<Void, any Error>?

    init(model: FluidAudioModel) {
        self.model = model
        checkExistingModel()
    }

    /// The default cache directory where FluidAudio stores downloaded models.
    var modelDirectory: URL {
        switch model {
        case .parakeet:
            return AsrModels.defaultCacheDirectory(for: .v3)
        case .qwen:
            return Qwen3AsrModels.defaultCacheDirectory()
        }
    }

    func checkExistingModel() {
        switch model {
        case .parakeet:
            let dir = AsrModels.defaultCacheDirectory(for: .v3)
            if AsrModels.modelsExist(at: dir, version: .v3) {
                state = .downloaded
                refreshModelSizeOnDisk()
            } else {
                state = .notDownloaded
                modelSizeOnDiskCached = ""
            }
        case .qwen:
            let dir = Qwen3AsrModels.defaultCacheDirectory()
            if Qwen3AsrModels.modelsExist(at: dir) {
                state = .downloaded
                refreshModelSizeOnDisk()
            } else {
                state = .notDownloaded
                modelSizeOnDiskCached = ""
            }
        }
    }

    /// Downloads the model. FluidAudio handles the HuggingFace download internally.
    func downloadModel() async {
        guard case .notDownloaded = state else { return }

        // FluidAudio's download APIs don't expose granular progress,
        // so we show an indeterminate progress state.
        state = .downloading(progress: -1)

        do {
            switch model {
            case .parakeet:
                try await AsrModels.download(version: .v3)
                state = .downloaded
                refreshModelSizeOnDisk()

            case .qwen:
                try await Qwen3AsrModels.download()
                state = .downloaded
                refreshModelSizeOnDisk()
            }
        } catch {
            state = .error("Download failed: \(error.localizedDescription)")
        }
    }

    /// Loads the model into memory, returning when ready for transcription.
    func loadModel() async throws {
        if parakeetManager != nil || qwen3Manager != nil {
            state = .ready
            return
        }

        // If a load is already in-flight, await it instead of starting a duplicate.
        if let existing = loadTask {
            try await existing.value
            return
        }

        state = .loading

        let task = Task<Void, any Error> {
            switch model {
            case .parakeet:
                let dir = AsrModels.defaultCacheDirectory(for: .v3)
                let asrModels = try await AsrModels.load(from: dir, version: .v3)
                let manager = AsrManager(config: .default)
                try await manager.initialize(models: asrModels)
                await MainActor.run { parakeetManager = manager }

            case .qwen:
                let dir = Qwen3AsrModels.defaultCacheDirectory()
                let manager = Qwen3AsrManager()
                try await manager.loadModels(from: dir)
                await MainActor.run { qwen3Manager = manager }
            }
        }
        loadTask = task

        do {
            try await task.value
            loadTask = nil
            state = .ready
            refreshModelSizeOnDisk()
        } catch {
            loadTask = nil
            throw error
        }
    }

    /// Transcribes audio from a file URL.
    func transcribe(audioURL: URL) async throws -> String {
        switch model {
        case .parakeet:
            guard let manager = parakeetManager else {
                throw FluidAudioTranscriberError.modelNotLoaded
            }
            let result = try await manager.transcribe(audioURL, source: .system)
            return normalizeTranscript(result.text)

        case .qwen:
            guard let manager = qwen3Manager else {
                throw FluidAudioTranscriberError.modelNotLoaded
            }
            let audioConverter = AudioConverter()
            let audioSamples = try audioConverter.resampleAudioFile(audioURL)
            let text = try await manager.transcribe(audioSamples: audioSamples)
            return normalizeTranscript(text)
        }
    }

    /// Deletes the downloaded model files.
    func deleteModel() {
        parakeetManager = nil
        qwen3Manager = nil

        let dir = modelDirectory
        try? FileManager.default.removeItem(at: dir)
        state = .notDownloaded
        modelSizeOnDiskCached = ""
    }

    /// Releases the loaded runtime from memory while keeping files on disk.
    func unloadModelFromMemory() {
        loadTask?.cancel()
        loadTask = nil
        parakeetManager = nil
        qwen3Manager = nil
        switch state {
        case .ready, .loading:
            state = .downloaded
        default:
            break
        }
    }

    /// Size of the model on disk (cached, not computed on every view redraw).
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

    /// Whether a loaded runtime instance is available.
    var isLoaded: Bool {
        parakeetManager != nil || qwen3Manager != nil
    }

    private func normalizeTranscript(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum FluidAudioTranscriberError: LocalizedError {
    case modelNotLoaded
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "FluidAudio model is not loaded."
        case .emptyAudio:
            return "No audio was recorded."
        }
    }
}

// MARK: - FluidAudioTranscriber

/// Transcriber that uses FluidAudio (Parakeet or Qwen) for speech recognition.
/// Records audio into a buffer while the hotkey is held, writes to a temp WAV file,
/// then transcribes on release.
@MainActor
class FluidAudioTranscriber: ObservableObject, TranscriberProtocol {
    @Published var isRecording = false
    @Published var audioLevel: Float = 0.0
    @Published var transcribedText = ""
    @Published var isEnhancing = false

    var onTranscriptionFinished: ((String) -> Void)?
    var selectedDeviceID: AudioDeviceID?

    let model: FluidAudioModel
    private let modelManager: FluidAudioModelManager

    private let audioEngine = AVAudioEngine()

    /// Thread-safe audio buffer protected by a serial queue.
    private let bufferQueue = DispatchQueue(label: "com.kaze.fluidaudio.audioBuffer")
    private var _audioBuffer: [Float] = []
    private var _inputSampleRate: Double = 16000
    private var transcriptionTask: Task<Void, Never>?

    /// Maximum recording duration in seconds.
    private static let maxRecordingSeconds: Double = 300 // 5 minutes
    private static let initialBufferCapacity: Int = 48000 * 60

    init(model: FluidAudioModel, modelManager: FluidAudioModelManager) {
        self.model = model
        self.modelManager = modelManager
    }

    deinit {
        transcriptionTask?.cancel()
    }

    func requestPermissions() async -> Bool {
        let micStatus = await AVCaptureDevice.requestAccess(for: .audio)
        return micStatus
    }

    func startRecording() {
        guard !isRecording else { return }
        transcriptionTask?.cancel()
        transcriptionTask = nil

        // Reset buffer with pre-allocation
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

            // Capture sample rate before recording starts
            bufferQueue.sync { _inputSampleRate = sampleRate }

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                guard let self else { return }

                if let channelData = buffer.floatChannelData?[0] {
                    let frameLength = Int(buffer.frameLength)

                    // Fix #1: Thread-safe buffer access
                    self.bufferQueue.sync {
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
            print("FluidAudioTranscriber: Failed to start recording: \(error)")
            audioEngine.inputNode.removeTap(onBus: 0)
            isRecording = false
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

        transcriptionTask?.cancel()
        transcriptionTask = Task { [weak self] in
            await self?.transcribeAudio(capturedAudio, sampleRate: sampleRate)
        }
    }

    private func transcribeAudio(_ samples: [Float], sampleRate: Double) async {
        guard !Task.isCancelled else { return }
        do {
            // Ensure model is loaded
            try await modelManager.loadModel()
            guard !Task.isCancelled else { return }

            // Write audio to a temporary WAV file (FluidAudio/Parakeet needs a file URL)
            let tempURL = try writeWAVFile(samples: samples, sampleRate: sampleRate)
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let text = try await modelManager.transcribe(audioURL: tempURL)
            guard !Task.isCancelled else { return }

            transcribedText = text
            onTranscriptionFinished?(text)
        } catch {
            guard !Task.isCancelled else { return }
            print("FluidAudioTranscriber: Transcription failed: \(error)")
            onTranscriptionFinished?("")
        }
    }

    /// Writes raw float samples to a temporary WAV file.
    /// Uses memcpy instead of element-by-element copy (Fix #4).
    private func writeWAVFile(samples: [Float], sampleRate: Double) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent("kaze_recording_\(UUID().uuidString).wav")

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!

        let frameCount = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw FluidAudioTranscriberError.emptyAudio
        }

        buffer.frameLength = frameCount
        // Fix #4: Use memcpy instead of element-by-element loop
        let channelData = buffer.floatChannelData![0]
        samples.withUnsafeBufferPointer { src in
            channelData.update(from: src.baseAddress!, count: samples.count)
        }

        let file = try AVAudioFile(forWriting: tempURL, settings: format.settings)
        try file.write(from: buffer)

        return tempURL
    }
}
