import AppKit
import AVFoundation
import Observation
import ServiceManagement

enum AVPermissions {
    static var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static var microphoneUndetermined: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    static func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }

    /// Adds Kaze to the Accessibility list and shows the system prompt.
    static func promptForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

/// Live permission state for onboarding and Settings. Accessibility has no
/// change notification, so it's polled while someone is watching.
@Observable
final class PermissionMonitor {
    private(set) var microphone = AVPermissions.microphoneGranted
    private(set) var accessibility = AXIsProcessTrusted()

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored var onAccessibilityGranted: (() -> Void)?

    var allGranted: Bool { microphone && accessibility }

    func refresh() {
        microphone = AVPermissions.microphoneGranted
        let trusted = AXIsProcessTrusted()
        if trusted, !accessibility { onAccessibilityGranted?() }
        accessibility = trusted
    }

    func beginWatching() {
        watchers += 1
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func endWatching() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    func requestMicrophone() async {
        _ = await AVPermissions.requestMicrophone()
        refresh()
        if !microphone { AVPermissions.openMicrophoneSettings() }
    }
}

enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Kaze: could not update login item: \(error.localizedDescription)")
        }
    }
}

enum Sounds {
    enum Cue {
        case start, stop, cancel, error

        var name: String {
            switch self {
            case .start: "Tink"
            case .stop: "Pop"
            case .cancel: "Bottle"
            case .error: "Funk"
            }
        }
    }

    private static var cache: [String: NSSound] = [:]

    static func play(_ cue: Cue, enabled: Bool) {
        guard enabled else { return }
        let sound = cache[cue.name] ?? NSSound(named: NSSound.Name(cue.name))?.copy() as? NSSound
        guard let sound else { return }
        cache[cue.name] = sound
        sound.volume = 0.22
        sound.stop()
        sound.play()
    }
}
