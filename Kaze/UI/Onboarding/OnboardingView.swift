import SwiftUI

struct OnboardingView: View {
    let onFinish: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: Step = Self.initialStep
    @State private var forward = true
    @Namespace private var glass

    enum Step: Int, CaseIterable {
        case welcome, permissions, model, cleanUp, shortcut, done
    }

    private static var initialStep: Step {
        #if DEBUG
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--onboarding-step"), index + 1 < args.count,
           let raw = Int(args[index + 1]), let step = Step(rawValue: raw) {
            return step
        }
        #endif
        return .welcome
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: WelcomeStep()
                case .permissions: PermissionsStep()
                case .model: ModelStep()
                case .cleanUp: CleanUpStep()
                case .shortcut: ShortcutStep()
                case .done: DoneStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 48)
            .padding(.top, 44)
            .id(step)
            .transition(.asymmetric(
                insertion: .pageSlide(x: forward ? 48 : -48),
                removal: .pageSlide(x: forward ? -48 : 48)
            ))

            footer
        }
        .frame(width: 680, height: 560)
        .background(.background)
        .onAppear { app.permissions.beginWatching() }
        .onDisappear { app.permissions.endWatching() }
    }

    private var footer: some View {
        HStack {
            PageDots(count: Step.allCases.count, index: step.rawValue)
            Spacer()
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 12) {
                    if step != .welcome && step != .done {
                        GlassIconButton(systemImage: "chevron.left", help: "Back", size: 34, morph: ("back", glass)) { go(-1) }
                    }
                    primaryButton
                }
            }
            .motion(value: step)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .frame(height: 76)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch step {
        case .welcome:
            GlassCapsuleButton(title: "Get Started", isProminent: true, morph: ("primary", glass)) { go(1) }
        case .permissions:
            GlassCapsuleButton(title: app.permissions.allGranted ? "Continue" : "Skip for Now", isProminent: app.permissions.allGranted, morph: ("primary", glass)) { go(1) }
        case .cleanUp:
            let skipping = !(app.preferences.formattingEnabled && app.models.isCleanUpReady(app.preferences.cleanUpEngine))
            GlassCapsuleButton(title: skipping ? "Not Now" : "Continue", isProminent: !skipping, morph: ("primary", glass)) { go(1) }
        case .done:
            GlassCapsuleButton(title: "Start Dictating", isProminent: true, morph: ("primary", glass)) { onFinish() }
        default:
            GlassCapsuleButton(title: "Continue", isProminent: true, morph: ("primary", glass)) { go(1) }
        }
    }

    private func go(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        forward = delta > 0
        withAnimation(reduceMotion ? nil : .kaze) { step = next }
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
                .animation(.kaze.delay(0.1)) { $0
                    .scaleEffect(appeared ? 1 : 0.85)
                    .opacity(appeared ? 1 : 0)
                }
            VStack(spacing: 10) {
                Text("Speak. Kaze types.")
                    .font(.system(size: 34, weight: .bold))
                Text("Hold a key in any app, say what you mean, and clean text appears where your cursor is.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            HStack(spacing: 12) {
                Feature(symbol: "lock.fill", title: "Private", detail: "Runs on your Mac")
                Feature(symbol: "bolt.fill", title: "Instant", detail: "Text in under a second")
                Feature(symbol: "macwindow.on.rectangle", title: "Everywhere", detail: "Works in every app")
            }
            .padding(.top, 8)
            Spacer(minLength: 0)
        }
        .onAppear { appeared = true }
    }
}

private struct Feature: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.solidLabel.opacity(0.85))
                .frame(height: 20)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 160, height: 96)
        .surface()
    }
}

private struct PermissionsStep: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            StepHeader(title: "Two quick permissions", subtitle: "Kaze needs to hear you, and to type into the app you're using. It only listens while you hold the shortcut.")
            VStack(spacing: 10) {
                PermissionCard(
                    symbol: "mic.fill",
                    title: "Microphone",
                    detail: "Listens only while you dictate.",
                    granted: app.permissions.microphone
                ) {
                    Task { await app.permissions.requestMicrophone() }
                }
                PermissionCard(
                    symbol: "accessibility",
                    title: "Accessibility",
                    detail: "Lets the shortcut work everywhere and pastes your text. Turn on Kaze in the list that opens.",
                    granted: app.permissions.accessibility
                ) {
                    AVPermissions.promptForAccessibility()
                    AVPermissions.openAccessibilitySettings()
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct PermissionCard: View {
    let symbol: String
    let title: String
    let detail: String
    let granted: Bool
    let request: () -> Void
    @Namespace private var glass

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.solidLabel.opacity(0.85))
                .frame(width: 38, height: 38)
                .glassEffect(.regular, in: .circle)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            GlassEffectContainer(spacing: 8) {
                if granted {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.solidBackground)
                        .frame(width: 34, height: 34)
                        .glassEffect(.regular.tint(.solidLabel), in: .circle)
                        .glassEffectID("control", in: glass)
                } else {
                    GlassCapsuleButton(title: "Allow", morph: ("control", glass), action: request)
                }
            }
        }
        .padding(16)
        .surface()
        .motion(value: granted)
    }
}

