import AVFoundation
import CoreMedia
import Accelerate
import CoreAudio
import Synchronization
import os

nonisolated struct AudioInputDevice: Identifiable, Hashable {
    let id: String
    let name: String

    /// Virtual inputs that aren't real microphones and should never be used
    /// for dictation. Matched against the device name and unique ID.
    static let ignoredDevices = ["ZoomAudioDevice"]

    static func isIgnored(_ device: AVCaptureDevice) -> Bool {
        ignoredDevices.contains { pattern in
            device.localizedName.localizedCaseInsensitiveContains(pattern)
                || device.uniqueID.localizedCaseInsensitiveContains(pattern)
        }
    }

    /// Every usable microphone, excluding ignored virtual devices.
    static var usableCaptureDevices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
            .devices
            .filter { !isIgnored($0) }
    }

    static func all() -> [AudioInputDevice] {
        usableCaptureDevices
            .map { AudioInputDevice(id: $0.uniqueID, name: $0.localizedName) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The system default input, unless it's an ignored device; then the
    /// built-in microphone, then any other real one.
    static var defaultCaptureDevice: AVCaptureDevice? {
        if let system = AVCaptureDevice.default(for: .audio), !isIgnored(system) {
            return system
        }
        let usable = usableCaptureDevices
        return usable.first { $0.transportType == Int32(bitPattern: kAudioDeviceTransportTypeBuiltIn) } ?? usable.first
    }

    static var defaultDeviceName: String? {
        defaultCaptureDevice?.localizedName
    }
}

enum AudioRecorderError: LocalizedError {
    case microphoneUnavailable
    case permissionDenied
    case configurationFailed

    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable: "No microphone is available."
        case .permissionDenied: "Kaze doesn't have microphone access."
        case .configurationFailed: "The microphone couldn't be started."
        }
    }
}

