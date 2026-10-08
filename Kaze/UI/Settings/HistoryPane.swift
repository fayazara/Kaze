import AppKit
import SwiftUI

struct HistoryPane: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var confirmClear = false

    private var filtered: [HistoryItem] {
        let items = app.history.items
        guard !query.isEmpty else { return items }
        return items.filter { $0.text.localizedCaseInsensitiveContains(query) || ($0.appName ?? "").localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        @Bindable var prefs = app.preferences
        VStack(spacing: 0) {
            stats
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 12)

            if app.history.items.isEmpty {
                ContentUnavailableView {
                    Label("No dictations yet", systemImage: "waveform")
                } description: {
                    Text("Hold \(app.preferences.shortcut.displayName) anywhere and start talking.")
                }
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(filtered) { item in
                        HistoryRow(item: item)
                            .contextMenu {
                                if item.failure == nil { Button("Copy") { copy(item.text) } }
                                if let raw = item.rawText { Button("Copy Original Transcript") { copy(raw) } }
                                if let recording = item.recordingURL {
                                    Divider()
                                    Button("Retry Transcription") { app.dictation.retry(item) }
                                        .disabled(!app.dictation.canRetry || app.dictation.retrying.contains(item.id))
                                    Button("Show Recording in Finder") { NSWorkspace.shared.activateFileViewerSelecting([recording]) }
                                }
                                Divider()
                                Button("Delete", role: .destructive) { app.history.delete(item) }
                            }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .searchable(text: $query, placement: .toolbar, prompt: "Search dictations")
            }

            Divider()
            HStack {
                Toggle("Keep history", isOn: $prefs.saveHistory)
                    .toggleStyle(.checkbox)
                Toggle("Keep audio", isOn: $prefs.keepRecordings)
                    .toggleStyle(.checkbox)
                    .disabled(!prefs.saveHistory)
                    .help("Save the recording of every dictation so it can be transcribed again. Recordings that fail or are cancelled are always kept until you delete them.")
                Spacer()
                Button("Clear History…") { confirmClear = true }
                    .disabled(app.history.items.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .confirmationDialog("Clear all dictation history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { app.history.clear() }
        } message: {
            Text("Dictations and their recordings will be deleted. This can't be undone.")
        }
    }

    private var stats: some View {
        let words = app.history.totalWords
        let minutes = app.history.totalDuration / 60
        // Compared with typing at 40 words per minute.
        let saved = max(0, Double(words) / 40 - minutes)
        return HStack(spacing: 12) {
            StatTile(value: words.formatted(), label: "words dictated", symbol: "text.word.spacing")
            StatTile(value: minutes > 0 ? (Double(words) / minutes).formatted(.number.precision(.fractionLength(0))) : "–", label: "words per minute", symbol: "speedometer")
            StatTile(value: Duration.seconds(saved * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)), label: "saved vs. typing", symbol: "hourglass")
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct StatTile: View {
    let value: String
    let label: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.solidLabel.opacity(0.7))
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .surface(radius: 12)
    }
}

private struct HistoryRow: View {
    @Environment(AppModel.self) private var app
    let item: HistoryItem
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            appIcon
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 4) {
                if let failure = item.failure {
                    Label("\(failure) · \(Duration.seconds(item.duration).formatted(.time(pattern: .minuteSecond))) recording", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    Text(item.text)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
                HStack(spacing: 6) {
                    Text(item.date, format: .relative(presentation: .named))
                    if let app = item.appName { Text("· \(app)") }
                    if item.failure == nil { Text("· \(item.model.title)") }
                    if item.rawText != nil {
                        Image(systemName: "wand.and.sparkles")
                            .help("Formatted by S1-mini")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if item.failure != nil, item.recordingURL != nil {
                if app.dictation.retrying.contains(item.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Retry") { app.dictation.retry(item) }
                        .disabled(!app.dictation.canRetry)
                        .help("Transcribe this recording again with \(app.preferences.speechModel.title)")
                }
            } else if item.failure == nil {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.text, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .frame(width: 16)
                }
                .buttonStyle(.borderless)
                .opacity(hovering || copied ? 1 : 0)
                .help("Copy")
            }
        }
        .padding(.vertical, 4)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var appIcon: some View {
        if let id = item.appBundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
        } else {
            Image(systemName: "app.dashed")
                .foregroundStyle(.secondary)
        }
    }
}
