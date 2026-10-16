import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FormattingPane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var prefs = app.preferences
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero

                PaneGroup("Model") {
                    VStack(spacing: 8) {
                        ForEach(CleanUpEngine.allCases) { engine in
                            CleanUpEngineCard(engine: engine, isSelected: prefs.cleanUpEngine == engine)
                        }
                    }
                    .motion(value: prefs.cleanUpEngine)
                }

                PaneGroup("Style") {
                    VStack(alignment: .leading, spacing: 12) {
                        GlassSegmentedPicker(options: FormatStyle.allCases, selection: $prefs.formatStyle, title: \.title, height: 30)
                        StylePreview(style: prefs.formatStyle)
                        HStack(spacing: 8) {
                            GlassToggleChip(title: "Bullet lists", systemImage: "list.bullet", isOn: $prefs.allowLists)
                                .help("Turns three or more spoken items into a bulleted list")
                            GlassToggleChip(title: "Email layout", systemImage: "envelope", isOn: $prefs.emailInMailApps)
                                .help("Greeting, body and sign-off on separate lines in mail apps")
                        }
                    }
                    .padding(14)
                    .surface()
                }
                .disabled(!ready)

                PaneGroup("Per app") {
                    AppStylesGrid()
                }
                .disabled(!ready)

                if ready {
                    PaneGroup("Try it") {
                        TryCleanUp()
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
    }

    /// The switch, with a live before → after instead of a description.
    private var hero: some View {
        @Bindable var prefs = app.preferences
        return VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clean up what I say")
                        .font(.system(size: 15, weight: .semibold))
                    if !ready {
                        Text("Pick a model below")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .transition(.blurReplace)
                    }
                }
                Spacer()
                Toggle("Clean up what I say", isOn: $prefs.formattingEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!ready)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            CleanUpDemo(framed: false)
                .opacity(prefs.formattingEnabled && ready ? 1 : 0.45)
        }
        .surface()
        .motion(value: ready)
    }

    private var ready: Bool { app.models.isCleanUpReady(app.preferences.cleanUpEngine) }
}

/// A titled block of the page, in the Speech Models layout.
struct PaneGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content
        }
    }
}

/// An on/off capsule with an icon, inked solid when on.
struct GlassToggleChip: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "checkmark" : systemImage)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 14)
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isOn ? Color.solidBackground : Color.solidLabel.opacity(0.8))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(isOn ? .regular.tint(.solidLabel).interactive() : .regular.interactive(), in: .capsule)
        .opacity(isEnabled ? 1 : 0.5)
        .motion(.kazeQuick, value: isOn)
    }
}

