import AppKit
import AVFoundation
import Observation

/// The app's object graph. Created once at launch and shared by every window.
@Observable
final class AppModel {
    static let shared = AppModel()

    let preferences = Preferences.shared
    let models = ModelManager()
    let vocabulary = VocabularyStore()
    let history = HistoryStore()
    let permissions = PermissionMonitor()
    let updater = UpdaterManager()
    let dictation: DictationController

    private init() {
        // A previously chosen mic that's now ignored (e.g. Zoom's virtual
        // device) falls back to the default.
        if let id = preferences.microphoneID, let device = AVCaptureDevice(uniqueID: id), AudioInputDevice.isIgnored(device) {
            preferences.microphoneID = nil
        }
        history.recoverInterruptedRecordings(model: preferences.speechModel)
        dictation = DictationController(preferences: preferences, models: models, vocabulary: vocabulary, history: history)
        permissions.onAccessibilityGranted = { [weak self] in
            self?.startShortcutMonitoring()
        }
    }

    /// Whether the shortcut is live (needs Accessibility).
    private(set) var isShortcutActive = false

    func startShortcutMonitoring() {
        if !dictation.hotkey.isRunning {
            dictation.startMonitoring()
        }
        isShortcutActive = dictation.hotkey.isRunning
    }

    func selectSpeechModel(_ model: SpeechModel) {
        preferences.speechModel = model
        if models.state(of: model).isInstalled {
            models.warmUp(model)
        } else if model.requiresDownload == false || !models.state(of: model).isDownloading {
            models.download(model)
        }
    }

    func setShortcut(_ shortcut: Shortcut) {
        preferences.shortcut = shortcut
        dictation.shortcutDidChange()
    }

    func setLanguage(_ language: String?) {
        preferences.language = language
        Task { await models.refreshAppleState() }
    }
}