/// Captures microphone audio and delivers it as 16 kHz mono Float32, the
/// format every speech engine in Kaze consumes. Capture runs on its own
/// queues; nothing here blocks the main thread.
nonisolated final class AudioRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    static let sampleRate: Double = 16_000

    /// Called on the capture queue with each converted chunk.
    var onSamples: (@Sendable ([Float]) -> Void)? {
        get { state.withLock { $0.onSamples } }
        set { state.withLock { $0.onSamples = newValue } }
    }

    /// Called on the capture queue with a 0...1 loudness value per chunk.
    var onLevel: (@Sendable (Float) -> Void)? {
        get { state.withLock { $0.onLevel } }
        set { state.withLock { $0.onLevel = newValue } }
    }

    private struct State {
        var samples: [Float] = []
        var peakLevel: Float = 0
        var isCapturing = false
        var onSamples: (@Sendable ([Float]) -> Void)?
        var onLevel: (@Sendable (Float) -> Void)?
    }

    private let state = Mutex(State())
    private let sessionQueue = DispatchQueue(label: "com.kaze.audio.session")
    private let captureQueue = DispatchQueue(label: "com.kaze.audio.capture", qos: .userInteractive)
    private let session = AVCaptureSession()
    private var output: AVCaptureAudioDataOutput?
    private var input: AVCaptureDeviceInput?

    // Conversion and file state; only touched on `captureQueue`.
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var file: AVAudioFile?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate, channels: 1, interleaved: false)!

    private let log = Logger(subsystem: "com.fayazahmed.Kaze", category: "Audio")

    /// Starts capturing. Returns once the device is configured; audio begins
    /// flowing a moment later. With `fileURL`, audio is also written to disk
    /// as it arrives, so a crash mid-dictation still leaves a playable file.
    func start(deviceID: String?, fileURL: URL? = nil) async throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw AudioRecorderError.permissionDenied
        }
        state.withLock {
            $0.samples.removeAll(keepingCapacity: true)
            $0.samples.reserveCapacity(Int(Self.sampleRate) * 60)
            $0.peakLevel = 0
            $0.isCapturing = true
        }
        captureQueue.async { [self] in
            file = fileURL.flatMap(Self.makeFile)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [self] in
                do {
                    try configure(deviceID: deviceID)
                    session.startRunning()
                    continuation.resume()
                } catch {
                    state.withLock { $0.isCapturing = false }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Stops capturing and returns everything recorded since `start`.
    func stop() async -> (samples: [Float], peakLevel: Float) {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [self] in
                if session.isRunning { session.stopRunning() }
                continuation.resume()
            }
        }
        // Drain chunks already queued for conversion, then close the file.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            captureQueue.async { [self] in
                file = nil
                continuation.resume()
            }
        }
        return state.withLock { state in
            state.isCapturing = false
            let result = (state.samples, state.peakLevel)
            state.samples = []
            return result
        }
    }

    private func configure(deviceID: String?) throws {
        let device: AVCaptureDevice?
        if let deviceID, !deviceID.isEmpty {
            device = AVCaptureDevice(uniqueID: deviceID).flatMap { AudioInputDevice.isIgnored($0) ? nil : $0 }
                ?? AudioInputDevice.defaultCaptureDevice
        } else {
            device = AudioInputDevice.defaultCaptureDevice
        }
        guard let device else { throw AudioRecorderError.microphoneUnavailable }

        // Reuse the existing configuration when the device hasn't changed.
        if let input, input.device.uniqueID == device.uniqueID, output != nil {
            return
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if let input { session.removeInput(input) }
        if let output { session.removeOutput(output) }
        input = nil
        output = nil

        let newInput: AVCaptureDeviceInput
        do {
            newInput = try AVCaptureDeviceInput(device: device)
        } catch {
            throw AudioRecorderError.configurationFailed
        }
        guard session.canAddInput(newInput) else { throw AudioRecorderError.configurationFailed }
        session.addInput(newInput)

        let newOutput = AVCaptureAudioDataOutput()
        newOutput.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(newOutput) else { throw AudioRecorderError.configurationFailed }
        session.addOutput(newOutput)

        input = newInput
        output = newOutput
        log.info("Microphone: \(device.localizedName, privacy: .public)")
    }

    // MARK: - Capture

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard state.withLock({ $0.isCapturing }), let chunk = convert(sampleBuffer), !chunk.isEmpty else { return }

        let level = Self.level(of: chunk)
        let (onSamples, onLevel) = state.withLock { state in
            state.samples.append(contentsOf: chunk)
            state.peakLevel = max(state.peakLevel, level)
            return (state.onSamples, state.onLevel)
        }
        onSamples?(chunk)
        onLevel?(level)
        write(chunk)
    }

    private func write(_ chunk: [Float]) {
        guard let file, let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(chunk.count)) else { return }
        buffer.frameLength = buffer.frameCapacity
        chunk.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: chunk.count) }
        do {
            try file.write(from: buffer)
        } catch {
            log.error("Couldn't write recording: \(error.localizedDescription, privacy: .public)")
            self.file = nil
        }
    }

    private func convert(_ sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let inputFormat = AVAudioFormat(cmAudioFormatDescription: description)
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0, let pcm = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else { return nil }
        pcm.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frameCount), into: pcm.mutableAudioBufferList)
        guard status == noErr else { return nil }

        if converter == nil || converterInputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            converterInputFormat = inputFormat
        }
        guard let converter else { return nil }

        let capacity = AVAudioFrameCount(Double(frameCount) * outputFormat.sampleRate / inputFormat.sampleRate) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return pcm
        }
        guard error == nil, let channel = converted.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
    }

    /// Perceptual loudness in 0...1, mapped from -50 dBFS...-10 dBFS.
    private static func level(of samples: [Float]) -> Float {
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        let db = 20 * log10(max(rms, 1e-7))
        return min(max((db + 50) / 40, 0), 1)
    }

    // MARK: - Recordings on disk

    /// 16-bit CAF. Core Audio updates the header on every write, so the file
    /// stays readable up to the last chunk even if Kaze never closes it.
    private static func makeFile(at url: URL) -> AVAudioFile? {
        _ = StorageLocations.ensure(url.deletingLastPathComponent())
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        return try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// Reads a saved recording back as 16 kHz mono Float32.
    static func readRecording(at url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw AudioRecorderError.configurationFailed
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    /// Length of a saved recording in seconds, or 0 if it can't be read.
    static func duration(ofRecordingAt url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }
}
