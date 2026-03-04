import Foundation
import Speech
import AVFoundation
import CoreAudio
import Combine

@MainActor
class SpeechTranscriber: ObservableObject, TranscriberProtocol {
    @Published var isRecording = false
    @Published var audioLevel: Float = 0.0
    @Published var transcribedText = ""
    @Published var isEnhancing = false

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    private var finalizeTimeoutTask: Task<Void, Never>?
    private var hasDeliveredFinalResult = false

    var onTranscriptionFinished: ((String) -> Void)?
    var selectedDeviceID: AudioDeviceID?

    /// Custom words to hint the recognizer toward (names, abbreviations, etc.)
    var customWords: [String] = []

    init() {
        speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
    }

    func requestPermissions() async -> Bool {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else { return false }

        let micStatus = await AVCaptureDevice.requestAccess(for: .audio)
        return micStatus
    }

    func startRecording() {
        guard !isRecording else { return }
        guard let recognizer = speechRecognizer, recognizer.isAvailable else { return }

        cleanupSessionState()
        transcribedText = ""
        audioLevel = 0
        hasDeliveredFinalResult = false

        do {
            try startSpeechRecognition(recognizer: recognizer)
            isRecording = true
        } catch {
            print("Failed to start recording: \(error)")
            cleanupSessionState()
        }
    }

    func stopRecording() {
        guard isRecording else { return }

        stopAudioCapture()
        isRecording = false

        finalizeTimeoutTask?.cancel()
        finalizeTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            await MainActor.run {
                self?.forceFinalizeIfNeeded()
            }
        }
    }

    private func cleanupSessionState() {
        finalizeTimeoutTask?.cancel()
        finalizeTimeoutTask = nil

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
    }

    private func stopAudioCapture() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
    }

    private func forceFinalizeIfNeeded() {
        guard !hasDeliveredFinalResult else { return }
        finishRecognition(with: transcribedText)
    }

    private func finishRecognition(with text: String) {
        guard !hasDeliveredFinalResult else { return }
        hasDeliveredFinalResult = true

        finalizeTimeoutTask?.cancel()
        finalizeTimeoutTask = nil

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        onTranscriptionFinished?(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func startSpeechRecognition(recognizer: SFSpeechRecognizer) throws {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if !customWords.isEmpty {
            request.contextualStrings = customWords
        }
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        // Capture the request reference for thread-safe access in the audio tap callback
        let capturedRequest = request
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            // SFSpeechAudioBufferRecognitionRequest.append is thread-safe
            capturedRequest.append(buffer)

            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            if frameLength == 0 { return }

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

        applyInputDevice(selectedDeviceID, to: audioEngine)
        audioEngine.prepare()
        try audioEngine.start()

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                Task { @MainActor in
                    self.transcribedText = text
                    if result.isFinal {
                        self.finishRecognition(with: text)
                    }
                }
            }

            if let error {
                let nsError = error as NSError
                if nsError.domain != "kAFAssistantErrorDomain" || (nsError.code != 216 && nsError.code != 1110) {
                    print("Recognition error: \(error)")
                }

                Task { @MainActor in
                    if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110 {
                        self.finishRecognition(with: "")
                        return
                    }

                    self.finishRecognition(with: self.transcribedText)
                }
            }
        }
    }
}
