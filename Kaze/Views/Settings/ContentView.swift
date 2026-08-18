import SwiftUI
import AppKit
import AVFoundation
import Combine
import ServiceManagement

// MARK: - Settings Tab Enum

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case controls
    case output
    case vocabulary
    case stats
    case history
    case debug
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return "General"
        case .controls: return "Controls"
        case .output: return "Output"
        case .vocabulary: return "Vocabulary"
        case .stats: return "Stats"
        case .history: return "History"
        case .debug: return "Debug"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .controls: return "slider.horizontal.3"
        case .output: return "pencil.line"
        case .vocabulary: return "text.book.closed"
        case .stats: return "chart.bar.xaxis"
        case .history: return "clock.arrow.circlepath"
        case .debug: return "ladybug"
        case .about: return "info.circle"
        }
    }
}

private enum AppVersion {
    static let displayString: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "Version \(version) (\(build))"
    }()
}

// MARK: - Root View

struct ContentView: View {
    @ObservedObject var appleSpeechModelManager: AppleSpeechModelManager
    @ObservedObject var whisperModelManager: WhisperModelManager
    @ObservedObject var parakeetModelManager: FluidAudioModelManager
    @ObservedObject var historyManager: TranscriptionHistoryManager
    @ObservedObject var customWordsManager: CustomWordsManager
    @ObservedObject var updaterManager: UpdaterManager
    let restartOnboarding: () -> Void

    @State private var selectedTab: SettingsTab? = .general

    init(
        appleSpeechModelManager: AppleSpeechModelManager,
        whisperModelManager: WhisperModelManager,
        parakeetModelManager: FluidAudioModelManager,
        historyManager: TranscriptionHistoryManager,
        customWordsManager: CustomWordsManager,
        updaterManager: UpdaterManager,
        restartOnboarding: @escaping () -> Void,
        initialTab: SettingsTab = .general
    ) {
        self.appleSpeechModelManager = appleSpeechModelManager
        self.whisperModelManager = whisperModelManager
        self.parakeetModelManager = parakeetModelManager
        self.historyManager = historyManager
        self.customWordsManager = customWordsManager
        self.updaterManager = updaterManager
        self.restartOnboarding = restartOnboarding
        _selectedTab = State(initialValue: initialTab)
    }

    private var activeTab: SettingsTab {
        selectedTab ?? .general
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(SettingsTab.allCases, selection: $selectedTab) { tab in
                    SettingsSidebarRow(tab: tab)
                        .tag(tab)
                }
                .listStyle(.sidebar)

                SettingsSidebarFooter()
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            settingsDetail(for: activeTab)
                .settingsDetailTopAligned()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .background(SettingsWindowConfigurator())
        .frame(width: 760, height: 640)
    }

    @ViewBuilder
    private func settingsDetail(for tab: SettingsTab) -> some View {
        switch tab {
        case .general:
            GeneralSettingsView(
                appleSpeechModelManager: appleSpeechModelManager,
                whisperModelManager: whisperModelManager,
                parakeetModelManager: parakeetModelManager
            )
        case .controls:
            ControlsSettingsView()
        case .output:
            OutputSettingsView()
        case .vocabulary:
            VocabularySettingsView(customWordsManager: customWordsManager)
        case .stats:
            StatsSettingsView(historyManager: historyManager)
        case .history:
            HistorySettingsView(historyManager: historyManager)
        case .debug:
            DebugSettingsView(restartOnboarding: restartOnboarding)
        case .about:
            AboutSettingsView(updaterManager: updaterManager)
        }
    }
}

private struct SettingsDetailTopAlignment: ViewModifier {
    // NavigationSplitView keeps the detail column below the titlebar while the sidebar extends into it.
    private let titlebarCompensation: CGFloat = 52

    func body(content: Content) -> some View {
        content
            .offset(y: -titlebarCompensation)
            .padding(.bottom, -titlebarCompensation)
    }
}

private extension View {
    func settingsDetailTopAligned() -> some View {
        modifier(SettingsDetailTopAlignment())
    }
}

private struct SettingsSidebarRow: View {
    let tab: SettingsTab

    var body: some View {
        Label {
            Text(tab.title)
        } icon: {
            Group {
                Image(systemName: tab.icon)
            }
            .frame(width: 18)
        }
    }
}

private struct SettingsSidebarFooter: View {
    var body: some View {
        Text(AppVersion.displayString)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
    }
}

private struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(window: nsView.window)
        }
    }

    private func configure(window: NSWindow?) {
        guard let window else { return }
        window.title = "Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        // The detail view is intentionally aligned into the transparent titlebar
        // area. Let controls in that area receive clicks instead of treating them
        // as draggable window background.
        window.isMovableByWindowBackground = false
        removeSidebarToggleWhenAvailable(from: window)
    }

    private func removeSidebarToggleWhenAvailable(from window: NSWindow) {
        removeSidebarToggle(from: window)

        for delay in [0.0, 0.05, 0.15, 0.35, 0.75] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                removeSidebarToggle(from: window)
            }
        }
    }

    private func removeSidebarToggle(from window: NSWindow) {
        guard let toolbar = window.toolbar else { return }

        for index in toolbar.items.indices.reversed() {
            let item = toolbar.items[index]
            let searchableText = [
                item.itemIdentifier.rawValue,
                item.label,
                item.paletteLabel,
                item.toolTip,
                item.view?.accessibilityLabel(),
                item.view?.accessibilityHelp()
            ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

            if searchableText.contains("sidebar") {
                toolbar.removeItem(at: index)
            }
        }
    }
}

// MARK: - General Settings Tab

private struct GeneralSettingsView: View {
    @AppStorage(AppPreferenceKey.transcriptionEngine) private var engineRaw = TranscriptionEngine.dictation.rawValue
    @AppStorage(AppPreferenceKey.selectedMicrophoneID) private var selectedMicrophoneID = ""
    @State private var availableMicrophones: [AudioInputDevice] = []
    @StateObject private var audioDeviceObserver = AudioDeviceObserver()

    @ObservedObject var appleSpeechModelManager: AppleSpeechModelManager
    @ObservedObject var whisperModelManager: WhisperModelManager
    @ObservedObject var parakeetModelManager: FluidAudioModelManager

    private var selectedEngine: TranscriptionEngine {
        TranscriptionEngine(rawValue: engineRaw) ?? .dictation
    }

    private var microphoneSelection: Binding<String> {
        Binding(
            get: {
                guard !selectedMicrophoneID.isEmpty else { return "" }
                return availableMicrophones.contains(where: { $0.uid == selectedMicrophoneID }) ? selectedMicrophoneID : ""
            },
            set: { newValue in
                selectedMicrophoneID = newValue
            }
        )
    }