private struct ModelStep: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(title: "Pick a voice engine", subtitle: "All of them run on your Mac. You can switch or add more later in Settings.")
            VStack(spacing: 8) {
                ModelCard(model: .apple, isSelected: app.preferences.speechModel == .apple, badge: "No download", compact: true)
                ModelCard(model: .parakeetV2, isSelected: app.preferences.speechModel == .parakeetV2, badge: "Best for English", compact: true)
                ModelCard(model: .whisperLargeTurbo, isSelected: app.preferences.speechModel == .whisperLargeTurbo, badge: "99 languages", compact: true)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct CleanUpStep: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var prefs = app.preferences
        VStack(alignment: .leading, spacing: 20) {
            StepHeader(title: "Clean up as you go", subtitle: "Optional. Fillers, false starts and numbers, fixed on your Mac.")

            VStack(spacing: 22) {
                CleanUpDemo()

                GlassSegmentedPicker(
                    options: CleanUpEngine.allCases,
                    selection: $prefs.cleanUpEngine,
                    title: \.title,
                    height: 28
                )

                GlassEffectContainer(spacing: 8) {
                    engineControl
                }
                .motion(value: prefs.cleanUpEngine)
                .motion(value: app.models.formatterState.isInstalled)

                Text(creditLine)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity)

            Spacer(minLength: 0)
        }
    }
}

extension CleanUpStep {
    @ViewBuilder
    var engineControl: some View {
        @Bindable var prefs = app.preferences
        let onOff = GlassSegmentedPicker(options: [false, true], selection: $prefs.formattingEnabled, title: { $0 ? "On" : "Off" })
        switch prefs.cleanUpEngine {
        case .chatGPT:
            switch app.models.chatGPT.status {
            case .signedIn:
                onOff
            case .signingIn:
                GlassCapsuleButton(title: "Waiting for browser…", height: 34) { app.models.chatGPT.cancelSignIn() }
            case .signedOut, .failed:
                GlassCapsuleButton(title: "Sign in with ChatGPT", isProminent: true, height: 34) { app.models.chatGPT.signIn() }
            }
        case .s1Mini:
            switch app.models.formatterState {
            case .installed:
                onOff
            case .preparing, .checking:
                ProgressView().controlSize(.small)
            default:
                GlassProgressButton(
                    title: "Get S1-mini · \(FormatterModel.downloadSize)",
                    systemImage: "arrow.down",
                    progress: { if case .downloading(let p) = app.models.formatterState { return p } else { return nil } }(),
                    width: 220,
                    height: 34,
                    start: { app.models.downloadFormatter() },
                    cancel: { app.models.cancelFormatterDownload() }
                )
            }
        }
    }

    var creditLine: String {
        switch app.preferences.cleanUpEngine {
        case .chatGPT:
            if case .failed(let message) = app.models.chatGPT.status { return message }
            if let email = app.models.chatGPT.email, app.models.chatGPT.isSignedIn {
                return "Signed in as \(email) · Uses your ChatGPT plan · Transcripts go to OpenAI, not saved to your history"
            }
            return "Uses your ChatGPT plan · Transcripts go to OpenAI, not saved to your history"
        case .s1Mini:
            return "\(FormatterModel.name) by \(FormatterModel.author) · \(app.models.diskUsageText(for: "formatter") ?? FormatterModel.downloadSize) · Uses up to 1.5 GB of memory while cleaning · English"
        }
    }
}

/// Raw speech that blur-morphs into its cleaned-up version, on a loop.
private struct CleanUpDemo: View {
    private static let examples: [(String, String)] = [
        ("so um i need to send the report by uh friday no wait make that thursday", "I need to send the report by Thursday."),
        ("the invoice came to twenty three thousand four hundred and fifty dollars", "The invoice came to $23,450."),
        ("send it to support at kaze dot app", "Send it to support@kaze.app."),
        ("we need eggs and then milk and um bread", "We need:\n- Eggs\n- Milk\n- Bread"),
    ]

