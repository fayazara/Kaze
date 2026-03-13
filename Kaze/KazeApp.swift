import SwiftUI
import AppKit
import Combine

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
    static let launchAtLogin = "launchAtLogin"

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
                customWordsManager: appDelegate.customWordsManager,
                updaterManager: appDelegate.updaterManager,
                restartOnboarding: appDelegate.restartOnboarding
            )
            .frame(width: 520, height: 600)
        }
    }
}

// MARK: - AppDelegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let speechTranscriber = SpeechTranscriber()
    private var whisperTranscriber: WhisperTranscriber?
    private var fluidAudioTranscriber: FluidAudioTranscriber?
    let whisperModelManager = WhisperModelManager()
    let parakeetModelManager = FluidAudioModelManager(model: .parakeet)
    let qwenModelManager = FluidAudioModelManager(model: .qwen)
    let historyManager = TranscriptionHistoryManager()
    let customWordsManager = CustomWordsManager()

    let updaterManager = UpdaterManager()

    private let hotkeyManager = HotkeyManager()
    private let overlayWindow = RecordingOverlayWindow()
    private let overlayState = OverlayState()
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var appearanceObservation: NSKeyValueObservation?
    /// Tracks the last icon name applied to the status bar button to prevent
    /// a KVO feedback loop where setting the image triggers an appearance
    /// change notification which calls updateStatusBarIcon() again endlessly.
    private var lastAppliedIconName: String?

    private var enhancer: TextEnhancer?
    private var settingsWindowController: NSWindowController?
    private var onboardingWindowController: NSWindowController?

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

    /// Returns the AVCapture unique ID for the user-selected microphone, or nil for system default.
    private var selectedMicrophoneUID: String? {
        let stored = UserDefaults.standard.string(forKey: AppPreferenceKey.selectedMicrophoneID) ?? ""
        guard !stored.isEmpty, isKnownAudioInputDevice(stored) else { return nil }
        return stored
    }

    private var hotkeyModeObserver: NSObjectProtocol?
    private var isSessionActive = false
    private var idleModelUnloadTask: Task<Void, Never>?
    private var observedEngineForPreferenceChanges: TranscriptionEngine?
    private static let modelUnloadIdleDelay: Duration = .seconds(90)

    /// Captures all settings at the moment recording begins so that mid-session
    /// preference changes cannot route stop/finalize through the wrong engine.
    private struct RecordingSession {
        let engine: TranscriptionEngine
        let enhancementMode: EnhancementMode
        let transcriber: any TranscriberProtocol
    }

    /// The active recording session, non-nil while `isSessionActive` is true.
    private var activeSession: RecordingSession?

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

        // Menu bar icon — use a dark/light appearance-aware icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusBarIcon()
        if let button = statusItem?.button {
            appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?.updateStatusBarIcon()
                }
            }
        }
        buildMenu()
        observedEngineForPreferenceChanges = transcriptionEngine
        observeModelState()
        updateStatusItemIndicator()

        // Start Sparkle updater (safe to call before permissions; it only
        // fetches the appcast over the network and never touches the mic).
        updaterManager.start()

        if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            showOnboarding()
        } else {
            // Already completed onboarding — set up hotkey (permissions should already be granted)
            Task {
                await requestPermissionsAndSetupHotkey()
            }
        }
    }

    private func migrateLegacyPreferences() {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: AppPreferenceKey.enhancementMode) == nil,
           defaults.object(forKey: "aiEnhanceEnabled") != nil {
            let oldEnabled = defaults.bool(forKey: "aiEnhanceEnabled")
            enhancementMode = oldEnabled ? .appleIntelligence : .off
        }

        let storedMicrophone = defaults.string(forKey: AppPreferenceKey.selectedMicrophoneID) ?? ""
        if !storedMicrophone.isEmpty, !isKnownAudioInputDevice(storedMicrophone) {
            defaults.set("", forKey: AppPreferenceKey.selectedMicrophoneID)
        }
    }

    private func updateStatusBarIcon() {
        guard let button = statusItem?.button else { return }
        let isDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let iconName = isDark ? "kaze-icon" : "kaze-icon-black"

        // Guard against redundant updates to break the KVO feedback loop:
        // setting button.image triggers an AppKit redraw which fires the
        // effectiveAppearance KVO observer, which calls this method again.
        // Without this guard the loop runs as fast as the CPU can go (~91% CPU).
        guard iconName != lastAppliedIconName else { return }
        lastAppliedIconName = iconName

        if let icon = NSImage(named: iconName) {
            icon.size = NSSize(width: 18, height: 18)
            button.image = icon
        } else {
            button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Kaze")
        }
        button.image?.accessibilityDescription = "Kaze"
    }

    private func buildMenu() {
        let menu = NSMenu()

        let aboutItem = NSMenuItem(title: "About Kaze", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Kaze", action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    private var aboutWindowController: NSWindowController?

    @objc private func showAbout() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let window = aboutWindowController?.window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let aboutView = AboutView()
        let hostingController = NSHostingController(rootView: aboutView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 310),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "About Kaze"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.delegate = self

        let controller = NSWindowController(window: window)
        aboutWindowController = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func observeModelState() {
        whisperModelManager.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItemIndicator() }
            .store(in: &cancellables)

        parakeetModelManager.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItemIndicator() }
            .store(in: &cancellables)

        qwenModelManager.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItemIndicator() }
            .store(in: &cancellables)
    }

    private func updateStatusItemIndicator() {
        guard let statusItem, let button = statusItem.button else { return }
        let runtimesLoaded = whisperModelManager.isLoaded || parakeetModelManager.isLoaded || qwenModelManager.isLoaded
        let shouldMuteIcon = !isSessionActive && !runtimesLoaded

        statusItem.length = NSStatusItem.squareLength
        button.attributedTitle = NSAttributedString(string: "")
        button.alphaValue = shouldMuteIcon ? 0.45 : 1.0
        button.contentTintColor = shouldMuteIcon ? NSColor.tertiaryLabelColor : nil
    }

    private func showOnboarding() {
        let onboardingView = OnboardingView(
            whisperModelManager: whisperModelManager,
            parakeetModelManager: parakeetModelManager,
            qwenModelManager: qwenModelManager
        ) { [weak self] in
            self?.onboardingWindowController?.window?.close()
            self?.onboardingWindowController = nil
            // Set up hotkey and permissions now that onboarding is complete
            Task { [weak self] in
                await self?.requestPermissionsAndSetupHotkey()
            }
        }
        let hostingController = NSHostingController(rootView: onboardingView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Kaze"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 480, height: 540))

        window.delegate = self

        let controller = NSWindowController(window: window)
        onboardingWindowController = controller
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        centerWindow(window)

        // SwiftUI/AppKit can still adjust the final frame right after showing.
        DispatchQueue.main.async { [weak self, weak window] in
            guard self != nil, let window else { return }
            self?.centerWindow(window)
        }
    }

    private func centerWindow(_ window: NSWindow) {
        if let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first {
            let visibleFrame = screen.visibleFrame
            let centeredFrame = NSRect(
                x: visibleFrame.midX - window.frame.width / 2,
                y: visibleFrame.midY - window.frame.height / 2,
                width: window.frame.width,
                height: window.frame.height
            )
            window.setFrame(centeredFrame, display: true)
        } else {
            window.center()
        }
    }

    /// Requests microphone permissions (if needed) and sets up the global hotkey.
    /// Called after onboarding completes or on subsequent launches.
    func requestPermissionsAndSetupHotkey() async {
        // Request microphone permission silently — if already granted this returns immediately
        _ = await speechTranscriber.requestPermissions()
        setupHotkey()
    }

    func restartOnboarding() {
        UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
        onboardingWindowController?.window?.close()
        onboardingWindowController = nil
        showOnboarding()
    }

    @objc private func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        updaterManager.checkForUpdates()
    }

    @objc private func openSettings() {
        // Temporarily become a regular app so the window can receive focus
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let window = settingsWindowController?.window {
            settingsWindowController?.showWindow(nil)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let contentView = ContentView(
            whisperModelManager: whisperModelManager,
            parakeetModelManager: parakeetModelManager,
            qwenModelManager: qwenModelManager,
            historyManager: historyManager,
            customWordsManager: customWordsManager,
            updaterManager: updaterManager,
            restartOnboarding: restartOnboarding
        )
        .frame(width: 520, height: 600)
        let hostingController = NSHostingController(rootView: contentView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 500, height: 800)
        window.maxSize = NSSize(width: 500, height: 800)
        window.center()
        window.title = "Kaze Settings"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.delegate = self

        let controller = NSWindowController(window: window)
        settingsWindowController = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }

        if settingsWindowController?.window === window {
            settingsWindowController = nil
        }
        if onboardingWindowController?.window === window {
            onboardingWindowController = nil
        }
        if aboutWindowController?.window === window {
            aboutWindowController = nil
        }

        // If no managed windows remain visible, revert to accessory (no dock icon)
        let hasVisibleWindow = [settingsWindowController, onboardingWindowController, aboutWindowController]
            .compactMap { $0?.window }
            .contains { $0.isVisible }
        if !hasVisibleWindow {
            NSApp.setActivationPolicy(.accessory)
        }
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
            print("[Kaze] Accessibility permission not granted yet — hotkey will not work until granted.")
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

                self.handleEnginePreferenceChange()
            }
        }

    }

    private func beginRecording() {
        guard !isSessionActive else { return }
        idleModelUnloadTask?.cancel()
        idleModelUnloadTask = nil

        // Capture engine and enhancement mode at session start so that mid-session
        // preference changes cannot route stop/finalize through the wrong engine.
        let engine = transcriptionEngine
        let enhancement = enhancementMode

        // Check if the selected engine's model is available
        if engine.requiresModelDownload && !isEngineReady(engine) {
            print("\(engine.title) model not ready, falling back to Direct Dictation")
        }

        isSessionActive = true
        updateStatusItemIndicator()

        // Pass current custom words and selected microphone to the transcriber
        let words = customWordsManager.words
        let micUID = selectedMicrophoneUID

        // Use the appropriate transcriber
        if engine == .whisper, isEngineReady(.whisper) {
            let whisper = whisperTranscriber ?? WhisperTranscriber(modelManager: whisperModelManager)
            whisperTranscriber = whisper
            whisper.customWords = words
            whisper.selectedDeviceUID = micUID
            whisper.onTranscriptionFinished = { [weak self] (text: String) in
                guard let self else { return }
                self.processTranscription(text)
            }
            activeSession = RecordingSession(engine: engine, enhancementMode: enhancement, transcriber: whisper)
            overlayState.bind(to: whisper)
            overlayWindow.show(state: overlayState, notchMode: notchModeEnabled)
            whisper.startRecording()
        } else if (engine == .parakeet || engine == .qwen), isEngineReady(engine) {
            let manager = engine == .parakeet ? parakeetModelManager : qwenModelManager
            let model: FluidAudioModel = engine == .parakeet ? .parakeet : .qwen
            let transcriber = getOrCreateFluidAudioTranscriber(model: model, manager: manager)
            transcriber.selectedDeviceUID = micUID
            transcriber.onTranscriptionFinished = { [weak self] (text: String) in
                guard let self else { return }
                self.processTranscription(text)
            }
            activeSession = RecordingSession(engine: engine, enhancementMode: enhancement, transcriber: transcriber)
            overlayState.bind(to: transcriber)
            overlayWindow.show(state: overlayState, notchMode: notchModeEnabled)
            transcriber.startRecording()
        } else {
            speechTranscriber.customWords = words
            speechTranscriber.selectedDeviceUID = micUID
            speechTranscriber.onTranscriptionFinished = { [weak self] (text: String) in
                guard let self else { return }
                self.processTranscription(text)
            }
            activeSession = RecordingSession(engine: engine, enhancementMode: enhancement, transcriber: speechTranscriber)
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
        guard isSessionActive, let session = activeSession else { return }

        let engine = session.engine

        if engine == .whisper {
            (session.transcriber as? WhisperTranscriber)?.stopRecording()
            // For Whisper, transcription happens after stop — the overlay stays visible
            // until onTranscriptionFinished fires via processTranscription
            overlayState.isEnhancing = true // Show processing state while Whisper works
        } else if engine == .parakeet || engine == .qwen {
            (session.transcriber as? FluidAudioTranscriber)?.stopRecording()
            // FluidAudio models also transcribe after stop
            overlayState.isEnhancing = true
        } else {
            (session.transcriber as? SpeechTranscriber)?.stopRecording()
            let waitingForAI = session.enhancementMode == .appleIntelligence && enhancer != nil
            if !waitingForAI {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.overlayWindow.hide(state: self?.overlayState)
                    self?.isSessionActive = false
                    self?.activeSession = nil
                    self?.updateStatusItemIndicator()
                    self?.scheduleIdleModelUnload()
                }
            }
        }
    }

    private func processTranscription(_ rawText: String) {
        // Use the session that was active when recording started, not current prefs.
        let session = activeSession

        // Clear the "processing" state from Whisper
        overlayState.isEnhancing = false

        guard !rawText.isEmpty else {
            overlayWindow.hide(state: overlayState)
            isSessionActive = false
            activeSession = nil
            updateStatusItemIndicator()
            scheduleIdleModelUnload()
            return
        }

        let engine = session?.engine ?? transcriptionEngine
        let enhancement = session?.enhancementMode ?? enhancementMode

        // Only apply AI enhancement for Direct Dictation — AI models already produce enhanced output.
        if enhancement == .appleIntelligence, engine == .dictation, let enhancer {
            overlayState.isEnhancing = true
            setEnhancingState(true, session: session)
            Task {
                defer {
                    self.overlayState.isEnhancing = false
                    self.setEnhancingState(false, session: session)
                    self.overlayWindow.hide(state: self.overlayState)
                    self.isSessionActive = false
                    self.activeSession = nil
                    self.updateStatusItemIndicator()
                    self.scheduleIdleModelUnload()
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
            activeSession = nil
            updateStatusItemIndicator()
            scheduleIdleModelUnload()
        }
    }

    private func handleEnginePreferenceChange() {
        let currentEngine = transcriptionEngine
        if observedEngineForPreferenceChanges == nil {
            observedEngineForPreferenceChanges = currentEngine
        }
        guard observedEngineForPreferenceChanges != currentEngine else { return }
        observedEngineForPreferenceChanges = currentEngine
        guard !isSessionActive else { return }
        scheduleIdleModelUnload()
    }

    private func scheduleIdleModelUnload() {
        idleModelUnloadTask?.cancel()
        idleModelUnloadTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.modelUnloadIdleDelay)
            } catch {
                return // Task was cancelled, don't unload
            }
            await MainActor.run {
                guard let self else { return }
                guard !self.isSessionActive else { return }
                self.unloadModelRuntimesFromMemory()
            }
        }
    }

    private func unloadModelRuntimesFromMemory() {
        whisperModelManager.unloadModelFromMemory()
        parakeetModelManager.unloadModelFromMemory()
        qwenModelManager.unloadModelFromMemory()
        whisperTranscriber = nil
        fluidAudioTranscriber = nil
        updateStatusItemIndicator()
    }

    private func setEnhancingState(_ enhancing: Bool, session: RecordingSession? = nil) {
        if let session {
            session.transcriber.isEnhancing = enhancing
        } else {
            // Fallback to current preference (should not happen with proper session usage)
            switch transcriptionEngine {
            case .whisper:
                whisperTranscriber?.isEnhancing = enhancing
            case .parakeet, .qwen:
                fluidAudioTranscriber?.isEnhancing = enhancing
            case .dictation:
                speechTranscriber.isEnhancing = enhancing
            }
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
        pasteboard.clearContents()
        pasteboard.setString(output, forType: .string)

        let vKeyCode: CGKeyCode = 0x09
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        cmdDown?.flags = .maskCommand
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        cmdUp?.flags = .maskCommand

        cmdDown?.post(tap: .cgAnnotatedSessionEventTap)
        cmdUp?.post(tap: .cgAnnotatedSessionEventTap)
    }

    @objc private func quit() {
        hotkeyManager.stop()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        idleModelUnloadTask?.cancel()
        hotkeyManager.stop()
        cancellables.removeAll()
        if let hotkeyModeObserver {
            NotificationCenter.default.removeObserver(hotkeyModeObserver)
            self.hotkeyModeObserver = nil
        }
    }

    /// Retries setting up the hotkey after the user grants Accessibility permission.
    /// Called from the onboarding flow when accessibility is detected as granted.
    func retryHotkeySetup() {
        hotkeyManager.stop()
        _ = hotkeyManager.start()
    }
}