    var body: some View {
        Form {
            Section("Transcription") {
                Picker("Transcription engine", selection: $engineRaw) {
                    ForEach(TranscriptionEngine.allCases) { engine in
                        Text(engine.title).tag(engine.rawValue)
                    }
                }

                Text(selectedEngine.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if selectedEngine == .dictation {
                    appleSpeechModelStatusRow
                }

                if selectedEngine == .whisper {
                    Picker("Whisper model", selection: Binding(
                        get: { whisperModelManager.selectedVariant },
                        set: { whisperModelManager.selectedVariant = $0 }
                    )) {
                        ForEach(WhisperModelVariant.allCases) { variant in
                            Text("\(variant.title) (\(variant.sizeDescription))").tag(variant)
                        }
                    }
                    .disabled(isModelBusy)

                    Text(whisperModelManager.selectedVariant.qualityDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    whisperModelStatusRow
                }

                if selectedEngine == .parakeet {
                    fluidAudioModelStatusRow(manager: parakeetModelManager, model: .parakeet)
                }
            }

            Section("Microphone") {
                Picker("Input device", selection: microphoneSelection) {
                    Text("System Default").tag("")
                    Divider()
                    ForEach(availableMicrophones, id: \.uid) { mic in
                        Text(mic.name).tag(mic.uid)
                    }
                }
            }

            Section("System") {
                Toggle(isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            print("Launch at login toggle failed: \(error)")
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Start Kaze when you log in")
                        Text("Kaze will be ready automatically after you sign in.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
        }
        .formStyle(.grouped)
        .contentMargins(.top, 8, for: .scrollContent)
        .onDisappear {
            audioDeviceObserver.stop()
        }
        .onAppear {
            refreshAvailableMicrophones()
            audioDeviceObserver.onChange = {
                refreshAvailableMicrophones()
            }
            audioDeviceObserver.start()
        }
    }

    // MARK: - Audio Device Enumeration

    private func refreshAvailableMicrophones() {
        availableMicrophones = listAudioInputDevices()

        guard !selectedMicrophoneID.isEmpty else { return }

        if !isKnownAudioInputDevice(selectedMicrophoneID) {
            selectedMicrophoneID = ""
        }
    }

    // MARK: - Whisper Model Status

    @ViewBuilder
    private var appleSpeechModelStatusRow: some View {
        switch appleSpeechModelManager.state {
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking system model...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .notDownloaded:
            HStack(spacing: 8) {
                Text("System model not downloaded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Download") {
                    Task { await appleSpeechModelManager.downloadModel() }
                }
                .controlSize(.small)
            }
        case .downloading(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress).frame(maxWidth: 140)
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Cancel", role: .destructive) {
                    appleSpeechModelManager.cancelDownload()
                }
                .controlSize(.small)
            }
        case .ready:
            Label("System model ready", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .unsupported:
            Label("Apple Speech does not support this Mac or system language.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        case .error(let message):
            HStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Retry") {
                    Task { await appleSpeechModelManager.downloadModel() }
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var whisperModelStatusRow: some View {
        switch whisperModelManager.state {
        case .notDownloaded:
            HStack(spacing: 8) {
                Text("Not downloaded (\(whisperModelManager.selectedVariant.sizeDescription))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Download") {
                    Task { await whisperModelManager.downloadModel() }
                }
                .controlSize(.small)
            }

        case .downloading(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(maxWidth: 140)
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Cancel", role: .destructive) {
                    whisperModelManager.cancelDownload()
                }
                .controlSize(.small)
            }

        case .downloaded:
            HStack(spacing: 8) {
                Label {
                    HStack(spacing: 4) {
                        Text("Downloaded")
                        if !whisperModelManager.modelSizeOnDisk.isEmpty {
                            Text("(\(whisperModelManager.modelSizeOnDisk))")
                                .foregroundStyle(.tertiary)
                        }
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()

                Button("Remove", role: .destructive) {
                    whisperModelManager.deleteModel()
                    engineRaw = TranscriptionEngine.dictation.rawValue
                }
                .controlSize(.small)
            }

        case .loading:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Warming up model...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .ready:
            HStack(spacing: 8) {
                Label {
                    HStack(spacing: 4) {
                        Text("Ready")
                        if !whisperModelManager.modelSizeOnDisk.isEmpty {
                            Text("(\(whisperModelManager.modelSizeOnDisk))")
                                .foregroundStyle(.tertiary)
                        }
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()

                Button("Remove", role: .destructive) {
                    whisperModelManager.deleteModel()
                    engineRaw = TranscriptionEngine.dictation.rawValue
                }
                .controlSize(.small)
            }

        case .error(let message):
            HStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)

                Button("Retry") {
                    whisperModelManager.deleteModel()
                    Task { await whisperModelManager.downloadModel() }
                }
                .controlSize(.small)
            }
        }
    }

    private var isModelBusy: Bool {
        whisperModelManager.isBusy
    }

    // MARK: - FluidAudio Model Status

    @ViewBuilder
    private func fluidAudioModelStatusRow(manager: FluidAudioModelManager, model: FluidAudioModel) -> some View {
        switch manager.state {
        case .notDownloaded:
            HStack(spacing: 8) {
                Text("Not downloaded (\(model.sizeDescription))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Download") {
                    Task { await manager.downloadModel() }
                }
                .controlSize(.small)
            }

        case .downloading(let progress):
            HStack(spacing: 8) {
                ProgressView(value: max(progress, 0))
                    .frame(maxWidth: 140)
                Text("\(Int(max(progress, 0) * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Cancel", role: .destructive) {
                    manager.cancelDownload()
                }
                .controlSize(.small)
            }

        case .downloaded:
            HStack(spacing: 8) {
                Label {
                    HStack(spacing: 4) {
                        Text("Downloaded")
                        if !manager.modelSizeOnDisk.isEmpty {
                            Text("(\(manager.modelSizeOnDisk))")
                                .foregroundStyle(.tertiary)
                        }
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()

                Button("Remove", role: .destructive) {
                    manager.deleteModel()
                    engineRaw = TranscriptionEngine.dictation.rawValue
                }
                .controlSize(.small)
            }

        case .loading:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Warming up model...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .ready:
            HStack(spacing: 8) {
                Label {
                    HStack(spacing: 4) {
                        Text("Ready")
                        if !manager.modelSizeOnDisk.isEmpty {
                            Text("(\(manager.modelSizeOnDisk))")
                                .foregroundStyle(.tertiary)
                        }
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()

                Button("Remove", role: .destructive) {
                    manager.deleteModel()
                    engineRaw = TranscriptionEngine.dictation.rawValue
                }
                .controlSize(.small)
            }

        case .error(let message):
            HStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)

                Button("Retry") {
                    manager.deleteModel()
                    Task { await manager.downloadModel() }
                }
                .controlSize(.small)
            }
        }
    }


}

// MARK: - Controls Settings Tab

private struct ControlsSettingsView: View {
    @AppStorage(AppPreferenceKey.hotkeyMode) private var hotkeyModeRaw = HotkeyMode.holdToTalk.rawValue
    @AppStorage(AppPreferenceKey.notchMode) private var notchMode = true
    @State private var hotkeyShortcut = HotkeyShortcut.loadFromDefaults()
    @StateObject private var hotkeyRecorder = HotkeyShortcutRecorder()

    private var selectedHotkeyMode: HotkeyMode {
        HotkeyMode(rawValue: hotkeyModeRaw) ?? .holdToTalk
    }

    var body: some View {
        Form {
            Section("Hotkey") {
                Picker("Mode", selection: $hotkeyModeRaw) {
                    ForEach(HotkeyMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }

                LabeledContent("Shortcut") {
                    HStack(spacing: 8) {
                        HStack(spacing: 3) {
                            ForEach(hotkeyShortcut.displayTokens, id: \.self) { token in
                                KeyCapView(token)
                            }
                        }
                        Button(hotkeyRecorder.isRecording ? "Press keys..." : "Record") {
                            if hotkeyRecorder.isRecording {
                                hotkeyRecorder.stop()
                            } else {
                                hotkeyRecorder.start()
                            }
                        }
                        .controlSize(.small)
                        Button("Reset") {
                            hotkeyShortcut = .default
                            hotkeyShortcut.saveToDefaults()
                            hotkeyRecorder.stop()
                        }
                        .controlSize(.small)
                    }
                }

                Text(selectedHotkeyMode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if hotkeyRecorder.isRecording {
                    Text("Press a key combination with at least one modifier (⌘ ⌥ ⌃ ⇧ fn). For modifier-only shortcuts, hold modifiers then release. Press Esc to cancel.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Appearance") {
                Toggle(isOn: $notchMode) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dynamic Island style")
                        Text("Show the recording indicator near the MacBook notch. When off, Kaze uses a floating pill at the bottom.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }

        }
        .formStyle(.grouped)
        .contentMargins(.top, 8, for: .scrollContent)
        .onDisappear {
            hotkeyRecorder.stop()
        }
        .onAppear {
            hotkeyShortcut = HotkeyShortcut.loadFromDefaults()
            hotkeyRecorder.onShortcutRecorded = { shortcut in
                hotkeyShortcut = shortcut
                hotkeyShortcut.saveToDefaults()
            }
        }
    }
}

private struct OutputSettingsView: View {
    @AppStorage(AppPreferenceKey.transcriptionEngine) private var engineRaw = TranscriptionEngine.dictation.rawValue
    @AppStorage(AppPreferenceKey.appendTrailingSpace) private var appendTrailingSpace = false
    @AppStorage(AppPreferenceKey.removeFillerWords) private var removeFillerWords = false
    @AppStorage(AppPreferenceKey.smartFormattingEnabled) private var smartFormattingEnabled = false
    @AppStorage(AppPreferenceKey.smartFormattingBackend) private var formattingBackendRaw = FormattingBackend.appleIntelligence.rawValue
    @AppStorage(AppPreferenceKey.enhancementMode) private var enhancementModeRaw = EnhancementMode.off.rawValue
    @AppStorage(AppPreferenceKey.enhancementSystemPrompt) private var systemPrompt = AppPreferenceKey.defaultEnhancementPrompt
    @AppStorage(AppPreferenceKey.cloudAIProvider) private var cloudProviderRaw = CloudAIProvider.openAI.rawValue
    @AppStorage(AppPreferenceKey.cloudAIModel) private var cloudModelID = CloudAIProvider.openAI.defaultModel.id
    @State private var apiKeyInput = ""
    @State private var apiKeySaved = false

    private var selectedEngine: TranscriptionEngine {
        TranscriptionEngine(rawValue: engineRaw) ?? .dictation
    }

    private var selectedEnhancementMode: EnhancementMode {
        EnhancementMode(rawValue: enhancementModeRaw) ?? .off
    }

    private var selectedCloudProvider: CloudAIProvider {
        CloudAIProvider(rawValue: cloudProviderRaw) ?? .openAI
    }

    private var textEnhancementAvailable: Bool {
        if #available(macOS 26.0, *) {
            return TextEnhancer.isAvailable
        }
        return false
    }

    private var smartFormattingAppleIntelligenceAvailable: Bool {
        if #available(macOS 26.0, *) {
            return TextFormatter.isAvailable
        }
        return false
    }

    private var cloudAIConfigured: Bool {
        KeychainManager.hasAPIKey(for: selectedCloudProvider)
    }

    private var smartFormattingAvailable: Bool {
        let backend = FormattingBackend(rawValue: formattingBackendRaw) ?? .appleIntelligence
        switch backend {
        case .appleIntelligence: return smartFormattingAppleIntelligenceAvailable
        case .cloudAI: return cloudAIConfigured
        }
    }

    var body: some View {
        Form {
            Section("Cleanup") {
                Toggle(isOn: $appendTrailingSpace) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Append a space after each transcription")
                        Text("Useful when dictating continuously into editors or chat fields.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Toggle(isOn: $removeFillerWords) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remove filler words")
                        Text("Strips hesitation sounds like \"uh\", \"um\", \"hmm\", and similar fillers before pasting.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }

            Section("Smart Formatting") {
                Toggle(isOn: $smartFormattingEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("Auto-detect paragraphs and lists")
                            Text("Experimental")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.orange.opacity(0.15), in: Capsule())
                                .foregroundStyle(.orange)
                        }

                        Text("Uses AI to add line breaks, paragraphs, bullets, and numbered lists from spoken cues.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                if smartFormattingEnabled {
                    Picker("Formatting backend", selection: $formattingBackendRaw) {
                        ForEach(FormattingBackend.allCases) { backend in
                            Text(backend.title).tag(backend.rawValue)
                        }
                    }

                    if !smartFormattingAvailable {
                        let backend = FormattingBackend(rawValue: formattingBackendRaw) ?? .appleIntelligence
                        if backend == .appleIntelligence {
                            Label("Requires macOS 26 with Apple Intelligence enabled.", systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Label("Configure your Cloud AI provider and API key below.", systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Text Enhancement") {
                Picker("Mode", selection: $enhancementModeRaw) {
                    Text(EnhancementMode.off.title).tag(EnhancementMode.off.rawValue)
                    Text(EnhancementMode.appleIntelligence.title)
                        .tag(EnhancementMode.appleIntelligence.rawValue)
                    Text(EnhancementMode.cloudAI.title)
                        .tag(EnhancementMode.cloudAI.rawValue)
                }

                if selectedEnhancementMode == .appleIntelligence {
                    if !textEnhancementAvailable {
                        Label("Apple Intelligence is not available on this Mac.", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if selectedEngine != .dictation {
                        Label("Apple Intelligence enhancement is only available with Direct Dictation. Use Cloud AI for Whisper/Parakeet.", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if selectedEnhancementMode == .cloudAI || smartFormattingBackendUsesCloudAI {
                    Picker("Provider", selection: Binding(
                        get: { cloudProviderRaw },
                        set: { newValue in
                            let provider = CloudAIProvider(rawValue: newValue) ?? .openAI
                            cloudProviderRaw = newValue
                            cloudModelID = provider.defaultModel.id
                            apiKeyInput = KeychainManager.getAPIKey(for: provider) ?? ""
                            apiKeySaved = !apiKeyInput.isEmpty
                        }
                    )) {
                        ForEach(CloudAIProvider.allCases) { provider in
                            Text(provider.title).tag(provider.rawValue)
                        }
                    }

                    Picker("Model", selection: $cloudModelID) {
                        ForEach(selectedCloudProvider.models) { model in
                            Text(model.title).tag(model.id)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("API key")

                        HStack(spacing: 8) {
                            SecureField("Enter your \(selectedCloudProvider.title) API key", text: $apiKeyInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(minWidth: 260, maxWidth: .infinity)
                                .onChange(of: apiKeyInput) {
                                    apiKeySaved = false
                                }

                            Button(apiKeySaved ? "Saved" : "Save") {
                                if !apiKeyInput.isEmpty {
                                    KeychainManager.saveAPIKey(apiKeyInput, for: selectedCloudProvider)
                                    apiKeySaved = true
                                }
                            }
                            .controlSize(.small)
                            .disabled(apiKeyInput.isEmpty || apiKeySaved)

                            if KeychainManager.hasAPIKey(for: selectedCloudProvider) {
                                Button("Remove", role: .destructive) {
                                    KeychainManager.deleteAPIKey(for: selectedCloudProvider)
                                    apiKeyInput = ""
                                    apiKeySaved = false
                                }
                                .controlSize(.small)
                            }
                        }

                        HStack(spacing: 4) {
                            Text("Stored securely in your Mac's Keychain.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let url = selectedCloudProvider.apiKeyURL {
                                Link("Get API key", destination: url)
                                    .font(.caption)
                            }
                        }
                    }
                }

                if (selectedEnhancementMode == .appleIntelligence && selectedEngine == .dictation)
                    || selectedEnhancementMode == .cloudAI {
                    LabeledContent("System prompt") {
                        VStack(alignment: .leading, spacing: 8) {
                            TextEditor(text: $systemPrompt)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(height: 96)
                                .scrollContentBackground(.hidden)
                                .padding(6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(.quaternary.opacity(0.5))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(.quaternary, lineWidth: 1)
                                )

                            HStack {
                                Text("Customise how AI enhances your transcriptions.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Reset to Default") {
                                    systemPrompt = AppPreferenceKey.defaultEnhancementPrompt
                                }
                                .controlSize(.small)
                                .disabled(systemPrompt == AppPreferenceKey.defaultEnhancementPrompt)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .contentMargins(.top, 8, for: .scrollContent)
        .onAppear {
            apiKeyInput = KeychainManager.getAPIKey(for: selectedCloudProvider) ?? ""
            apiKeySaved = !apiKeyInput.isEmpty
        }
    }

    private var smartFormattingBackendUsesCloudAI: Bool {
        smartFormattingEnabled
            && (FormattingBackend(rawValue: formattingBackendRaw) ?? .appleIntelligence) == .cloudAI
    }
}

private struct StatsSettingsView: View {
    @ObservedObject var historyManager: TranscriptionHistoryManager
    private let windowDays = TranscriptionStatsSnapshot.defaultWindowDays
    private let activityColumnCount = 10
    private let activityGridSpacing: CGFloat = 8

    private let metricColumns = [
        GridItem(.flexible(minimum: 0), spacing: 12),
        GridItem(.flexible(minimum: 0), spacing: 12),
        GridItem(.flexible(minimum: 0), spacing: 12)
    ]

    private var summary: TranscriptionStatsSnapshot.WindowedSummary {
        historyManager.stats.summary(forLast: windowDays)
    }

    private var topSources: [TranscriptionStatsSnapshot.SourceUsage] {
        Array(summary.topSources.prefix(5))
    }

    private var activityDays: [StatsActivityDay] {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: Date())
        let wordsByDay = Dictionary(uniqueKeysWithValues: summary.dailyActivity.map {
            (calendar.startOfDay(for: $0.date), $0.words)
        })

        return (0..<windowDays).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset - (windowDays - 1), to: today) else {
                return nil
            }
            return StatsActivityDay(date: date, words: wordsByDay[date] ?? 0)
        }
    }

    private var activityGridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: activityGridSpacing),
            count: activityColumnCount
        )
    }

    private var activityPeak: Int {
        max(activityDays.map(\.words).max() ?? 0, 1)
    }

    private var activeDaysInWindow: Int {
        activityDays.reduce(into: 0) { count, day in
            if day.words > 0 {
                count += 1
            }
        }
    }

    private var subtitle: String {
        if summary.totalSessions == 0 {
            return historyManager.records.isEmpty
                ? "Dictate something and your usage will show up here."
                : "Usage stats start tracking with your next transcription."
        }

        return "\(summary.totalSessions.formattedCount) dictated session\(summary.totalSessions == 1 ? "" : "s") in the last \(windowDays) days."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Usage Overview")
                        .font(.headline)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                LazyVGrid(columns: metricColumns, spacing: 12) {
                    StatsMetricCard(
                        title: "Total words",
                        value: summary.totalWords.formattedCount,
                        detail: "\(summary.totalSessions.formattedCount) session\(summary.totalSessions == 1 ? "" : "s")"
                    )

                    StatsMetricCard(
                        title: "Time saved",
                        value: summary.estimatedTimeSaved.statsDurationString,
                        detail: "Vs 40 WPM typing"
                    )

                    StatsMetricCard(
                        title: "Speed",
                        value: summary.averageWordsPerMinute.map { "\($0.wpmString) WPM" } ?? "--",
                        detail: summary.averageWordsPerMinute == nil ? "Needs captured speech time" : "Average speaking speed"
                    )
                }
                .padding(.horizontal, 20)

                activitySection
                    .padding(.horizontal, 20)

                topSourcesSection
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
            }
        }
        .contentMargins(.top, 8, for: .scrollContent)
    }

    private var topSourcesSection: some View {
        StatsPanel(
            title: "Top Sources",
            subtitle: "Where Kaze is used the most in the last \(windowDays) days"
        ) {
            if topSources.isEmpty {
                StatsEmptyState(
                    systemImage: "app.badge",
                    title: "No sources yet",
                    message: "App usage appears here after your next dictated session."
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(topSources) { source in
                        HStack(spacing: 12) {
                            SourceAppIconView(
                                bundleIdentifier: source.bundleIdentifier,
                                displayName: source.name
                            )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)

                                Text("\(source.sessions.formattedCount) session\(source.sessions == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 12)

                            Text("\(source.words.formattedCount) words")
                                .font(.system(size: 13, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 10)

                        if source.id != topSources.last?.id {
                            Divider()
                                .padding(.leading, 42)
                        }
                    }
                }
            }
        }
    }

    private var activitySection: some View {
        StatsPanel(
            title: "Activity",
            subtitle: "Last \(windowDays) days"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: activityGridColumns, alignment: .leading, spacing: activityGridSpacing) {
                    ForEach(activityDays) { day in
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.accentColor.opacity(activityOpacity(for: day.words)))
                            .aspectRatio(1, contentMode: .fit)
                            .overlay {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(
                                        Calendar.autoupdatingCurrent.isDateInToday(day.date)
                                            ? Color.accentColor.opacity(0.8)
                                            : Color.primary.opacity(0.08),
                                        lineWidth: Calendar.autoupdatingCurrent.isDateInToday(day.date) ? 1 : 0.5
                                    )
                            }
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(.quaternary.opacity(0.28))
                            )
                            .help(day.date.activityTooltip(words: day.words))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text("\(activeDaysInWindow.formattedCount) active day\(activeDaysInWindow == 1 ? "" : "s") in the last \(windowDays) days")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func activityOpacity(for words: Int) -> Double {
        guard words > 0 else { return 0.06 }
        let normalized = Double(words) / Double(activityPeak)
        return 0.18 + (normalized * 0.72)
    }
}

private struct StatsMetricCard: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.75)
                .lineLimit(1)
                .foregroundStyle(.primary)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.quaternary.opacity(0.24))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct StatsPanel<Content: View>: View {
    let title: String
    let subtitle: String
    let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.quaternary.opacity(0.18))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct StatsEmptyState: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 24))
                .foregroundStyle(.quaternary)

            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            Text(message)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }
}

private struct SourceAppIconView: View {
    let bundleIdentifier: String?
    let displayName: String

    private var appIcon: NSImage? {
        guard
            let bundleIdentifier,
            let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else {
            return nil
        }

        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        icon.size = NSSize(width: 28, height: 28)
        return icon
    }

    private var fallbackLetter: String {
        String(displayName.prefix(1)).uppercased()
    }

    var body: some View {
        Group {
            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.quaternary.opacity(0.35))

                    Text(fallbackLetter)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 28, height: 28)
            }
        }
    }
}

private struct StatsActivityDay: Identifiable {
    let date: Date
    let words: Int

    var id: Date { date }
}

// MARK: - History Tab

private struct HistorySettingsView: View {
    @ObservedObject var historyManager: TranscriptionHistoryManager

    var body: some View {
        VStack(spacing: 0) {
            if historyManager.records.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 28))
                        .foregroundStyle(.quaternary)
                    Text("No transcriptions yet")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Text("Dictate something and it will appear here.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            } else {
                // Toolbar row
                HStack {
                    Text("\(historyManager.records.count) transcription\(historyManager.records.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear All", role: .destructive) {
                        historyManager.clearHistory()
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Divider()

                // Records list
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(historyManager.records) { record in
                            historyRow(for: record)

                            if record.id != historyManager.records.last?.id {
                                Divider()
                                    .padding(.leading, 36)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func historyRow(for record: TranscriptionRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            historyIconView(for: record.engine)
                .foregroundStyle(.tertiary)
                .frame(width: 16, height: 16, alignment: .center)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(record.text)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .truncationMode(.tail)

                HStack(spacing: 6) {
                    Text(record.timestamp.relativeString)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    if record.wasEnhanced {
                        Text("Enhanced")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(.blue.opacity(0.12))
                            )
                            .foregroundStyle(.blue)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Copy to clipboard")
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func historyIconView(for engine: String) -> some View {
        switch engine {
        case "whisper":
            Image("openai-icon")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
        case "parakeet":
            Image("nvidia-icon")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
        default:
            Text("\u{F8FF}")
                .font(.system(size: 14))
        }
    }
}

// MARK: - Vocabulary Tab

private struct VocabularySettingsView: View {
    @ObservedObject var customWordsManager: CustomWordsManager
    @State private var newWord: String = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Add word input
            HStack(spacing: 8) {
                TextField("Add a new word or phrase", text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .focused($isInputFocused)
                    .onSubmit {
                        addCurrentWord()
                    }

                Button("Add") {
                    addCurrentWord()
                }
                .controlSize(.small)
                .disabled(newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)

            Divider()

            if customWordsManager.words.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "text.book.closed")
                        .font(.system(size: 28))
                        .foregroundStyle(.quaternary)
                    Text("No custom words yet")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Text("Add names, abbreviations, and specialised terms.\nWhisper uses them during transcription; AI enhancement preserves their spelling.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 20)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(customWordsManager.words.enumerated()), id: \.offset) { index, word in
                            wordRow(word, at: index)

                            if index < customWordsManager.words.count - 1 {
                                Divider()
                                    .padding(.leading, 16)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }

                Divider()

                // Footer
                HStack {
                    Text("\(customWordsManager.words.count) word\(customWordsManager.words.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }

    private func addCurrentWord() {
        let trimmed = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        customWordsManager.addWord(trimmed)
        newWord = ""

        // Let the button/text-field event finish before restoring focus. On macOS,
        // doing this synchronously after a button click can leave the field unable
        // to accept the next word once the first list item appears.
        DispatchQueue.main.async {
            isInputFocused = true
        }
    }

    private func wordRow(_ word: String, at index: Int) -> some View {
        HStack {
            Text(word)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                customWordsManager.removeWord(at: index)
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove word")
        }
        .padding(.vertical, 8)
    }
}

private struct DebugSettingsView: View {
    let restartOnboarding: () -> Void

    var body: some View {
        Form {
            Section("Onboarding") {
                VStack(alignment: .leading, spacing: 8) {
                    Button("Restart Onboarding") {
                        restartOnboarding()
                    }
                    .buttonStyle(.borderedProminent)

                    Text("Reopens the first-launch onboarding flow for testing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}

// MARK: - Audio Device Observer

/// Observes microphone device changes and calls `onChange` on the main thread.
class AudioDeviceObserver: ObservableObject {
    var onChange: (() -> Void)?
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }

        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: AVCaptureDevice.wasConnectedNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.onChange?()
            },
            center.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.onChange?()
            }
        ]
    }

    func stop() {
        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
    }

    deinit {
        stop()
    }
}

// MARK: - About Settings

private struct AboutSettingsView: View {
    @ObservedObject var updaterManager: UpdaterManager
    @State private var avatarImage: NSImage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center, spacing: 16) {
                    appIcon

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Kaze")
                            .font(.largeTitle.bold())

                        Text(AppVersion.displayString)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Text("Speech-to-text dictation for macOS.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Updates")
                        .font(.headline)

                    Toggle(isOn: Binding(
                        get: { updaterManager.automaticallyChecksForUpdates },
                        set: { updaterManager.automaticallyChecksForUpdates = $0 }
                    )) {
                        Text("Automatically check for updates")
                    }
                    .toggleStyle(.switch)

                    Button("Check for Updates…") {
                        updaterManager.checkForUpdates()
                    }
                    .disabled(!updaterManager.canCheckForUpdates)
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Follow")
                        .font(.headline)

                    Text("Follow Fayaz on Twitter for Kaze updates, release notes, and development notes.")
                        .foregroundStyle(.secondary)

                    Link(destination: URL(string: "https://x.com/fayazara")!) {
                        HStack(spacing: 8) {
                            if let avatarImage {
                                Image(nsImage: avatarImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 24, height: 24)
                                    .clipShape(Circle())
                            }

                            Text("Follow Fayaz on Twitter")
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Project")
                        .font(.headline)

                    HStack(spacing: 10) {
                        Link("GitHub", destination: URL(string: "https://github.com/fayazara/Kaze")!)
                        Link("Releases", destination: URL(string: "https://github.com/fayazara/Kaze/releases")!)
                    }
                    .controlSize(.small)

                    Text("MIT License")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 520, alignment: .leading)
        }
        .contentMargins(.top, 8, for: .scrollContent)
        .task {
            await loadAvatar()
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        if let icon = NSImage(named: "kaze-icon") {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 72, height: 72)
        } else {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
        }
    }

    private func loadAvatar() async {
        guard let url = URL(string: "https://github.com/fayazara.png") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let image = NSImage(data: data) {
                await MainActor.run { avatarImage = image }
            }
        } catch {
            // The about page works fine without the remote avatar.
        }
    }
}

private extension Int {
    var formattedCount: String {
        formatted(.number.grouping(.automatic))
    }
}

private extension Double {
    var wpmString: String {
        Int(rounded()).formatted(.number.grouping(.never))
    }
}

private extension TimeInterval {
    var statsDurationString: String {
        let totalMinutes = max(Int((self / 60).rounded()), 0)

        if totalMinutes == 0 {
            return "0m"
        }

        let days = totalMinutes / (60 * 24)
        let hours = (totalMinutes % (60 * 24)) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            if hours > 0 {
                return "\(days)d \(hours)h"
            }
            return "\(days)d"
        }

        if hours > 0 {
            if minutes > 0 {
                return "\(hours)h \(minutes)m"
            }
            return "\(hours)h"
        }

        return "\(minutes)m"
    }
}

private extension Date {
    func activityTooltip(words: Int) -> String {
        let wordsLabel = "\(words.formatted(.number.grouping(.automatic))) word\(words == 1 ? "" : "s")"
        return "\(formatted(date: .abbreviated, time: .omitted)): \(wordsLabel)"
    }
}

// MARK: - Key Cap View

private struct KeyCapView: View {
    let key: String

    init(_ key: String) {
        self.key = key
    }

    var body: some View {
        Text(key)
            .font(.system(size: 12, weight: .medium))
            .frame(minWidth: 22, minHeight: 20)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 1)
            )
    }
}
