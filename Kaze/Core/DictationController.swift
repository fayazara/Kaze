import AppKit
import Observation
import os

/// Where a dictation is in its life. Every UI surface renders from this.
enum DictationPhase: Equatable {
    case idle
    /// Recording. `handsFree` means the shortcut was tapped, so recording
    /// continues until the next tap rather than until release.
    case listening(handsFree: Bool)
    case transcribing
    case formatting
    case done(pasted: Bool)
    case failed(String)
    /// The recording had no speech in it. Shown wordlessly.
    case nothingHeard

    var isActive: Bool {
        switch self {
        case .listening, .transcribing, .formatting: true
        default: false
        }
    }

    var isListening: Bool {
        if case .listening = self { return true }
        return false
    }
}

/// The end-to-end dictation pipeline:
/// shortcut → microphone → speech engine → S1-mini → replacements → paste.
///
/// All state lives here and changes only on the main actor. Each session gets
/// a generation number so late callbacks from a cancelled session can never
/// touch a newer one.
@Observable
final class DictationController {
    private(set) var phase: DictationPhase = .idle
    /// Live text from streaming engines while listening.
    private(set) var liveText = ""
    /// Recent input levels (0...1), newest last, for the waveform.
    private(set) var levels: [Float] = Array(repeating: 0, count: DictationController.levelCount)
    private(set) var listeningSince: Date?
    /// When recording ended, so the island can show the final duration.
    private(set) var stoppedAt: Date?
    /// The app that will receive the text.
    private(set) var targetApp: NSRunningApplication?
    /// The speech model was still loading when recording ended.
    private(set) var isWaitingForModel = false

    static let levelCount = 28

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let models: ModelManager
    @ObservationIgnored private let vocabulary: VocabularyStore
    @ObservationIgnored private let history: HistoryStore
    @ObservationIgnored private let inserter = TextInserter()
    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored let hotkey = HotkeyMonitor()

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var session: (any TranscriptionSession)?
    @ObservationIgnored private var sessionModel: SpeechModel = .apple
    @ObservationIgnored private var pressedAt: Date?
    @ObservationIgnored private var resetTask: Task<Void, Never>?
    @ObservationIgnored private var maxDurationTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.fayazahmed.Kaze", category: "Dictation")

    /// A tap shorter than this switches Hold-or-Tap into hands-free mode.
    private static let tapThreshold: TimeInterval = 0.3
    /// Keystrokes this soon after a modifier-only shortcut mean the user was
    /// typing a chord (fn+←, ⌘C…), not dictating.
    private static let chordWindow: TimeInterval = 0.8
    /// Keep recording briefly after release so the last syllable isn't clipped.
    private static let tailPadding: Duration = .milliseconds(180)
    private static let maxDuration: Duration = .seconds(10 * 60)
    /// Recordings whose loudest moment stays below this are treated as silence.
    private static let speechLevelThreshold: Float = 0.18

    /// While `true`, the shortcut is ignored (e.g. while recording a new one).
    var isPaused = false

    init(preferences: Preferences, models: ModelManager, vocabulary: VocabularyStore, history: HistoryStore) {
        self.preferences = preferences
        self.models = models
        self.vocabulary = vocabulary
        self.history = history
        hotkey.shortcut = preferences.shortcut
        hotkey.onEvent = { [weak self] event in self?.handle(event) }
    }

    // MARK: - Shortcut

    @discardableResult
    func startMonitoring() -> Bool {
        hotkey.shortcut = preferences.shortcut
        return hotkey.start()
    }

    func shortcutDidChange() {
        hotkey.shortcut = preferences.shortcut
    }

    private func handle(_ event: HotkeyMonitor.Event) {
        guard !isPaused else { return }
        let now = Date()
        switch event {
        case .pressed:
            switch phase {
            case .idle, .done, .failed, .nothingHeard:
                pressedAt = now
                start(handsFree: preferences.activationMode == .toggle)
            case .listening(handsFree: true):
                stop()
            default:
                break
            }
        case .released:
            guard case .listening(handsFree: false) = phase else { return }
            let heldFor = now.timeIntervalSince(pressedAt ?? now)
            if preferences.activationMode == .automatic, heldFor < Self.tapThreshold {
                phase = .listening(handsFree: true)
            } else {
                stop()
            }
        case .interrupted:
            if phase.isListening, let since = listeningSince, now.timeIntervalSince(since) < Self.chordWindow {
                log.debug("Shortcut was part of a key chord; discarding")
                cancel(silently: true)
            }
        case .escape:
            if phase.isActive { cancel(silently: false) }
        }
    }

    /// For the menu bar item and onboarding's practice field.
    func toggleFromUI() {
        switch phase {
        case .listening: stop()
        case .idle, .done, .failed, .nothingHeard: start(handsFree: true)
        default: break
        }
    }

    // MARK: - Session lifecycle

