import SwiftUI

struct FormattingPane: View {
    @Environment(AppModel.self) private var app
    @State private var sample = "so um i need to like send the report by uh friday no wait make that thursday and cc sarah at kaze dot app"
    @State private var output = ""
    @State private var isRunning = false
    @State private var elapsed: TimeInterval?

    var body: some View {
        @Bindable var prefs = app.preferences
        SettingsPage {
            Section {
                FormatterHero()
            }

            Section {
                Picker("Style", selection: $prefs.formatStyle) {
                    ForEach(FormatStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                StylePreview(style: prefs.formatStyle)

                Toggle(isOn: $prefs.allowLists) {
                    Text("Turn spoken lists into bullet points")
                    Text("Only when you list three or more items.")
                }
                Toggle(isOn: $prefs.emailInMailApps) {
                    Text("Lay out emails in mail apps")
                    Text("Greeting, body and sign-off on separate lines in Mail, Outlook, Spark and others.")
                }
            } header: {
                Text("Style")
            }
            .disabled(!app.models.formatterState.isInstalled)

            if app.models.formatterState.isInstalled {
                Section("Try it") {
                    TextField("Try it", text: $sample, prompt: Text("Type something the way you'd say it"), axis: .vertical)
                        .labelsHidden()
                        .lineLimit(2...4)
                    HStack {
                        GlassCapsuleButton(title: isRunning ? "Cleaning up…" : "Clean Up", systemImage: "wand.and.sparkles", height: 30) {
                            Task { await run() }
                        }
                        .disabled(isRunning || sample.isEmpty)
                        if isRunning { ProgressView().controlSize(.small) }
                        Spacer()
                        if let elapsed {
                            Text("\(elapsed, format: .number.precision(.fractionLength(2)))s")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !output.isEmpty {
                        Text(output)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .surface(radius: 10)
                    }
                }
            }
        }
    }

    private func run() async {
        isRunning = true
        defer { isRunning = false }
        let started = Date()
        do {
            let prefs = app.preferences
            output = try await app.models.formatter.format(sample, style: prefs.formatStyle, allowLists: prefs.allowLists, context: .general)
            if output.isEmpty { output = "(nothing — S1-mini drops input that's only filler)" }
        } catch {
            output = error.localizedDescription
        }
        elapsed = Date().timeIntervalSince(started)
    }
}

/// Header card for S1-mini with its install state and on/off switch.
struct FormatterHero: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var prefs = app.preferences
        HStack(alignment: .top, spacing: 14) {
            LogoMark(image: Theme.superwhisperLogo, size: 18)
                .foregroundStyle(Color.solidLabel.opacity(0.85))
                .frame(width: 40, height: 40)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Clean Up")
                        .font(.headline)
                    Text("Runs on your Mac · \(FormatterModel.name) by \(FormatterModel.author)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("A small language model that rewrites what you said into clean text: removes \"um\"s and false starts, keeps your corrections (\"Friday — no, Thursday\" → Thursday), and writes numbers, dates, times and emails properly. Runs locally with MLX. English only.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var control: some View {
        @Bindable var prefs = app.preferences
        switch app.models.formatterState {
        case .installed:
            VStack(alignment: .trailing, spacing: 6) {
                Toggle("", isOn: $prefs.formattingEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                Menu {
                    Button("Delete Model", role: .destructive) { app.models.deleteFormatter() }
                } label: {
                    Text(app.models.diskUsageText(for: "formatter") ?? "Installed")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        case .preparing:
            ProgressView().controlSize(.small)
        default:
            VStack(alignment: .trailing, spacing: 4) {
                GlassProgressButton(
                    title: "Get · \(FormatterModel.downloadSize)",
                    systemImage: "arrow.down",
                    progress: { if case .downloading(let p) = app.models.formatterState { return p } else { return nil } }(),
                    width: 150,
                    start: { app.models.downloadFormatter() },
                    cancel: { app.models.cancelFormatterDownload() }
                )
                if case .failed(let message) = app.models.formatterState {
                    Text(message).font(.caption2).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: 150, alignment: .trailing)
                }
            }
        }
    }
}

struct StylePreview: View {
    let style: FormatStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "waveform")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text("hmm im gonna be late theres a cute dog outside i cant just walk past him")
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "text.cursor")
                    .foregroundStyle(Color.solidLabel)
                    .frame(width: 16)
                Text(style.example)
                    .contentTransition(.opacity)
                    .id(style)
                    .transition(.opacity)
            }
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(radius: 12)
        .animation(.easeInOut(duration: 0.2), value: style)
    }
}
