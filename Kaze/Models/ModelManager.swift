import Foundation
import Observation
import os
import Speech

enum InstallState: Equatable {
    case checking
    case notInstalled
    case downloading(Double)
    /// Downloaded; Core ML is compiling it for this Mac's Neural Engine
    /// (a one-time step that can take a few minutes).
    case preparing
    case installed
    case unavailable(String)
    case failed(String)

    var isInstalled: Bool { self == .installed }

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}

/// Owns every model: what's installed, downloads in flight, and the loaded
/// engines. The single source of truth the UI and the dictation pipeline read.
@Observable
final class ModelManager {
    private(set) var speechStates: [SpeechModel: InstallState] = [:]
    private(set) var formatterState: InstallState = .checking
    private(set) var diskUsage: [String: Int64] = [:]
    /// The model currently being loaded into memory, for the "warming up" hint.
    private(set) var warmingModel: SpeechModel?
    private(set) var lastWarmUpError: String?

    let formatter = S1MiniFormatter()
    let chatGPT = ChatGPTAccount()
    @ObservationIgnored private(set) lazy var chatGPTCleaner = ChatGPTCleaner(account: chatGPT)

    func cleaner(for engine: CleanUpEngine) -> any TextCleaner {
        switch engine {
        case .chatGPT: chatGPTCleaner
        case .s1Mini: formatter
        }
    }

    /// Whether `engine` can run right now (downloaded / turned on).
    func isCleanUpReady(_ engine: CleanUpEngine) -> Bool {
        switch engine {
        case .chatGPT: chatGPT.isSignedIn
        case .s1Mini: formatterState.isInstalled
        }
    }

    @ObservationIgnored private var engines: [SpeechModel: any SpeechEngine] = [:]
    @ObservationIgnored private var idleUnload: Task<Void, Never>?
    @ObservationIgnored private var memoryPressure: DispatchSourceMemoryPressure?
    /// A dictation is using the models; never unload underneath it.
    @ObservationIgnored private var inUse = false

    /// Models stay loaded this long after the last dictation. Reloading is
    /// ~0.1 s once macOS has the Neural Engine build cached, so holding them
    /// longer only costs memory.
    private static let idleUnloadDelay: Duration = .seconds(3 * 60)
    @ObservationIgnored private var downloads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let log = Logger(subsystem: "com.fayazahmed.Kaze", category: "Models")

    init() {
        for model in SpeechModel.allCases { speechStates[model] = .checking }
        refresh()
        watchMemoryPressure()
    }

    func state(of model: SpeechModel) -> InstallState {
        speechStates[model] ?? .checking
    }

    /// Re-reads what's on disk.
    func refresh() {
        for model in SpeechModel.allCases where !state(of: model).isDownloading && state(of: model) != .preparing {
            switch model.family {
            case .apple:
                Task { await refreshAppleState() }
            case .parakeet:
                speechStates[model] = ParakeetEngine.isInstalled(model) ? .installed : .notInstalled
            case .whisper:
                speechStates[model] = WhisperEngine.isInstalled(model) ? .installed : .notInstalled
            }
        }
        if !formatterState.isDownloading {
            formatterState = S1MiniFormatter.isInstalled ? .installed : .notInstalled
        }
        refreshDiskUsage()
    }

    func refreshAppleState() async {
        guard AppleSpeechEngine.isSupported else {
            speechStates[.apple] = .unavailable("Requires Apple silicon and macOS 26")
            return
        }
        guard !state(of: .apple).isDownloading else { return }
        switch await AppleSpeechEngine.assetStatus(for: Preferences.shared.language) {
        case .installed: speechStates[.apple] = .installed
        case .unsupported: speechStates[.apple] = .unavailable("Your language isn't supported")
        default: speechStates[.apple] = .notInstalled
        }
    }

    // MARK: - Engines

    func engine(for model: SpeechModel) -> any SpeechEngine {
        if let engine = engines[model] { return engine }
        let engine: any SpeechEngine = switch model.family {
        case .apple: AppleSpeechEngine()
        case .parakeet: ParakeetEngine(model: model)
        case .whisper: WhisperEngine(model: model)
        }
        engines[model] = engine
        return engine
    }