/// Type something the way you'd say it and run it through the current model.
private struct TryCleanUp: View {
    @Environment(AppModel.self) private var app
    @State private var sample = "so um i need to like send the report by uh friday no wait make that thursday and cc sarah at kaze dot app"
    @State private var output = ""
    @State private var isRunning = false
    @State private var elapsed: TimeInterval?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Try it", text: $sample, prompt: Text("Type something the way you'd say it"), axis: .vertical)
                .textFieldStyle(.plain)
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
                    .transition(.blurReplace)
            }
        }
        .padding(14)
        .surface()
        .motion(value: output)
    }

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
    @State private var hovering = false
    @Namespace private var glass

    private var account: ChatGPTAccount { app.models.chatGPT }
    private var keyAccount: APIKeyAccount? { app.models.keyAccount(for: engine) }

    private var logo: Image {
        switch engine {
        case .instant: Image(systemName: "bolt.fill")
        case .s1Mini: Theme.superwhisperLogo
        case .chatGPT: Image("openai-icon")
        case .claude: Image("anthropic-icon")
        case .gemini: Image("gemini-icon")
        }
    }

    /// Only what needs attention right now; everything else is in the facts row.
    private var status: String? {
        switch engine {
        case .instant, .s1Mini:
            return nil
        case .chatGPT:
            if case .failed(let message) = account.status { return message }
            if account.status == .signingIn { return "Finish signing in in your browser" }
            return nil
        case .claude, .gemini:
            if let error = keyAccount?.error { return error }
            if keyAccount?.isVerifying == true { return "Checking your key…" }
            return nil
        }
    }

    /// Speed and quality for the model this engine would use.
    private var ratings: (speed: Int, quality: Int) {
        switch engine {
        case .instant: return (5, 2)
        case .s1Mini: return (5, 4)
        case .chatGPT: return (3, 5)
        case .claude:
            let id = KeyProvider.anthropic.resolvedModel(preferred: app.preferences.claudeModel).id
            return id.contains("haiku") ? (5, 4) : id.contains("sonnet") ? (4, 5) : (3, 5)
        case .gemini:
            let id = KeyProvider.google.resolvedModel(preferred: app.preferences.geminiModel).id
            return id.contains("lite") ? (5, 4) : (4, 5)
        }
    }

    private var facts: some View {
        HStack(spacing: 14) {
            RatingDots(label: "Speed", value: ratings.speed)
            RatingDots(label: "Quality", value: ratings.quality)
            Label(engine.isCloud ? "Cloud" : "On your Mac", systemImage: engine.isCloud ? "cloud" : "lock")
                .help(engine.isCloud ? "Transcripts are sent to \(engine.vendor)" : "Nothing leaves your Mac")
            Label(engine == .s1Mini || engine == .instant ? "English" : "Any language", systemImage: "globe")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                LogoMark(image: logo, size: 16)
                    .foregroundStyle(Color.solidLabel.opacity(0.85))
                    .frame(width: 34, height: 34)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(engine.title)
                            .font(.system(size: 13.5, weight: .semibold))
                        Text(engine.vendor)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if let status {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .transition(.blurReplace)
                    } else {
                        facts.transition(.blurReplace)
                    }
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
            if let keyAccount, isSelected {
                Group {
                    if keyAccount.hasKey {
                        CloudModelPicker(provider: keyAccount.provider, selection: modelSelection)
                    } else {
                        APIKeyField(account: keyAccount, engine: engine)
                    }
                }
                .padding(.leading, 46)
                .transition(.blurReplace)
            }
        }
        .padding(14)
        .surface(selected: isSelected || hovering)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.solidLabel.opacity(isSelected ? 0.55 : 0), lineWidth: 1.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onHover { hovering = $0 }
        .onTapGesture { select() }
        .motion(value: isSelected)
        .motion(.kazeQuick, value: hovering)
        .motion(value: status)
        .contextMenu {
            if engine == .s1Mini, app.models.formatterState.isInstalled {
                Button("Delete Model", role: .destructive) { app.models.deleteFormatter() }
            }
            if engine == .chatGPT, account.isSignedIn {
                Button("Sign Out of ChatGPT", role: .destructive) { account.signOut() }
            }
            if let keyAccount, keyAccount.hasKey {
                Button("Remove \(keyAccount.provider.name) API Key", role: .destructive) { keyAccount.removeKey() }
            }
        }
    }

    private var controlKey: String {
        "\(isSelected)-\(app.models.isCleanUpReady(engine))-\(app.models.formatterState.isDownloading)-\(account.status == .signingIn)-\(keyAccount?.hasKey ?? false)"
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
        case .claude, .gemini:
            if let keyAccount, keyAccount.hasKey {
                keyMenu(keyAccount)
                selectionControl
            } else if isSelected {
                // The key field is open below.
                EmptyView()
            } else {
                GlassCapsuleButton(title: "Add Key", height: 28, morph: ("control", glass)) { select() }
            }
        case .instant:
            selectionControl
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
            if let email = account.email { Text(email) }
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

    /// Key actions, kept out of the way.
    private func keyMenu(_ keyAccount: APIKeyAccount) -> some View {
        Menu {
            Link("Manage Keys…", destination: keyAccount.provider.consoleURL)
            Divider()
            Button("Remove Key", role: .destructive) { keyAccount.removeKey() }
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
        .help("\(keyAccount.provider.name) API key")
    }

    private var modelSelection: Binding<String?> {
        @Bindable var prefs = app.preferences
        return engine == .gemini ? $prefs.geminiModel : $prefs.claudeModel
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
        case .claude, .gemini:
            // Without a key, selecting opens the key field.
            if keyAccount?.hasKey == true { app.preferences.formattingEnabled = true }
        case .instant:
            app.preferences.formattingEnabled = true
        case .s1Mini:
            if app.models.formatterState.isInstalled {
                app.preferences.formattingEnabled = true
            } else if !app.models.formatterState.isDownloading {
                app.models.downloadFormatter()   // turns Clean Up on when done
            }
        }
    }
}

