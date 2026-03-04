import SwiftUI
import AppKit
import CoreAudio

enum TranscriptionEngine: String, CaseIterable, Identifiable {
    case dictation
    case whisper
    case parakeet
    case qwen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: return "Direct Dictation"
        case .whisper: return "Whisper (OpenAI)"
        case .parakeet: return "Parakeet v3 (NVIDIA)"
        case .qwen: return "Qwen3 ASR (Alibaba)"
        }
    }

    var description: String {
        switch self {
        case .dictation: return "Uses Apple's built-in speech recognition. Works immediately with no setup."
        case .whisper: return "Uses OpenAI's Whisper model running locally on your Mac. Requires a one-time download."
        case .parakeet: return "NVIDIA's Parakeet TDT 0.6B v3 via CoreML. Top-ranked accuracy, blazing fast. English only."
        case .qwen: return "Alibaba's Qwen3 ASR 0.6B via CoreML. Fast multilingual transcription with 30+ languages."
        }
    }

    /// Whether this engine requires a model download before use.
    var requiresModelDownload: Bool {
        switch self {
        case .dictation: return false
        case .whisper, .parakeet, .qwen: return true
        }
    }
}

enum HotkeyMode: String, CaseIterable, Identifiable {
    case holdToTalk
    case toggle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .holdToTalk: return "Hold to Talk"
        case .toggle: return "Press to Toggle"
        }
    }

    var description: String {
        switch self {
        case .holdToTalk: return "Hold the hotkey to record, release to stop."
        case .toggle: return "Press the hotkey once to start, press again to stop."
        }
    }
}

enum EnhancementMode: String, CaseIterable, Identifiable {
    case off
    case appleIntelligence

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .appleIntelligence: return "Apple Intelligence"
        }
    }
}

enum AppPreferenceKey {
    static let transcriptionEngine = "transcriptionEngine"
    static let enhancementMode = "enhancementMode"
    static let enhancementSystemPrompt = "enhancementSystemPrompt"
    static let hotkeyMode = "hotkeyMode"
    static let hotkeyShortcut = "hotkeyShortcut"
    static let whisperModelVariant = "whisperModelVariant"
    static let fluidAudioModelState = "fluidAudioModelState"
    static let notchMode = "notchMode"
    static let selectedMicrophoneID = "selectedMicrophoneID"
    static let appendTrailingSpace = "appendTrailingSpace"

    static let defaultEnhancementPrompt = """
        You are Kaze, a speech-to-text transcription assistant. Your only job is to \
        enhance raw transcription output. Fix punctuation, add missing commas, correct \
        capitalization, and improve formatting. Do not alter the meaning, tone, or \
        substance of the text. Do not add, remove, or rephrase any content. Do not \
        add commentary or explanations. Return only the cleaned-up text.
        """
}

@main
struct KazeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            ContentView(
                whisperModelManager: appDelegate.whisperModelManager,
                parakeetModelManager: appDelegate.parakeetModelManager,
                qwenModelManager: appDelegate.qwenModelManager,
                historyManager: appDelegate.historyManager,
                customWordsManager: appDelegate.customWordsManager
            )
            .frame(minWidth: 480, maxWidth: 520)
        }
    }
}