    /// Loads `model` and releases every other engine. Used at launch to
    /// prime macOS's Neural Engine compile cache (the slow part), and when a
    /// dictation starts so the model loads while the user is speaking.
    /// Unless a dictation is running, the model is freed again after
    /// `idleUnloadDelay`.
    func warmUp(_ model: SpeechModel) {
        idleUnload?.cancel()
        for (other, engine) in engines where other != model { engine.unload() }
        guard state(of: model).isInstalled else { return }
        warmingModel = model
        lastWarmUpError = nil
        Task {
            do {
                try await engine(for: model).prepare()
            } catch {
                log.error("Warm-up of \(model.title, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                lastWarmUpError = error.localizedDescription
            }
            if warmingModel == model { warmingModel = nil }
            if !inUse { scheduleIdleUnload() }
        }
    }

    /// A dictation started: keep everything loaded until it ends.
    func beginUse(_ model: SpeechModel) {
        inUse = true
        warmUp(model)
    }

    /// The dictation ended: free memory once the user has been idle a while.
    func endUse() {
        inUse = false
        scheduleIdleUnload()
    }

    private func scheduleIdleUnload() {
        idleUnload?.cancel()
        idleUnload = Task {
            try? await Task.sleep(for: Self.idleUnloadDelay)
            guard !Task.isCancelled, !inUse else { return }
            unloadAll(reason: "idle")
        }
    }

    private func unloadAll(reason: String) {
        guard !inUse else { return }
        for engine in engines.values { engine.unload() }
        formatter.unload()
        log.info("Unloaded models (\(reason, privacy: .public))")
    }

    /// Give memory back as soon as macOS asks for it.
    private func watchMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.unloadAll(reason: "memory pressure") }
        }
        source.resume()
        memoryPressure = source
    }

    // MARK: - Speech model downloads

    func download(_ model: SpeechModel) {
        let key = model.rawValue
        guard downloads[key] == nil else { return }
        speechStates[model] = .downloading(0)
        downloads[key] = Task {
            let report: @Sendable (Double) -> Void = { fraction in
                Task { @MainActor in
                    if case .downloading = self.speechStates[model] {
                        self.speechStates[model] = .downloading(min(max(fraction, 0), 1))
                    }
                }
            }
            do {
                switch model.family {
                case .apple:
                    let locale = try await AppleSpeechEngine.resolveLocale(Preferences.shared.language)
                    try await AppleSpeechEngine.installAssets(for: locale, progress: report)
                case .parakeet:
                    try await ParakeetEngine.download(model, progress: report)
                case .whisper:
                    try await WhisperEngine.download(model, progress: report)
                }
                try Task.checkCancellation()
                if model.requiresDownload {
                    speechStates[model] = .preparing
                    do {
                        try await engine(for: model).prepare()
                    } catch {
                        log.error("Preparing \(model.title, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
                speechStates[model] = .installed
                if Preferences.shared.speechModel == model {
                    warmUp(model)
                } else {
                    engines[model]?.unload()
                }
            } catch is CancellationError {
                speechStates[model] = .notInstalled
            } catch {
                log.error("Download of \(model.title, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                speechStates[model] = Task.isCancelled ? .notInstalled : .failed(error.localizedDescription)
            }
            downloads[key] = nil
            refreshDiskUsage()
        }
    }

    func cancelDownload(_ model: SpeechModel) {
        downloads[model.rawValue]?.cancel()
        downloads[model.rawValue] = nil
        speechStates[model] = .notInstalled
    }

    func delete(_ model: SpeechModel) {
        engines[model]?.unload()
        engines[model] = nil
        switch model.family {
        case .apple:
            return
        case .parakeet:
            try? FileManager.default.removeItem(at: ParakeetEngine.directory(for: model))
        case .whisper:
            WhisperEngine.delete(model)
        }
        speechStates[model] = .notInstalled
        refreshDiskUsage()
    }

    // MARK: - Formatter

    func downloadFormatter() {
        guard downloads["formatter"] == nil else { return }
        formatterState = .downloading(0)
        downloads["formatter"] = Task {
            do {
                try await S1MiniFormatter.download { fraction in
                    Task { @MainActor in
                        if case .downloading = self.formatterState { self.formatterState = .downloading(fraction) }
                    }
                }
                try Task.checkCancellation()
                formatterState = .installed
                Preferences.shared.formattingEnabled = true
            } catch is CancellationError {
                formatterState = .notInstalled
            } catch {
                log.error("S1-mini download failed: \(error.localizedDescription, privacy: .public)")
                formatterState = Task.isCancelled ? .notInstalled : .failed(error.localizedDescription)
            }
            downloads["formatter"] = nil
            refreshDiskUsage()
        }
    }

    func cancelFormatterDownload() {
        downloads["formatter"]?.cancel()
        downloads["formatter"] = nil
        formatterState = .notInstalled
    }

    func deleteFormatter() {
        formatter.unload()
        try? FileManager.default.removeItem(at: S1MiniFormatter.directory)
        formatterState = .notInstalled
        Preferences.shared.formattingEnabled = false
        refreshDiskUsage()
    }

    // MARK: - Disk usage

    private func refreshDiskUsage() {
        var locations: [String: URL] = ["formatter": S1MiniFormatter.directory]
        for model in SpeechModel.allCases {
            switch model.family {
            case .apple: continue
            case .parakeet: locations[model.rawValue] = ParakeetEngine.directory(for: model)
            case .whisper: if let folder = WhisperEngine.folder(for: model) { locations[model.rawValue] = folder }
            }
        }
        Task.detached(priority: .utility) {
            var usage: [String: Int64] = [:]
            for (key, url) in locations { usage[key] = FileManager.default.allocatedSize(of: url) }
            let result = usage
            await MainActor.run { self.diskUsage = result }
        }
    }

    func diskUsageText(for key: String) -> String? {
        guard let bytes = diskUsage[key], bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