    func start(handsFree: Bool) {
        resetTask?.cancel()
        generation += 1
        let generation = generation
        let model = preferences.speechModel

        guard AVPermissions.microphoneGranted else {
            if AVPermissions.microphoneUndetermined {
                Task { _ = await AVPermissions.requestMicrophone() }
                fail("Allow microphone access, then try again", quiet: true)
            } else {
                fail("Kaze needs microphone access", openSettings: true)
            }
            return
        }
        guard models.state(of: model).isInstalled else {
            fail("\(model.title) isn't downloaded yet")
            return
        }

        let session: any TranscriptionSession
        do {
            let options = RecognitionOptions(vocabulary: vocabulary.words, language: preferences.language)
            session = try models.engine(for: model).makeSession(options: options) { [weak self] text in
                Task { @MainActor in
                    guard let self, self.generation == generation, self.phase.isListening, self.preferences.showLivePreview else { return }
                    self.liveText = text
                }
            }
        } catch {
            fail(error.localizedDescription)
            return
        }

        self.session = session
        sessionModel = model
        targetApp = NSWorkspace.shared.frontmostApplication
        liveText = ""
        levels = Array(repeating: 0, count: Self.levelCount)
        listeningSince = Date()
        stoppedAt = nil
        phase = .listening(handsFree: handsFree)
        hotkey.capturesEscape = preferences.escapeToCancel
        Sounds.play(.start, enabled: preferences.playSounds)

        // Load the models while the user speaks (~0.1 s once macOS has
        // cached the Neural Engine build), and keep them until we're done.
        models.beginUse(model)
        if shouldFormat {
            let cleaner = models.cleaner(for: preferences.cleanUpEngine)
            Task { try? await cleaner.prepare() }
        }

        recorder.onSamples = { samples in session.append(samples) }
        recorder.onLevel = { [weak self] level in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.levels.removeFirst()
                self.levels.append(level)
            }
        }

        Task {
            do {
                try await recorder.start(deviceID: preferences.microphoneID)
            } catch {
                guard self.generation == generation else { return }
                session.cancel()
                fail(error.localizedDescription, openSettings: (error as? AudioRecorderError) == .permissionDenied)
            }
        }

