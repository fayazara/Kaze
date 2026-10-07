import AppKit
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
                Toggle(isOn: $prefs.formattingEnabled) {
                    Text("Clean up what I say")
                    Text("Removes fillers and false starts, keeps your corrections, and writes numbers, dates and emails properly.")
                }
                .disabled(!ready)
            }

            Section {
                ForEach(CleanUpEngine.allCases) { engine in
                    CleanUpEngineCard(engine: engine, isSelected: prefs.cleanUpEngine == engine)
                }
            } header: {
                Text("Model")
            }
            .motion(value: prefs.cleanUpEngine)

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
            .disabled(!ready)

            if ready {
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

    private var ready: Bool { app.models.isCleanUpReady(app.preferences.cleanUpEngine) }

    private func run() async {
        isRunning = true
        defer { isRunning = false }
        let started = Date()
        do {
            let prefs = app.preferences
            let cleaner = app.models.cleaner(for: prefs.cleanUpEngine)
            output = try await cleaner.format(sample, style: prefs.formatStyle, allowLists: prefs.allowLists, context: .general)
            if prefs.cleanUpEngine == .s1Mini { cleaner.unload() }
            if output.isEmpty { output = "(nothing; input that's only filler is dropped)" }
        } catch {
            output = error.localizedDescription
        }
        elapsed = Date().timeIntervalSince(started)
    }
}

/// One Clean Up model: logo, name, one quiet line of facts, and its control.
/// Settings that only apply to the selected model appear inside its row.
struct CleanUpEngineCard: View {
    let engine: CleanUpEngine
    var isSelected: Bool

    @Environment(AppModel.self) private var app
    @Namespace private var glass

    private var account: ChatGPTAccount { app.models.chatGPT }

    private var subtitle: String {
        switch engine {
        case .s1Mini:
            let size = app.models.formatterState.isInstalled
                ? "Up to 1.5 GB of memory while cleaning"
                : "\(FormatterModel.downloadSize) download"
            return "On your Mac · English only · \(size)"
        case .chatGPT:
            if case .failed(let message) = account.status { return message }
            if account.status == .signingIn { return "Finish signing in in your browser" }
            if account.isSignedIn, let email = account.email { return "\(email) · Sends transcripts to OpenAI" }
            return "Your ChatGPT plan · Sends transcripts to OpenAI"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                LogoMark(image: engine == .chatGPT ? Image("openai-icon") : Theme.superwhisperLogo, size: 16)
                    .foregroundStyle(Color.solidLabel.opacity(0.85))
                    .frame(width: 34, height: 34)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.title)
                        .font(.system(size: 13.5, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .contentTransition(.opacity)
                }
                // The text gets the width; controls only take what they need.
                .layoutPriority(1)

                Spacer(minLength: 12)

                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) { control }
                }
                .fixedSize()
                .motion(value: controlKey)
            }

            if engine == .chatGPT, isSelected, account.isSignedIn {
                modelPicker
                    .padding(.leading, 46)
                    .transition(.blurReplace)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { select() }
        .motion(value: isSelected)
        .contextMenu {
            if engine == .s1Mini, app.models.formatterState.isInstalled {
                Button("Delete Model", role: .destructive) { app.models.deleteFormatter() }
            }
            if engine == .chatGPT, account.isSignedIn {
                Button("Sign Out of ChatGPT", role: .destructive) { account.signOut() }
            }
        }
    }

    private var controlKey: String {
        "\(isSelected)-\(app.models.isCleanUpReady(engine))-\(app.models.formatterState.isDownloading)-\(account.status == .signingIn)"
    }

    @ViewBuilder
    private var control: some View {
        switch engine {
        case .chatGPT:
            switch account.status {
            case .signedIn:
                accountMenu
                selectionControl
            case .signingIn:
                ProgressView().controlSize(.small)
                GlassCapsuleButton(title: "Cancel", height: 28, morph: ("control", glass)) { account.cancelSignIn() }
            case .signedOut, .failed:
                GlassCapsuleButton(title: "Sign In", height: 28, morph: ("control", glass)) { select() }
            }
        case .s1Mini:
            switch app.models.formatterState {
            case .installed:
                selectionControl
            case .checking, .preparing:
                ProgressView().controlSize(.small)
            default:
                GlassProgressButton(
                    title: "Get",
                    systemImage: "arrow.down",
                    progress: { if case .downloading(let p) = app.models.formatterState { return p } else { return nil } }(),
                    width: 96,
                    height: 28,
                    morph: ("control", glass),
                    start: { select() },
                    cancel: { app.models.cancelFormatterDownload() }
                )
            }
        }
    }

    @ViewBuilder
    private var selectionControl: some View {
        if isSelected {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.solidBackground)
                .frame(width: 28, height: 28)
                .glassEffect(.regular.tint(.solidLabel), in: .circle)
                .glassEffectID("control", in: glass)
                .help("In use")
        } else {
            GlassCapsuleButton(title: "Use", height: 28, morph: ("control", glass)) { select() }
        }
    }

    /// Account actions, kept out of the way.
    private var accountMenu: some View {
        Menu {
            Button("Sign Out", role: .destructive) { account.signOut() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.solidLabel.opacity(0.8))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .glassEffectID("account", in: glass)
        .fixedSize()
        .help("ChatGPT account")
    }

    private var modelPicker: some View {
        @Bindable var prefs = app.preferences
        return HStack(spacing: 6) {
            Text("Model")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Picker("Model", selection: $prefs.chatGPTModel) {
                Text("Automatic" + (account.resolvedModel(preferred: nil).map { " (\($0.displayName))" } ?? "")).tag(String?.none)
                if !account.models.isEmpty { Divider() }
                ForEach(account.models) { model in
                    Text(model.displayName).tag(String?.some(model.slug))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()

            if let model = account.resolvedModel(preferred: prefs.chatGPTModel), model.reasoningLevels.count > 1 {
                Text("Thinking")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10)
                Picker("Thinking", selection: $prefs.chatGPTReasoning) {
                    Text("Lowest").tag(String?.none)
                    Divider()
                    ForEach(model.reasoningLevels, id: \.self) { level in
                        Text(Self.levelName(level)).tag(String?.some(level))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                .help("Clean Up is simple work; the lowest level is fastest and uses the least of your plan.")
            }
        }
    }

    private static func levelName(_ effort: String) -> String {
        switch effort {
        case "xhigh": "Extra High"
        default: effort.prefix(1).uppercased() + effort.dropFirst()
        }
    }

    private func select() {
        app.preferences.cleanUpEngine = engine
        switch engine {
        case .chatGPT:
            if account.isSignedIn {
                app.preferences.formattingEnabled = true
            } else if account.status != .signingIn {
                account.signIn()   // turns Clean Up on when done
            }
        case .s1Mini:
            if app.models.formatterState.isInstalled {
                app.preferences.formattingEnabled = true
            } else if !app.models.formatterState.isDownloading {
                app.models.downloadFormatter()   // turns Clean Up on when done
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