    @State private var index = 0
    @State private var cleaned = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let example = Self.examples[index]
        VStack(spacing: 10) {
            Image(systemName: cleaned ? "text.badge.checkmark" : "waveform")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(cleaned ? Color.solidLabel.opacity(0.85) : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
            Text(cleaned ? example.1 : example.0)
                .font(.system(size: 17, weight: cleaned ? .semibold : .regular))
                .foregroundStyle(cleaned ? Color.solidLabel : Color.secondary)
                .multilineTextAlignment(cleaned && example.1.contains("\n") ? .leading : .center)
                .id("\(index)-\(cleaned)")
                .transition(.blurReplace)
                .frame(maxWidth: 440, minHeight: 70)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .surface()
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(cleaned ? 2.6 : 1.8))
                withAnimation(reduceMotion ? nil : .kaze) {
                    if cleaned {
                        cleaned = false
                        index = (index + 1) % Self.examples.count
                    } else {
                        cleaned = true
                    }
                }
            }
        }
    }
}

private struct ShortcutStep: View {
    @Environment(AppModel.self) private var app
    @State private var practice = ""
    @FocusState private var practiceFocused: Bool

    var body: some View {
        @Bindable var prefs = app.preferences
        VStack(alignment: .leading, spacing: 20) {
            StepHeader(title: "Your shortcut", subtitle: "Hold it while you talk, or tap it once to keep listening hands-free.")

            VStack(spacing: 16) {
                ShortcutRecorderView(shortcut: prefs.shortcut, prominent: true) { app.setShortcut($0) }

                VStack(spacing: 8) {
                    GlassSegmentedPicker(
                        options: ActivationMode.allCases,
                        selection: $prefs.activationMode,
                        title: \.shortTitle,
                        symbol: \.symbol
                    )
                    Text(prefs.activationMode.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .id(prefs.activationMode)
                        .transition(.blurReplace)
                        .frame(height: 20)
                }
                .motion(value: prefs.activationMode)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .surface()

            if prefs.shortcut.usesFnKey {
                HStack(spacing: 10) {
                    Image(systemName: "globe")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("Set **Press 🌐 key to** → **Do Nothing** so macOS doesn't open the emoji picker when you let go of fn.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    GlassCapsuleButton(title: "Open Settings", height: 28) { AVPermissions.openKeyboardSettings() }
                }
                .transition(.blurReplace)
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $practice)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($practiceFocused)
                if practice.isEmpty {
                    Text(app.isShortcutActive ? "Try it: click here, hold \(prefs.shortcut.displayName) and say something…" : "The shortcut starts working once Accessibility is allowed.")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(12)
            .frame(height: 76)
            .surface()

            Spacer(minLength: 0)
        }
        .motion(value: prefs.shortcut.usesFnKey)
        .onAppear { practiceFocused = true }
    }
}

private struct DoneStep: View {
    @Environment(AppModel.self) private var app
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            Image(systemName: "checkmark")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Color.solidBackground)
                .frame(width: 72, height: 72)
                .glassEffect(.regular.tint(.solidLabel), in: .circle)
                .animation(.kaze.delay(0.1)) { $0
                    .scaleEffect(appeared ? 1 : 0.6)
                    .opacity(appeared ? 1 : 0)
                }
            Text("You're all set")
                .font(.system(size: 30, weight: .bold))
            HStack(spacing: 8) {
                Text("Hold")
                ShortcutCaps(shortcut: app.preferences.shortcut)
                Text("anywhere to dictate. Press esc to cancel.")
            }
            .foregroundStyle(.secondary)
            Text("Kaze lives in your menu bar. Open it any time to change models or settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
        }
        .onAppear { appeared = true }
    }
}

// MARK: - Chrome

private struct StepHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 26, weight: .bold))
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PageDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(Color.solidLabel.opacity(i == index ? 0.85 : 0.15))
                    .frame(width: i == index ? 18 : 6, height: 6)
            }
        }
        .motion(value: index)
    }
}

/// Pages move purely sideways while fading and softening; no scaling, so
/// nothing appears to grow from a corner.
private struct PageSlide: ViewModifier {
    let x: CGFloat
    let progress: CGFloat

    func body(content: Content) -> some View {
        content
            .offset(x: x * progress)
            .opacity(1 - progress)
            .blur(radius: 6 * progress)
    }
}

private extension AnyTransition {
    static func pageSlide(x: CGFloat) -> AnyTransition {
        .modifier(active: PageSlide(x: x, progress: 1), identity: PageSlide(x: x, progress: 0))
    }
}