        maxDurationTask?.cancel()
        maxDurationTask = Task {
            try? await Task.sleep(for: Self.maxDuration)
            guard !Task.isCancelled, self.generation == generation, self.phase.isListening else { return }
            stop()
        }
    }

    func stop() {
        guard phase.isListening, let session else { return }
        let generation = generation
        let model = sessionModel
        let stoppedAt = Date()
        maxDurationTask?.cancel()
        isWaitingForModel = models.warmingModel == model
        self.stoppedAt = stoppedAt
        phase = .transcribing

        Task {
            try? await Task.sleep(for: Self.tailPadding)
            let (audio, peak) = await recorder.stop()
            guard self.generation == generation else { return }
            Sounds.play(.stop, enabled: preferences.playSounds)

            let duration = Double(audio.count) / AudioRecorder.sampleRate
            guard duration > 0.3, peak >= Self.speechLevelThreshold else {
                session.cancel()
                nothingHeard()
                return
            }

            do {
                // A model still compiling after download can take minutes.
                let timeout = max(20, duration * 1.5) + (isWaitingForModel ? 300 : 0)
                let raw = try await withTimeout(seconds: timeout) {
                    try await session.finish(audio: audio)
                }
                guard self.generation == generation else { return }
                try await deliver(raw: TextPolisher.clean(raw), model: model, duration: duration, stoppedAt: stoppedAt, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                guard self.generation == generation else { return }
                log.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
                fail(error is TimeoutError ? "Transcription took too long" : error.localizedDescription)
            }
        }
    }

    func cancel(silently: Bool) {
        guard phase.isActive else { return }
        generation += 1
        session?.cancel()
        session = nil
        maxDurationTask?.cancel()
        hotkey.capturesEscape = false
        let recorder = recorder
        Task { _ = await recorder.stop() }
        liveText = ""
        listeningSince = nil
        phase = .idle
        models.endUse()
        if !silently { Sounds.play(.cancel, enabled: preferences.playSounds) }
    }

    private func deliver(raw: String, model: SpeechModel, duration: TimeInterval, stoppedAt: Date, generation: Int) async throws {
        guard !raw.isEmpty else {
            nothingHeard()
            return
        }

        var text = raw
        if shouldFormat {
            phase = .formatting
            let context: FormatContext = preferences.emailInMailApps && Self.isMailApp(targetApp) ? .email : .general
            let formatter = models.cleaner(for: preferences.cleanUpEngine)
            let style = preferences.formatStyle
            let allowLists = preferences.allowLists
            do {
                let formatted = try await withTimeout(seconds: 20) {
                    try await formatter.format(raw, style: style, allowLists: allowLists, context: context)
                }
                guard self.generation == generation else { return }
                let cleaned = TextPolisher.clean(formatted)
                if TextPolisher.isPlausibleRewrite(cleaned, of: raw) {
                    text = cleaned
                } else {
                    log.notice("Discarded implausible formatter output")
                }
            } catch {
                guard self.generation == generation else { return }
                log.error("Formatting failed, using raw transcript: \(error.localizedDescription, privacy: .public)")
            }
            // S1-mini holds ~1.4 GB and reloads in under a second while the
            // next dictation is being spoken, so don't keep it around.
            if preferences.cleanUpEngine == .s1Mini { models.formatter.unload() }
        }

        text = TextPolisher.applyReplacements(vocabulary.replacements, to: text)
        guard !text.isEmpty else {
            // The formatter returns nothing for filler-only speech ("um").
            nothingHeard()
            return
        }

        var output = text
        if preferences.addTrailingSpace, !output.hasSuffix("\n") { output += " " }
        let outcome = await inserter.insert(output, restoreClipboard: preferences.restoreClipboard)
        guard self.generation == generation else { return }

        if preferences.saveHistory {
            history.add(HistoryItem(
                date: Date(),
                text: text,
                rawText: raw == text ? nil : raw,
                model: model,
                appName: targetApp?.localizedName,
                appBundleID: targetApp?.bundleIdentifier,
                duration: duration,
                latency: Date().timeIntervalSince(stoppedAt)
            ))
        }
        log.info("Delivered \(text.count) chars in \(Date().timeIntervalSince(stoppedAt), format: .fixed(precision: 2))s after release")
        finish(.done(pasted: outcome == .pasted), after: outcome == .pasted ? 0.9 : 2.5)
    }

    private var shouldFormat: Bool {
        let engine = preferences.cleanUpEngine
        guard preferences.formattingEnabled, models.isCleanUpReady(engine) else { return false }
        let language = sessionModel.isEnglishOnly ? "en" : preferences.language
        switch engine {
        case .s1Mini:
            // S1-mini v1 is English-only.
            return (language ?? Locale.current.language.languageCode?.identifier ?? "en").hasPrefix("en")
        case .chatGPT:
            return true
        }
    }

    /// Silence, an accidental tap, or filler only: no error, just a shrug.
    private func nothingHeard() {
        log.notice("Session ended: nothing heard")
        finish(.nothingHeard, after: 1.1)
    }

    private func fail(_ message: String, quiet: Bool = false, openSettings: Bool = false) {
        log.notice("Session ended: \(message, privacy: .public)")
        if !quiet { Sounds.play(.error, enabled: preferences.playSounds) }
        finish(.failed(message), after: quiet ? 1.4 : 3)
        if openSettings { AVPermissions.openMicrophoneSettings() }
    }

    private func finish(_ final: DictationPhase, after seconds: Double) {
        session = nil
        models.endUse()
        isWaitingForModel = false
        hotkey.capturesEscape = false
        listeningSince = nil
        liveText = ""
        phase = final
        let generation = generation
        resetTask?.cancel()
        resetTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, self.generation == generation else { return }
            phase = .idle
        }
    }

    // MARK: - Helpers

    private static let mailApps: Set<String> = [
        "com.apple.mail",
        "com.microsoft.Outlook",
        "com.readdle.smartemail-Mac",
        "com.superhuman.electron",
        "com.mimestream.Mimestream",
        "it.bloop.airmail2",
        "io.canarymail.mac",
        "com.hey.app.desktop",
    ]

    private static func isMailApp(_ app: NSRunningApplication?) -> Bool {
        guard let id = app?.bundleIdentifier else { return false }
        return mailApps.contains(id)
    }
}

struct TimeoutError: Error {}

/// Runs `operation`, throwing `TimeoutError` if it takes longer than `seconds`.
func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

#if DEBUG
extension DictationController {
    /// Walks the island through every state with fake data, for design review:
    /// `"Kaze Dev" --preview-island`
    func runIslandPreview() async {
        let words = "So I was thinking we could ship the new onboarding on Thursday and then follow up with the notch animation polish next week".split(separator: " ")
        listeningSince = Date()
        phase = .listening(handsFree: false)
        for index in 0..<90 {
            levels.removeFirst()
            levels.append(Float.random(in: 0.15...0.95) * Float(0.6 + 0.4 * sin(Double(index) / 4)))
            if index > 25, index % 3 == 0 {
                liveText = words.prefix((index - 25) / 3).joined(separator: " ")
            }
            try? await Task.sleep(for: .milliseconds(60))
        }
        liveText = ""
        phase = .listening(handsFree: true)
        try? await Task.sleep(for: .seconds(1.5))
        targetApp = NSWorkspace.shared.frontmostApplication
        stoppedAt = Date()
        isWaitingForModel = true
        phase = .transcribing
        try? await Task.sleep(for: .seconds(1.5))
        isWaitingForModel = false
        phase = .transcribing
        try? await Task.sleep(for: .seconds(1.5))
        phase = .formatting
        try? await Task.sleep(for: .seconds(1.5))
        phase = .done(pasted: true)
        try? await Task.sleep(for: .seconds(1.5))
        phase = .nothingHeard
        try? await Task.sleep(for: .seconds(2))
        phase = .failed("Kaze needs microphone access")
        try? await Task.sleep(for: .seconds(2.5))
        phase = .idle
    }
}
#endif