// MARK: - AppDelegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private let speechTranscriber = SpeechTranscriber()
    private var whisperTranscriber: WhisperTranscriber?
    private var fluidAudioTranscriber: FluidAudioTranscriber?
    let whisperModelManager = WhisperModelManager()
    let parakeetModelManager = FluidAudioModelManager(model: .parakeet)
    let qwenModelManager = FluidAudioModelManager(model: .qwen)
    let historyManager = TranscriptionHistoryManager()
    let customWordsManager = CustomWordsManager()

    private let hotkeyManager = HotkeyManager()
    private let overlayWindow = RecordingOverlayWindow()
    private let overlayState = OverlayState()
    private var statusItem: NSStatusItem?

    private var enhancer: TextEnhancer?
    private var settingsWindowController: NSWindowController?

    var transcriptionEngine: TranscriptionEngine {
        get {
            let raw = UserDefaults.standard.string(forKey: AppPreferenceKey.transcriptionEngine)
            return TranscriptionEngine(rawValue: raw ?? "") ?? .dictation
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: AppPreferenceKey.transcriptionEngine)
        }
    }

    private var enhancementMode: EnhancementMode {
        get {
            let raw = UserDefaults.standard.string(forKey: AppPreferenceKey.enhancementMode)
            return EnhancementMode(rawValue: raw ?? "") ?? .off
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: AppPreferenceKey.enhancementMode)
        }
    }

    private var hotkeyMode: HotkeyMode {
        get {
            let raw = UserDefaults.standard.string(forKey: AppPreferenceKey.hotkeyMode)
            return HotkeyMode(rawValue: raw ?? "") ?? .holdToTalk
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: AppPreferenceKey.hotkeyMode)
        }
    }

    private var notchModeEnabled: Bool {
        UserDefaults.standard.bool(forKey: AppPreferenceKey.notchMode)
    }

    /// Returns the Core Audio device ID for the user-selected microphone, or nil for system default.
    private var selectedMicrophoneDeviceID: AudioDeviceID? {
        let stored = UserDefaults.standard.string(forKey: AppPreferenceKey.selectedMicrophoneID) ?? ""
        guard !stored.isEmpty, let id = UInt32(stored) else { return nil }
        return id
    }

    private var hotkeyModeObserver: NSObjectProtocol?
    private var isSessionActive = false

    /// Returns the currently active transcriber based on the user's engine preference.
    private var activeTranscriber: (any TranscriberProtocol)? {
        switch transcriptionEngine {
        case .dictation:
            return speechTranscriber
        case .whisper:
            if whisperTranscriber == nil {
                whisperTranscriber = WhisperTranscriber(modelManager: whisperModelManager)
            }
            return whisperTranscriber
        case .parakeet:
            return getOrCreateFluidAudioTranscriber(model: .parakeet, manager: parakeetModelManager)
        case .qwen:
            return getOrCreateFluidAudioTranscriber(model: .qwen, manager: qwenModelManager)
        }
    }

    private func getOrCreateFluidAudioTranscriber(model: FluidAudioModel, manager: FluidAudioModelManager) -> FluidAudioTranscriber {
        if let existing = fluidAudioTranscriber, existing.model == model {
            return existing
        }
        let transcriber = FluidAudioTranscriber(model: model, modelManager: manager)
        fluidAudioTranscriber = transcriber
        return transcriber
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as an accessory so no Dock icon appears
        NSApp.setActivationPolicy(.accessory)
        migrateLegacyPreferences()

        // Set up Apple Intelligence enhancer if available
        if #available(macOS 26.0, *), TextEnhancer.isAvailable {
            enhancer = TextEnhancer()
        }

        // Menu bar icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            if let icon = NSImage(named: "kaze-icon") {
                icon.size = NSSize(width: 18, height: 18)
                icon.isTemplate = true
                button.image = icon
            } else {
                button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Kaze")
            }
            button.image?.accessibilityDescription = "Kaze"
        }
        buildMenu()

        Task {
            let granted = await speechTranscriber.requestPermissions()
            if !granted {
                showPermissionAlert()
                return
            }
            setupHotkey()
        }
    }

    private func migrateLegacyPreferences() {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: AppPreferenceKey.enhancementMode) == nil,
           defaults.object(forKey: "aiEnhanceEnabled") != nil {
            let oldEnabled = defaults.bool(forKey: "aiEnhanceEnabled")
            enhancementMode = oldEnabled ? .appleIntelligence : .off
        }
    }

    private func buildMenu() {
        let menu = NSMenu()

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Kaze", action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    @objc private func openSettings() {
        if let window = settingsWindowController?.window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let contentView = ContentView(
            whisperModelManager: whisperModelManager,
            parakeetModelManager: parakeetModelManager,
            qwenModelManager: qwenModelManager,
            historyManager: historyManager,
            customWordsManager: customWordsManager
        )
        .frame(minWidth: 480, maxWidth: 520)
        let hostingController = NSHostingController(rootView: contentView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 500, height: 400)
        window.center()
        window.title = "Kaze Settings"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false

        let controller = NSWindowController(window: window)
        settingsWindowController = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
    }

    private func setupHotkey() {
        hotkeyManager.mode = hotkeyMode
        hotkeyManager.shortcut = HotkeyShortcut.loadFromDefaults()
        hotkeyManager.onKeyDown = { [weak self] in
            self?.beginRecording()
        }
        hotkeyManager.onKeyUp = { [weak self] in
            self?.endRecording()
        }
        let started = hotkeyManager.start()
        if !started {
            showAccessibilityPermissionAlert()
        }

        // Observe changes to hotkey mode preference (Fix #6: early-exit avoids
        // unnecessary work when unrelated UserDefaults keys change)
        hotkeyModeObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let newMode = self.hotkeyMode
                if self.hotkeyManager.mode != newMode {
                    self.hotkeyManager.mode = newMode
                }

                let newShortcut = HotkeyShortcut.loadFromDefaults()
                if self.hotkeyManager.shortcut != newShortcut {
                    self.hotkeyManager.shortcut = newShortcut
                }
            }
        }
    }

    private func beginRecording() {
        guard !isSessionActive else { return }

        let engine = transcriptionEngine

        // Check if the selected engine's model is available
        if engine.requiresModelDownload && !isEngineReady(engine) {
            print("\(engine.title) model not ready, falling back to Direct Dictation")
        }

        isSessionActive = true

        // Pass current custom words and selected microphone to the transcriber
        let words = customWordsManager.words
        let micID = selectedMicrophoneDeviceID

        // Use the appropriate transcriber
        if engine == .whisper, isEngineReady(.whisper) {
            let whisper = whisperTranscriber ?? WhisperTranscriber(modelManager: whisperModelManager)
            whisperTranscriber = whisper
            whisper.customWords = words
            whisper.selectedDeviceID = micID
            whisper.onTranscriptionFinished = { [weak self] (text: String) in
                guard let self else { return }
                self.processTranscription(text)
            }
            overlayState.bind(to: whisper)
            overlayWindow.show(state: overlayState, notchMode: notchModeEnabled)
            whisper.startRecording()
        } else if (engine == .parakeet || engine == .qwen), isEngineReady(engine) {
            let manager = engine == .parakeet ? parakeetModelManager : qwenModelManager
            let model: FluidAudioModel = engine == .parakeet ? .parakeet : .qwen
            let transcriber = getOrCreateFluidAudioTranscriber(model: model, manager: manager)
            transcriber.selectedDeviceID = micID
            transcriber.onTranscriptionFinished = { [weak self] (text: String) in
                guard let self else { return }
                self.processTranscription(text)
            }
            overlayState.bind(to: transcriber)
            overlayWindow.show(state: overlayState, notchMode: notchModeEnabled)
            transcriber.startRecording()
        } else {
            speechTranscriber.customWords = words
            speechTranscriber.selectedDeviceID = micID
            speechTranscriber.onTranscriptionFinished = { [weak self] (text: String) in
                guard let self else { return }
                self.processTranscription(text)
            }
            overlayState.bind(to: speechTranscriber)
            overlayWindow.show(state: overlayState, notchMode: notchModeEnabled)
            speechTranscriber.startRecording()
        }
    }

    /// Whether the given engine's model is downloaded and available for use.
    private func isEngineReady(_ engine: TranscriptionEngine) -> Bool {
        switch engine {
        case .dictation:
            return true
        case .whisper:
            switch whisperModelManager.state {
            case .downloaded, .ready, .loading:
                return true
            default:
                return false
            }
        case .parakeet:
            switch parakeetModelManager.state {
            case .downloaded, .ready, .loading:
                return true
            default:
                return false
            }
        case .qwen:
            switch qwenModelManager.state {
            case .downloaded, .ready, .loading:
                return true
            default:
                return false
            }
        }
    }

    private func endRecording() {
        guard isSessionActive else { return }

        let engine = transcriptionEngine

        if engine == .whisper, isEngineReady(.whisper) {
            whisperTranscriber?.stopRecording()
            // For Whisper, transcription happens after stop — the overlay stays visible
            // until onTranscriptionFinished fires via processTranscription
            overlayState.isEnhancing = true // Show processing state while Whisper works
        } else if (engine == .parakeet || engine == .qwen), isEngineReady(engine) {
            fluidAudioTranscriber?.stopRecording()
            // FluidAudio models also transcribe after stop
            overlayState.isEnhancing = true
        } else {
            speechTranscriber.stopRecording()
            let waitingForAI = enhancementMode == .appleIntelligence && enhancer != nil
            if !waitingForAI {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.overlayWindow.hide(state: self?.overlayState)
                    self?.isSessionActive = false
                }
            }
        }
    }

    private func processTranscription(_ rawText: String) {
        // Clear the "processing" state from Whisper
        overlayState.isEnhancing = false

        guard !rawText.isEmpty else {
            overlayWindow.hide(state: overlayState)
            isSessionActive = false
            return
        }

        let engine = transcriptionEngine

        if enhancementMode == .appleIntelligence, let enhancer {
            overlayState.isEnhancing = true
            setEnhancingState(true)
            Task {
                defer {
                    self.overlayState.isEnhancing = false
                    self.setEnhancingState(false)
                    self.overlayWindow.hide(state: self.overlayState)
                    self.isSessionActive = false
                }
                do {
                    if #available(macOS 26.0, *) {
                        var prompt = UserDefaults.standard.string(forKey: AppPreferenceKey.enhancementSystemPrompt)
                            ?? AppPreferenceKey.defaultEnhancementPrompt
                        // Inject custom vocabulary so the enhancer preserves these terms
                        let words = self.customWordsManager.words
                        if !words.isEmpty {
                            prompt += "\n\nIMPORTANT: The following are custom words, names, or abbreviations the user has defined. Always preserve their exact spelling and casing: \(words.joined(separator: ", "))."
                        }
                        let enhanced = try await enhancer.enhance(rawText, systemPrompt: prompt)
                        self.typeText(enhanced)
                        self.historyManager.addRecord(
                            TranscriptionRecord(text: enhanced, engine: engine, wasEnhanced: true)
                        )
                    } else {
                        self.typeText(rawText)
                        self.historyManager.addRecord(
                            TranscriptionRecord(text: rawText, engine: engine, wasEnhanced: false)
                        )
                    }
                } catch {
                    print("AI enhancement failed, using raw text: \(error)")
                    self.typeText(rawText)
                    self.historyManager.addRecord(
                        TranscriptionRecord(text: rawText, engine: engine, wasEnhanced: false)
                    )
                }
            }
        } else {
            typeText(rawText)
            historyManager.addRecord(
                TranscriptionRecord(text: rawText, engine: engine, wasEnhanced: false)
            )
            overlayWindow.hide(state: overlayState)
            isSessionActive = false
        }
    }

    private func setEnhancingState(_ enhancing: Bool) {
        switch transcriptionEngine {
        case .whisper:
            whisperTranscriber?.isEnhancing = enhancing
        case .parakeet, .qwen:
            fluidAudioTranscriber?.isEnhancing = enhancing
        case .dictation:
            speechTranscriber.isEnhancing = enhancing
        }
    }

    private func typeText(_ text: String) {
        guard !text.isEmpty else { return }
        var output = text
        if UserDefaults.standard.bool(forKey: AppPreferenceKey.appendTrailingSpace) {
            output += " "
        }
        let source = CGEventSource(stateID: .hidSystemState)
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string) ?? ""
        pasteboard.clearContents()
        pasteboard.setString(output, forType: .string)

        let vKeyCode: CGKeyCode = 0x09
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        cmdDown?.flags = .maskCommand
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        cmdUp?.flags = .maskCommand

        cmdDown?.post(tap: .cgAnnotatedSessionEventTap)
        cmdUp?.post(tap: .cgAnnotatedSessionEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            pasteboard.clearContents()
            if !previous.isEmpty {
                pasteboard.setString(previous, forType: .string)
            }
        }
    }

    @objc private func quit() {
        hotkeyManager.stop()
        NSApp.terminate(nil)
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Permissions Required"
        alert.informativeText = "Kaze needs Microphone and Speech Recognition access. Please grant them in System Settings → Privacy & Security."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!)
        }
        NSApp.terminate(nil)
    }

    private func showAccessibilityPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = "Kaze needs Accessibility access to detect your global hotkey. Please enable Kaze in System Settings → Privacy & Security → Accessibility, then relaunch the app."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
        NSApp.terminate(nil)
    }
}
