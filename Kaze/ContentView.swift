import SwiftUI
import AppKit
import AVFoundation
import Combine
import ServiceManagement

// MARK: - Settings Tab Enum

private enum SettingsTab: String, CaseIterable {
    case general
    case vocabulary
    case history

    var title: String {
        switch self {
        case .general: return "General"
        case .vocabulary: return "Vocabulary"
        case .history: return "History"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .vocabulary: return "text.book.closed"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

// MARK: - Root View

struct ContentView: View {
    @ObservedObject var whisperModelManager: WhisperModelManager
    @ObservedObject var parakeetModelManager: FluidAudioModelManager
    @ObservedObject var qwenModelManager: FluidAudioModelManager
    @ObservedObject var historyManager: TranscriptionHistoryManager
    @ObservedObject var customWordsManager: CustomWordsManager
    @ObservedObject var updaterManager: UpdaterManager

    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            tabBar

            Divider()

            // Tab content
            Group {
                switch selectedTab {
                case .general:
                    GeneralSettingsView(
                        whisperModelManager: whisperModelManager,
                        parakeetModelManager: parakeetModelManager,
                        qwenModelManager: qwenModelManager,
                        updaterManager: updaterManager
                    )
                case .vocabulary:
                    VocabularySettingsView(customWordsManager: customWordsManager)
                case .history:
                    HistorySettingsView(historyManager: historyManager)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                tabButton(for: tab)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private func tabButton(for tab: SettingsTab) -> some View {
        Button {
            selectedTab = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.icon)
                    .font(.system(size: 18))
                    .frame(width: 28, height: 22)
                Text(tab.title)
                    .font(.system(size: 10))
            }
            .foregroundStyle(selectedTab == tab ? Color.accentColor : .secondary)
            .frame(width: 68, height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - General Settings Tab

private struct GeneralSettingsView: View {
    @AppStorage(AppPreferenceKey.transcriptionEngine) private var engineRaw = TranscriptionEngine.dictation.rawValue
    @AppStorage(AppPreferenceKey.enhancementMode) private var enhancementModeRaw = EnhancementMode.off.rawValue
    @AppStorage(AppPreferenceKey.enhancementSystemPrompt) private var systemPrompt = AppPreferenceKey.defaultEnhancementPrompt
    @AppStorage(AppPreferenceKey.hotkeyMode) private var hotkeyModeRaw = HotkeyMode.holdToTalk.rawValue
    @AppStorage(AppPreferenceKey.notchMode) private var notchMode = true
    @AppStorage(AppPreferenceKey.selectedMicrophoneID) private var selectedMicrophoneID = ""
    @AppStorage(AppPreferenceKey.appendTrailingSpace) private var appendTrailingSpace = false
    @State private var hotkeyShortcut = HotkeyShortcut.loadFromDefaults()
    @State private var isRecordingHotkey = false
    @State private var hotkeyMonitor: Any?
    @State private var recordedModifiersUnion: HotkeyShortcut.Modifiers = []
    @State private var availableMicrophones: [AudioInputDevice] = []
    @StateObject private var audioDeviceObserver = AudioDeviceObserver()

    @ObservedObject var whisperModelManager: WhisperModelManager
    @ObservedObject var parakeetModelManager: FluidAudioModelManager
    @ObservedObject var qwenModelManager: FluidAudioModelManager
    @ObservedObject var updaterManager: UpdaterManager

    private var selectedEngine: TranscriptionEngine {
        TranscriptionEngine(rawValue: engineRaw) ?? .dictation
    }

    private var selectedHotkeyMode: HotkeyMode {
        HotkeyMode(rawValue: hotkeyModeRaw) ?? .holdToTalk
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

    private var appleIntelligenceAvailable: Bool {
        if #available(macOS 26.0, *) {
            return TextEnhancer.isAvailable
        }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: Transcription
            formRow("Transcription engine:") {
                Picker("Engine", selection: $engineRaw) {
                    ForEach(TranscriptionEngine.allCases) { engine in
                        Text(engine.title).tag(engine.rawValue)
                    }
                }
                .labelsHidden()
            }

            // Engine details card: description + model controls + status
            formRow("") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(selectedEngine.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if selectedEngine == .whisper {
                        Picker("Model", selection: Binding(
                            get: { whisperModelManager.selectedVariant },
                            set: { whisperModelManager.selectedVariant = $0 }
                        )) {
                            ForEach(WhisperModelVariant.allCases) { variant in
                                Text("\(variant.title) (\(variant.sizeDescription))").tag(variant)
                            }
                        }
                        .labelsHidden()
                        .disabled(isModelBusy)

                        Text(whisperModelManager.selectedVariant.qualityDescription)
                            .font(.caption)
                            .foregroundStyle(.tertiary)

                        whisperModelStatusRow
                    }

                    if selectedEngine == .parakeet {
                        fluidAudioModelStatusRow(manager: parakeetModelManager, model: .parakeet)
                    }

                    if selectedEngine == .qwen {
                        fluidAudioModelStatusRow(manager: qwenModelManager, model: .qwen)
                    }
                }
            }

            sectionDivider()

            // MARK: Microphone
            formRow("Microphone:") {
                Picker("Microphone", selection: microphoneSelection) {
                    Text("System Default").tag("")
                    ForEach(availableMicrophones, id: \.uid) { mic in
                        Text(mic.name).tag(mic.uid)
                    }
                }
                .labelsHidden()
            }

            sectionDivider()

            // MARK: Hotkey
            formRow("Hotkey mode:") {
                Picker("Mode", selection: $hotkeyModeRaw) {
                    ForEach(HotkeyMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .labelsHidden()
            }

            formRow("Shortcut:") {
                HStack(spacing: 8) {
                    HStack(spacing: 3) {
                        ForEach(hotkeyShortcut.displayTokens, id: \.self) { token in
                            KeyCapView(token)
                        }
                    }
                    Button(isRecordingHotkey ? "Press keys..." : "Record") {
                        if isRecordingHotkey {
                            stopHotkeyRecording()
                        } else {
                            startHotkeyRecording()
                        }
                    }
                    .controlSize(.small)
                    Button("Reset") {
                        hotkeyShortcut = .default
                        hotkeyShortcut.saveToDefaults()
                        stopHotkeyRecording()
                    }
                    .controlSize(.small)
                }
            }

            formRow("") {
                Text(selectedHotkeyMode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isRecordingHotkey {
                formRow("") {
                    Text("Press a key combination with at least one modifier (⌘ ⌥ ⌃ ⇧ fn). For modifier-only shortcuts, hold modifiers then release. Press Esc to cancel.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            sectionDivider()

            // MARK: Enhancement
            formRow("Text enhancement:") {
                Picker("Enhancement", selection: $enhancementModeRaw) {
                    Text(EnhancementMode.off.title).tag(EnhancementMode.off.rawValue)
                    Text(EnhancementMode.appleIntelligence.title)
                        .tag(EnhancementMode.appleIntelligence.rawValue)
                }
                .labelsHidden()
                .disabled(selectedEngine != .dictation)
            }

            if selectedEngine != .dictation {
                formRow("") {
                    Label("Text enhancement is only available with Direct Dictation. AI models already produce enhanced output.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !appleIntelligenceAvailable {
                formRow("") {
                    Label("Apple Intelligence is not available on this Mac.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if enhancementModeRaw == EnhancementMode.appleIntelligence.rawValue, selectedEngine == .dictation {
                formRow("System prompt:") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextEditor(text: $systemPrompt)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(height: 80)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(.quaternary.opacity(0.5))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(.quaternary, lineWidth: 1)
                            )

                        HStack {
                            Text("Customise how Apple Intelligence enhances your transcriptions.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
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

            sectionDivider()

            // MARK: Appearance
            formRow("Notch mode:") {
                Toggle(isOn: $notchMode) {
                    Text("Dynamic Island style")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            formRow("") {
                Text("Show the recording indicator at the top of the screen, like a Dynamic Island around the MacBook notch. When off, a floating pill appears at the bottom.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            sectionDivider()

            // MARK: Output
            formRow("Trailing space:") {
                Toggle(isOn: $appendTrailingSpace) {
                    Text("Append a space after each transcription")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            sectionDivider()

            // MARK: System
            formRow("Launch at login:") {
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
                    Text("Start Kaze when you log in")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            sectionDivider()

            // MARK: Updates
            formRow("Auto-update:") {
                Toggle(isOn: Binding(
                    get: { updaterManager.automaticallyChecksForUpdates },
                    set: { updaterManager.automaticallyChecksForUpdates = $0 }
                )) {
                    Text("Automatically check for updates")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            formRow("") {
                Button("Check for Updates…") {
                    updaterManager.checkForUpdates()
                }
                .controlSize(.small)
                .disabled(!updaterManager.canCheckForUpdates)
            }

            Spacer(minLength: 20)
        }
        .padding(.top, 12)
        .onDisappear {
            stopHotkeyRecording()
            audioDeviceObserver.stop()
        }
        .onAppear {
            hotkeyShortcut = HotkeyShortcut.loadFromDefaults()
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
                Text("Loading model...")
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
        switch whisperModelManager.state {
        case .downloading, .loading:
            return true
        default:
            return false
        }
    }

    // MARK: - FluidAudio Model Status (Parakeet / Qwen)

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
                if progress < 0 {
                    // Indeterminate progress (FluidAudio doesn't expose granular progress)
                    ProgressView()
                        .controlSize(.small)
                    Text("Downloading...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView(value: progress)
                        .frame(maxWidth: 140)
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
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
                Text("Loading model...")
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

    private func startHotkeyRecording() {
        stopHotkeyRecording()
        isRecordingHotkey = true
        recordedModifiersUnion = []

        hotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if !isRecordingHotkey {
                return event
            }

            if event.type == .flagsChanged {
                let modifiers = HotkeyShortcut.Modifiers(from: event.modifierFlags)

                if !modifiers.isEmpty {
                    recordedModifiersUnion.formUnion(modifiers)
                    return nil
                }

                // User released held modifiers without pressing a regular key:
                // treat this as a modifier-only shortcut recording.
                if !recordedModifiersUnion.isEmpty {
                    hotkeyShortcut = HotkeyShortcut(modifiers: recordedModifiersUnion, keyCode: nil)
                    hotkeyShortcut.saveToDefaults()
                    stopHotkeyRecording()
                    return nil
                }

                return nil
            }

            if event.keyCode == 53 {
                stopHotkeyRecording()
                return nil
            }

            let modifiers = HotkeyShortcut.Modifiers(from: event.modifierFlags)
            guard !modifiers.isEmpty else {
                NSSound.beep()
                return nil
            }

            hotkeyShortcut = HotkeyShortcut(modifiers: modifiers, keyCode: Int(event.keyCode))
            hotkeyShortcut.saveToDefaults()
            stopHotkeyRecording()
            return nil
        }
    }

    private func stopHotkeyRecording() {
        isRecordingHotkey = false
        recordedModifiersUnion = []
        if let hotkeyMonitor {
            NSEvent.removeMonitor(hotkeyMonitor)
            self.hotkeyMonitor = nil
        }
    }


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
            Image(systemName: historyIconName(for: record.engine))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 16, alignment: .center)
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

    private func historyIconName(for engine: String) -> String {
        switch engine {
        case "whisper": return "waveform"
        case "parakeet": return "bird"
        case "qwen": return "brain.head.profile"
        default: return "mic.fill"
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
            .padding(.top, 14)
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
                    Text("Add names, abbreviations, and specialised terms.\nKaze will recognise them during transcription.")
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
        isInputFocused = true
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

// MARK: - Shared Form Helpers

private let formLabelWidth: CGFloat = 140

private func formRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(label)
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .frame(width: formLabelWidth, alignment: .trailing)

        content()
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 4)
}

private func sectionDivider() -> some View {
    Divider()
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
}

// MARK: - About View

struct AboutView: View {
    private let appVersion: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "v\(version) (\(build))"
    }()

    var body: some View {
        VStack(spacing: 12) {
            if let icon = NSImage(named: "kaze-icon") {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)
            } else {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
            }

            Text("Kaze")
                .font(.title2.bold())

            Text(appVersion)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Speech-to-text, entirely on-device.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Divider()
                .padding(.horizontal, 40)

            HStack(spacing: 16) {
                Button("GitHub") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/fayazara/Kaze")!)
                }
                .controlSize(.small)

                Button("Releases") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/fayazara/Kaze/releases")!)
                }
                .controlSize(.small)
            }

            Text("MIT License")
                .font(.caption2)
                .foregroundStyle(.quaternary)
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 40)
        .frame(width: 300)
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
