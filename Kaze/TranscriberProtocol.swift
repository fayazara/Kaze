import Foundation
import Combine
import AVFoundation
import CoreAudio

/// Protocol that both SpeechTranscriber (Direct Dictation) and WhisperTranscriber conform to.
/// Provides a unified interface for the AppDelegate to interact with either engine.
@MainActor
protocol TranscriberProtocol: ObservableObject {
    var isRecording: Bool { get }
    var audioLevel: Float { get }
    var transcribedText: String { get }
    var isEnhancing: Bool { get set }

    /// The Core Audio device ID to use for recording, or `nil` for the system default.
    var selectedDeviceID: AudioDeviceID? { get set }

    var onTranscriptionFinished: ((String) -> Void)? { get set }

    func requestPermissions() async -> Bool
    func startRecording()
    func stopRecording()
}

/// Sets the input device on an AVAudioEngine's input node before prepare/start.
func applyInputDevice(_ deviceID: AudioDeviceID?, to engine: AVAudioEngine) {
    guard let deviceID else { return }
    var devID = deviceID
    let inputNode = engine.inputNode
    guard let audioUnit = inputNode.audioUnit else { return }
    AudioUnitSetProperty(
        audioUnit,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global,
        0,
        &devID,
        UInt32(MemoryLayout<AudioDeviceID>.size)
    )
}