/// Apps with their own style, as a grid of icon tiles.
struct AppStylesGrid: View {
    @Environment(AppModel.self) private var app

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 8)]

    var body: some View {
        let rules = app.preferences.appStyles
        let suggestions = AppStyleSuggestions.available(excluding: rules)
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(rules) { rule in
                AppStyleTile(rule: rule)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
            if !suggestions.isEmpty {
                SuggestedAppsTile(suggestions: suggestions) {
                    app.preferences.appStyles.append(contentsOf: suggestions)
                }
            }
            AddAppTile(taken: Set(rules.map(\.bundleID))) { bundleID, name in
                guard !app.preferences.appStyles.contains(where: { $0.bundleID == bundleID }) else { return }
                app.preferences.appStyles.append(AppStyleRule(bundleID: bundleID, name: name, style: AppStyle(app.preferences.formatStyle)))
            }
        }
        .motion(value: rules)
    }
}

private struct AppStyleTile: View {
    let rule: AppStyleRule
    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(image: rule.icon, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(rule.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Menu {
                    Picker(rule.name, selection: style) {
                        ForEach(AppStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    HStack(spacing: 3) {
                        Text(rule.style.title)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .surface(selected: hovering, radius: 12)
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button {
                    app.preferences.appStyles.removeAll { $0.bundleID == rule.bundleID }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 18, height: 18)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .padding(5)
                .help("Use the default style in \(rule.name)")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .onHover { hovering = $0 }
        .motion(.kazeQuick, value: hovering)
    }

    private var style: Binding<AppStyle> {
        Binding {
            rule.style
        } set: { new in
            guard let index = app.preferences.appStyles.firstIndex(where: { $0.bundleID == rule.bundleID }) else { return }
            app.preferences.appStyles[index].style = new
        }
    }
}

/// One click to add styles for the well-known apps on this Mac.
private struct SuggestedAppsTile: View {
    let suggestions: [AppStyleRule]
    let add: () -> Void

    var body: some View {
        Button(action: add) {
            HStack(spacing: 10) {
                HStack(spacing: -10) {
                    ForEach(suggestions.prefix(3)) { AppIcon(image: $0.icon, size: 24) }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add suggested")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("\(suggestions.count) apps")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .surface(radius: 12)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help(suggestions.map { "\($0.name): \($0.style.title)" }.joined(separator: "\n"))
    }
}

/// Adds an open app, or any app picked from disk.
private struct AddAppTile: View {
    let taken: Set<String>
    let add: (_ bundleID: String, _ name: String) -> Void

    var body: some View {
        Menu {
            let running = runningApps
            if !running.isEmpty {
                Section("Open Apps") {
                    ForEach(running, id: \.bundleID) { candidate in
                        Button(candidate.name) { add(candidate.bundleID, candidate.name) }
                    }
                }
                Divider()
            }
            Button("Choose App…", action: chooseApp)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text("Add app")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.solidLabel.opacity(0.8))
            .padding(10)
            .frame(maxWidth: .infinity)
            .surface(radius: 12)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
    }

    private var runningApps: [(bundleID: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { running in
                guard let id = running.bundleIdentifier, id != Bundle.main.bundleIdentifier, !taken.contains(id) else { return nil }
                return (id, running.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        add(id, AppStyleSuggestions.appName(at: url))
    }
}

private struct AppIcon: View {
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable()
            } else {
                Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Paste-in field for a provider API key, verified before it's saved.
struct APIKeyField: View {
    let account: APIKeyAccount
    let engine: CleanUpEngine
    var height: CGFloat = 26
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 8) {
            SecureField("API key", text: $draft, prompt: Text(account.provider.keyPlaceholder))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            if account.isVerifying {
                ProgressView().controlSize(.small)
            } else {
                GlassCapsuleButton(title: "Save", height: height, action: save)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Link("Get a key", destination: account.provider.consoleURL)
                .font(.system(size: 12))
                .fixedSize()
        }
    }

    private func save() {
        account.save(draft, turnOnFor: engine)
    }
}

/// Picks among a key provider's models; `nil` means the lightest.
struct CloudModelPicker: View {
    let provider: KeyProvider
    @Binding var selection: String?

    var body: some View {
        HStack(spacing: 6) {
            Text("Model")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Picker("Model", selection: $selection) {
                Text("Automatic (\(provider.models[0].name))").tag(String?.none)
                Divider()
                ForEach(provider.models) { model in
                    Text("\(model.name) · \(model.note)").tag(String?.some(model.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
            .help("Clean Up is simple work; the lightest model is fastest and cheapest.")
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
