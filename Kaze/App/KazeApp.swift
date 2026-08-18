import SwiftUI
import AppKit
import Combine
import FluidAudio

@main
struct KazeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            ContentView(
                appleSpeechModelManager: appDelegate.appleSpeechModelManager,
                whisperModelManager: appDelegate.whisperModelManager,
                parakeetModelManager: appDelegate.parakeetModelManager,
                historyManager: appDelegate.historyManager,
                customWordsManager: appDelegate.customWordsManager,
                updaterManager: appDelegate.updaterManager,
                restartOnboarding: appDelegate.restartOnboarding
            )
            .frame(width: 760, height: 640)
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - AppDelegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let appleSpeechModelManager = AppleSpeechModelManager()
    private lazy var speechTranscriber = SpeechTranscriber(modelManager: appleSpeechModelManager)
    private var whisperTranscriber: WhisperTranscriber?
    private var fluidAudioTranscriber: FluidAudioTranscriber?
    let whisperModelManager = WhisperModelManager()
    let parakeetModelManager = FluidAudioModelManager(model: .parakeet)
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
    private var formatter: TextFormatter?
    private let cloudEnhancer = CloudEnhancer()
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
    private var modelWarmupTask: Task<Void, Never>?
    private var modelWarmupGeneration: UUID?
    private var observedEngineForPreferenceChanges: TranscriptionEngine?
    private var lastWhisperModelState: WhisperModelManager.ModelState = .notDownloaded
    private var lastParakeetModelState: FluidAudioModelManager.ModelState = .notDownloaded
    private static let modelUnloadIdleDelay: Duration = .seconds(90)

    /// Captures all settings at the moment recording begins so that mid-session
    /// preference changes cannot route stop/finalize through the wrong engine.
    private struct RecordingSession {
        let engine: TranscriptionEngine
        let enhancementMode: EnhancementMode
        let transcriber: any TranscriberProtocol
        let source: TranscriptionSource?
        let startedAt: Date
        var endedAt: Date?

        var speechDuration: TimeInterval {
            max((endedAt ?? Date()).timeIntervalSince(startedAt), 0)
        }
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

        // Set up Apple Intelligence enhancer and formatter if available
        if #available(macOS 26.0, *), TextEnhancer.isAvailable {
            enhancer = TextEnhancer()
            formatter = TextFormatter()
        }

        // Menu bar icon uses a dark/light appearance-aware image.
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
        warmupSelectedEngineRuntimeIfNeeded()

        // Start Sparkle updater (safe to call before permissions; it only
        // fetches the appcast over the network and never touches the mic).
        updaterManager.start()

        if !UserDefaults.standard.bool(forKey: AppPreferenceKey.hasCompletedOnboarding) {
            showOnboarding()
        } else {
            // Already completed onboarding, so set up the hotkey (permissions should already be granted).
            Task {
                await requestPermissionsAndSetupHotkey()
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await appleSpeechModelManager.refreshStatus() }
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

        if defaults.string(forKey: AppPreferenceKey.transcriptionEngine) == "qwen" {
            defaults.set(TranscriptionEngine.parakeet.rawValue, forKey: AppPreferenceKey.transcriptionEngine)
        }

        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let legacyQwenDirectory = appSupport
                .appendingPathComponent("FluidAudio/Models/qwen3-asr-0.6b-coreml/f32", isDirectory: true)
            if FileManager.default.fileExists(atPath: legacyQwenDirectory.path) {
                try? FileManager.default.removeItem(at: legacyQwenDirectory)
            }
        }
    }

    private func updateStatusBarIcon() {
        guard let button = statusItem?.button else { return }
        let iconName = "kaze-icon"

        // Guard against redundant updates to break the KVO feedback loop:
        // setting button.image triggers an AppKit redraw which fires the
        // effectiveAppearance KVO observer, which calls this method again.
        // Without this guard the loop runs as fast as the CPU can go (~91% CPU).
        guard iconName != lastAppliedIconName else { return }
        lastAppliedIconName = iconName

        if let icon = NSImage(named: iconName)?.copy() as? NSImage {
            icon.size = NSSize(width: 18, height: 18)
            icon.isTemplate = true
            button.image = icon
        } else {
            let fallback = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Kaze")
            fallback?.isTemplate = true
            button.image = fallback
        }
        button.imagePosition = .imageOnly
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

    @objc private func showAbout() {
        openSettingsWindow(initialTab: .about)
    }

    private func observeModelState() {
        lastWhisperModelState = whisperModelManager.state
        lastParakeetModelState = parakeetModelManager.state

        appleSpeechModelManager.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItemIndicator()
            }
            .store(in: &cancellables)

        whisperModelManager.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] newState in
                guard let self else { return }
                let previousState = self.lastWhisperModelState
                self.lastWhisperModelState = newState
                self.updateStatusItemIndicator()
                self.updateOverlayProcessingStatusIfNeeded()
                if self.didCompleteWhisperDownload(from: previousState, to: newState) {
                    self.cancelModelWarmup()
                    self.warmupSelectedEngineRuntimeIfNeeded()
                }
            }
            .store(in: &cancellables)

        parakeetModelManager.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] newState in
                guard let self else { return }
                let previousState = self.lastParakeetModelState
                self.lastParakeetModelState = newState
                self.updateStatusItemIndicator()
                self.updateOverlayProcessingStatusIfNeeded()
                if self.didCompleteFluidAudioDownload(for: .parakeet, from: previousState, to: newState) {
                    self.cancelModelWarmup()
                    self.warmupSelectedEngineRuntimeIfNeeded()
                }
            }
            .store(in: &cancellables)

        whisperModelManager.$selectedVariant
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.cancelModelWarmup()
                self.scheduleIdleModelUnload()
                self.updateOverlayProcessingStatusIfNeeded()
                self.warmupSelectedEngineRuntimeIfNeeded()
            }
            .store(in: &cancellables)
    }

    private func updateStatusItemIndicator() {
        guard let statusItem, let button = statusItem.button else { return }
        let runtimesLoaded = whisperModelManager.isLoaded || parakeetModelManager.isLoaded
        let shouldMuteIcon = !isSessionActive && !runtimesLoaded

        statusItem.length = NSStatusItem.squareLength
        button.attributedTitle = NSAttributedString(string: "")
        button.alphaValue = shouldMuteIcon ? 0.45 : 1.0
        button.contentTintColor = nil
    }

    private func showOnboarding() {
        let onboardingView = OnboardingView(
            appleSpeechModelManager: appleSpeechModelManager,
            whisperModelManager: whisperModelManager,
            parakeetModelManager: parakeetModelManager
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
        // Request microphone permission silently. If already granted, this returns immediately.
        _ = await speechTranscriber.requestPermissions()
        setupHotkey()
    }

    func restartOnboarding() {
        UserDefaults.standard.set(false, forKey: AppPreferenceKey.hasCompletedOnboarding)
        onboardingWindowController?.window?.close()
        onboardingWindowController = nil
        showOnboarding()
    }

    @objc private func checkForUpdates() {
        presentManagedWindow {
            self.updaterManager.checkForUpdates()
        }
    }

    @objc private func openSettings() {
        openSettingsWindow(initialTab: .general)
    }

    private func openSettingsWindow(initialTab: SettingsTab) {
        presentManagedWindow {
            if let window = self.settingsWindowController?.window {
                if let hostingController = window.contentViewController as? NSHostingController<AnyView> {
                    hostingController.rootView = self.makeSettingsContent(initialTab: initialTab)
                }
                self.settingsWindowController?.showWindow(nil)
                self.bringWindowToFront(window)
                return
            }

            let contentView = self.makeSettingsContent(initialTab: initialTab)
            let hostingController = NSHostingController(rootView: contentView)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.minSize = NSSize(width: 760, height: 640)
            window.maxSize = NSSize(width: 760, height: 640)
            window.center()
            window.title = "Settings"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            // Keep controls aligned beneath the transparent titlebar clickable.
            window.isMovableByWindowBackground = false
            window.contentViewController = hostingController
            window.isReleasedWhenClosed = false
            window.delegate = self

            let controller = NSWindowController(window: window)
            self.settingsWindowController = controller
            controller.showWindow(nil)
            self.bringWindowToFront(window)
        }
    }

    private func makeSettingsContent(initialTab: SettingsTab) -> AnyView {
        AnyView(ContentView(
            appleSpeechModelManager: appleSpeechModelManager,
            whisperModelManager: whisperModelManager,
            parakeetModelManager: parakeetModelManager,
            historyManager: historyManager,
            customWordsManager: customWordsManager,
            updaterManager: updaterManager,
            restartOnboarding: restartOnboarding,
            initialTab: initialTab
        )
        .frame(width: 760, height: 640))
    }

    private func presentManagedWindow(_ action: @escaping () -> Void) {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            action()
        }
    }

    private func bringWindowToFront(_ window: NSWindow) {
        window.orderFrontRegardless()
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

        // If no managed windows remain visible, revert to accessory (no dock icon)
        let hasVisibleWindow = [settingsWindowController, onboardingWindowController]
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
            print("[Kaze] Accessibility permission not granted yet; hotkey will not work until granted.")
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
        overlayState.processingStatusText = ""

        // Capture engine and enhancement mode at session start so that mid-session
        // preference changes cannot route stop/finalize through the wrong engine.
        let preferredEngine = transcriptionEngine
        let engine: TranscriptionEngine
        let enhancement = enhancementMode
        let source = currentSourceApplication()

        // Check if the selected engine's model is available
        if preferredEngine.requiresModelDownload && !preferredEngine.isModelReady(
            appleManager: appleSpeechModelManager,
            whisperManager: whisperModelManager,
            parakeetManager: parakeetModelManager
        ) {
            if preferredEngine != .dictation, TranscriptionEngine.dictation.isModelReady(
                appleManager: appleSpeechModelManager,
                whisperManager: whisperModelManager,
                parakeetManager: parakeetModelManager
            ) {
                print("\(preferredEngine.title) model not ready, falling back to Direct Dictation")
                engine = .dictation
            } else {
                print("\(preferredEngine.title) model is not ready")
                if preferredEngine == .dictation {
                    openSettingsWindow(initialTab: .general)
                }
                return
            }
        } else {
            engine = preferredEngine
        }

        isSessionActive = true
        updateStatusItemIndicator()

        // Pass current custom words and selected microphone to the transcriber
        let words = customWordsManager.words
        let micUID = selectedMicrophoneUID

        // Use the appropriate transcriber
        if engine == .whisper, engine.isModelReady(
            appleManager: appleSpeechModelManager,
            whisperManager: whisperModelManager,
            parakeetManager: parakeetModelManager
        ) {
            let whisper = whisperTranscriber ?? WhisperTranscriber(modelManager: whisperModelManager)
            whisperTranscriber = whisper
            whisper.customWords = words
            whisper.selectedDeviceUID = micUID
            whisper.onTranscriptionFinished = { [weak self] (text: String) in
                guard let self else { return }
                self.processTranscription(text)
            }
            activeSession = RecordingSession(
                engine: engine,
                enhancementMode: enhancement,
                transcriber: whisper,
                source: source,
                startedAt: Date()
            )
            overlayState.bind(to: whisper)
            overlayWindow.show(state: overlayState, notchMode: notchModeEnabled)
            whisper.startRecording()
        } else if engine == .parakeet, engine.isModelReady(
            appleManager: appleSpeechModelManager,
            whisperManager: whisperModelManager,
            parakeetManager: parakeetModelManager
        ) {
            let transcriber = getOrCreateFluidAudioTranscriber(model: .parakeet, manager: parakeetModelManager)
            transcriber.selectedDeviceUID = micUID
            transcriber.onTranscriptionFinished = { [weak self] (text: String) in
                guard let self else { return }
                self.processTranscription(text)
            }
            activeSession = RecordingSession(
                engine: engine,
                enhancementMode: enhancement,
                transcriber: transcriber,
                source: source,
                startedAt: Date()
            )
            overlayState.bind(to: transcriber)
            overlayWindow.show(state: overlayState, notchMode: notchModeEnabled)
            transcriber.startRecording()
        } else {
            speechTranscriber.selectedDeviceUID = micUID
            speechTranscriber.onTranscriptionFinished = { [weak self] (text: String) in
                guard let self else { return }
                self.processTranscription(text)
            }
            activeSession = RecordingSession(
                engine: engine,
                enhancementMode: enhancement,
                transcriber: speechTranscriber,
                source: source,
                startedAt: Date()
            )
            overlayState.bind(to: speechTranscriber)
            overlayWindow.show(state: overlayState, notchMode: notchModeEnabled)
            speechTranscriber.startRecording()
        }
    }

    private func endRecording() {
        guard isSessionActive, let session = activeSession else { return }
        activeSession?.endedAt = Date()

        let engine = session.engine

        if engine == .whisper {
            (session.transcriber as? WhisperTranscriber)?.stopRecording()
            // For Whisper, transcription happens after stop, so the overlay stays visible
            // until onTranscriptionFinished fires via processTranscription
            overlayState.isEnhancing = true // Show processing state while Whisper works
            overlayState.processingStatusText = processingStatusText(for: .whisper)
        } else if engine == .parakeet {
            (session.transcriber as? FluidAudioTranscriber)?.stopRecording()
            // FluidAudio models also transcribe after stop
            overlayState.isEnhancing = true
            overlayState.processingStatusText = processingStatusText(for: engine)
        } else {
            (session.transcriber as? SpeechTranscriber)?.stopRecording()
            overlayState.isEnhancing = true
            overlayState.processingStatusText = "Finalizing..."
        }
    }

    private func processTranscription(_ rawText: String) {
        // Use the session that was active when recording started, not current prefs.
        let session = activeSession

        // Clear the "processing" state from Whisper
        overlayState.processingStatusText = ""
        overlayState.isEnhancing = false

        // Optionally strip filler words (uh, um, er, hmm, etc.) before any further processing.
        let cleanedText: String
        if UserDefaults.standard.bool(forKey: AppPreferenceKey.removeFillerWords) {
            cleanedText = FillerWordCleaner.clean(rawText)
        } else {
            cleanedText = rawText
        }

        guard !cleanedText.isEmpty else {
            overlayWindow.hide(state: overlayState)
            isSessionActive = false
            activeSession = nil
            updateStatusItemIndicator()
            scheduleIdleModelUnload()
            return
        }

        let engine = session?.engine ?? transcriptionEngine
        let enhancement = session?.enhancementMode ?? enhancementMode
        let speechDuration = session?.speechDuration ?? 0
        let source = session?.source

        // Determine what post-processing is needed
        let smartFormattingEnabled = UserDefaults.standard.bool(forKey: AppPreferenceKey.smartFormattingEnabled)
        let formattingBackendRaw = UserDefaults.standard.string(forKey: AppPreferenceKey.smartFormattingBackend) ?? FormattingBackend.appleIntelligence.rawValue
        let formattingBackend = FormattingBackend(rawValue: formattingBackendRaw) ?? .appleIntelligence

        // Enhancement: Apple Intelligence (Dictation only), Cloud AI (all engines)
        let needsLocalEnhancement = enhancement == .appleIntelligence && engine == .dictation && enhancer != nil
        let needsCloudEnhancement = enhancement == .cloudAI

        // Formatting: Apple Intelligence (local) or Cloud AI
        let needsLocalFormatting = smartFormattingEnabled && formattingBackend == .appleIntelligence && formatter != nil
        let needsCloudFormatting = smartFormattingEnabled && formattingBackend == .cloudAI

        let needsAsyncProcessing = needsLocalEnhancement || needsCloudEnhancement || needsLocalFormatting || needsCloudFormatting

        if needsAsyncProcessing {
            let statusText = (needsLocalEnhancement || needsCloudEnhancement) ? "Enhancing text..." : "Formatting..."
            overlayState.isEnhancing = true
            overlayState.processingStatusText = statusText
            setEnhancingState(true, session: session)
            Task {
                defer {
                    self.overlayState.processingStatusText = ""
                    self.overlayState.isEnhancing = false
                    self.setEnhancingState(false, session: session)
                    self.overlayWindow.hide(state: self.overlayState)
                    self.isSessionActive = false
                    self.activeSession = nil
                    self.updateStatusItemIndicator()
                    self.scheduleIdleModelUnload()
                }
                var processedText = cleanedText
                var wasEnhanced = false

                // Build the enhancement system prompt with custom vocabulary
                var enhancementPrompt = UserDefaults.standard.string(forKey: AppPreferenceKey.enhancementSystemPrompt)
                    ?? AppPreferenceKey.defaultEnhancementPrompt
                let words = self.customWordsManager.words
                if !words.isEmpty {
                    enhancementPrompt += "\n\nIMPORTANT: The following are custom words, names, or abbreviations the user has defined. Always preserve their exact spelling and casing: \(words.joined(separator: ", "))."
                }

                // Step 1: AI Enhancement
                if needsLocalEnhancement {
                    do {
                        if #available(macOS 26.0, *) {
                            processedText = try await enhancer!.enhance(processedText, systemPrompt: enhancementPrompt)
                            wasEnhanced = true
                        }
                    } catch {
                        print("Apple Intelligence enhancement failed: \(error)")
                    }
                } else if needsCloudEnhancement {
                    do {
                        let provider = CloudAIProvider(rawValue: UserDefaults.standard.string(forKey: AppPreferenceKey.cloudAIProvider) ?? "") ?? .openAI
                        let modelID = UserDefaults.standard.string(forKey: AppPreferenceKey.cloudAIModel) ?? provider.defaultModel.id
                        processedText = try await self.cloudEnhancer.enhance(
                            processedText,
                            systemPrompt: enhancementPrompt,
                            provider: provider,
                            modelID: modelID
                        )
                        wasEnhanced = true
                    } catch {
                        print("Cloud AI enhancement failed: \(error)")
                    }
                }

                // Step 2: Smart Formatting
                if needsLocalFormatting || needsCloudFormatting {
                    self.overlayState.processingStatusText = "Formatting..."

                    if needsLocalFormatting {
                        do {
                            if #available(macOS 26.0, *) {
                                processedText = try await self.formatter!.format(processedText)
                            }
                        } catch {
                            print("Apple Intelligence formatting failed: \(error)")
                        }
                    } else if needsCloudFormatting {
                        do {
                            let provider = CloudAIProvider(rawValue: UserDefaults.standard.string(forKey: AppPreferenceKey.cloudAIProvider) ?? "") ?? .openAI
                            let modelID = UserDefaults.standard.string(forKey: AppPreferenceKey.cloudAIModel) ?? provider.defaultModel.id
                            processedText = try await self.cloudEnhancer.format(
                                processedText,
                                provider: provider,
                                modelID: modelID
                            )
                        } catch {
                            print("Cloud AI formatting failed: \(error)")
                        }
                    }
                }

                self.typeText(processedText)
                self.historyManager.addRecord(
                    TranscriptionRecord(
                        text: processedText,
                        engine: engine,
                        wasEnhanced: wasEnhanced,
                        speechDuration: speechDuration,
                        source: source
                    )
                )
            }
        } else {
            typeText(cleanedText)
            historyManager.addRecord(
                TranscriptionRecord(
                    text: cleanedText,
                    engine: engine,
                    wasEnhanced: false,
                    speechDuration: speechDuration,
                    source: source
                )
            )
            overlayWindow.hide(state: overlayState)
            isSessionActive = false
            activeSession = nil
            updateStatusItemIndicator()
            scheduleIdleModelUnload()
        }
    }

    private func processingStatusText(for engine: TranscriptionEngine) -> String {
        switch engine {
        case .dictation:
            return "Enhancing text..."
        case .whisper:
            return processingStatusText(for: whisperModelManager.state)
        case .parakeet:
            return processingStatusText(for: parakeetModelManager.state)
        }
    }

    private func processingStatusText(for state: WhisperModelManager.ModelState) -> String {
        switch state {
        case .loading:
            return "Warming up model..."
        default:
            return "Transcribing..."
        }
    }

    private func processingStatusText(for state: FluidAudioModelManager.ModelState) -> String {
        switch state {
        case .loading:
            return "Warming up model..."
        default:
            return "Transcribing..."
        }
    }

    private func updateOverlayProcessingStatusIfNeeded() {
        guard overlayState.isEnhancing, let engine = activeSession?.engine else { return }
        overlayState.processingStatusText = processingStatusText(for: engine)
    }

    private func handleEnginePreferenceChange() {
        let currentEngine = transcriptionEngine
        if observedEngineForPreferenceChanges == nil {
            observedEngineForPreferenceChanges = currentEngine
        }
        guard observedEngineForPreferenceChanges != currentEngine else { return }
        observedEngineForPreferenceChanges = currentEngine
        cancelModelWarmup()
        guard !isSessionActive else { return }
        scheduleIdleModelUnload()
        warmupSelectedEngineRuntimeIfNeeded()
    }

    private func warmupSelectedEngineRuntimeIfNeeded() {
        guard !isSessionActive else { return }
        guard modelWarmupTask == nil else { return }

        let generation = UUID()
        modelWarmupGeneration = generation

        switch transcriptionEngine {
        case .dictation:
            modelWarmupGeneration = nil
            return

        case .whisper:
            guard case .downloaded = whisperModelManager.state else {
                modelWarmupGeneration = nil
                return
            }
            modelWarmupTask = Task(priority: .utility) { [weak self] in
                guard let self else { return }
                defer { self.finishModelWarmup(generation: generation) }
                do {
                    _ = try await self.whisperModelManager.loadModel()
                    if !self.isSessionActive {
                        self.scheduleIdleModelUnload()
                    }
                } catch is CancellationError {
                } catch {
                    guard !Task.isCancelled else { return }
                    print("Whisper warm-up failed: \(error)")
                }
            }

        case .parakeet:
            guard case .downloaded = parakeetModelManager.state else {
                modelWarmupGeneration = nil
                return
            }
            modelWarmupTask = Task(priority: .utility) { [weak self] in
                guard let self else { return }
                defer { self.finishModelWarmup(generation: generation) }
                do {
                    try await self.parakeetModelManager.loadModel()
                    if !self.isSessionActive {
                        self.scheduleIdleModelUnload()
                    }
                } catch is CancellationError {
                } catch {
                    guard !Task.isCancelled else { return }
                    print("Parakeet warm-up failed: \(error)")
                }
            }
        }
    }

    private func cancelModelWarmup() {
        modelWarmupTask?.cancel()
        modelWarmupTask = nil
        modelWarmupGeneration = nil
    }

    private func finishModelWarmup(generation: UUID) {
        guard modelWarmupGeneration == generation else { return }
        modelWarmupTask = nil
        modelWarmupGeneration = nil
    }

    private func didCompleteWhisperDownload(
        from previous: WhisperModelManager.ModelState,
        to current: WhisperModelManager.ModelState
    ) -> Bool {
        guard transcriptionEngine == .whisper else { return false }
        guard case .downloaded = current else { return false }
        switch previous {
        case .notDownloaded, .downloading, .error:
            return true
        case .downloaded, .loading, .ready:
            return false
        }
    }

    private func didCompleteFluidAudioDownload(
        for engine: TranscriptionEngine,
        from previous: FluidAudioModelManager.ModelState,
        to current: FluidAudioModelManager.ModelState
    ) -> Bool {
        guard transcriptionEngine == engine else { return false }
        guard case .downloaded = current else { return false }
        switch previous {
        case .notDownloaded, .downloading, .error:
            return true
        case .downloaded, .loading, .ready:
            return false
        }
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
            case .parakeet:
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

    private func currentSourceApplication() -> TranscriptionSource? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        let name = application.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = (name?.isEmpty == false ? name : nil) ?? "Unknown App"
        return TranscriptionSource(
            bundleIdentifier: application.bundleIdentifier,
            name: resolvedName
        )
    }

    @objc private func quit() {
        cancelModelWarmup()
        hotkeyManager.stop()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        idleModelUnloadTask?.cancel()
        cancelModelWarmup()
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
