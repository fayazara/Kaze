import SwiftUI

struct VoiceEditsPane: View {
    @Environment(AppModel.self) private var app
    @Environment(SettingsNavigation.self) private var navigation

    var body: some View {
        let prefs = app.preferences
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VoiceEditDemo()

                PaneGroup("Shortcut") {
                    shortcutCard
                }

                if prefs.editShortcut != nil {
                    PaneGroup("Model") {
                        modelCard
                    }
                    .transition(.blurReplace)
                }
            }
            .padding(24)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .motion(value: prefs.editShortcut)
    }

    private var shortcutCard: some View {
        let prefs = app.preferences
        return HStack(spacing: 12) {
            if let shortcut = prefs.editShortcut {
                ShortcutRecorderView(shortcut: shortcut) { app.setEditShortcut($0) }
                Spacer()
                GlassCapsuleButton(title: "Turn Off", height: 28) { app.setEditShortcut(nil) }
            } else {
                Text("Off")
                    .foregroundStyle(.secondary)
                Spacer()
                GlassCapsuleButton(title: "Turn On", isProminent: true, height: 28) {
                    app.setEditShortcut(.suggestedEdit(avoiding: prefs.shortcut))
                }
            }
        }
        .padding(14)
        .surface()
    }

    @ViewBuilder
    private var modelCard: some View {
        @Bindable var prefs = app.preferences
        let engines = CleanUpEngine.allCases.filter { $0.isCloud && app.models.isCleanUpReady($0) }
        if engines.isEmpty {
            HStack(spacing: 12) {
                Image(systemName: "cloud")
                    .foregroundStyle(.secondary)
                Text("Needs ChatGPT, Claude or Gemini")
                Spacer()
                GlassCapsuleButton(title: "Set Up", height: 28) { navigation.selection = .formatting }
            }
            .padding(14)
            .surface()
        } else {
            let automatic = app.models.voiceEditEngine(preferred: nil, cleanUp: prefs.cleanUpEngine)
            GlassSegmentedPicker(
                options: [CleanUpEngine?.none] + engines.map(Optional.some),
                selection: $prefs.editEngine,
                title: { $0?.title ?? "Auto" + (automatic.map { " · \($0.title)" } ?? "") },
                height: 30
            )
        }
    }
}

/// Selected text, a spoken instruction, and the rewrite, on a loop.
private struct VoiceEditDemo: View {
    private static let examples: [(text: String, instruction: String, result: String)] = [
        ("Send me the report by Thursday.", "make it friendlier", "Could you send me the report by Thursday? Thanks so much!"),
        ("Can we move the meeting to 3pm?", "translate to Spanish", "¿Podemos mover la reunión a las 3 p. m.?"),
        ("We need eggs, milk, bread and coffee.", "make this a list", "- Eggs\n- Milk\n- Bread\n- Coffee"),
    ]

    private enum Stage { case selected, speaking, done }

    @State private var index = 0
    @State private var stage = Stage.selected
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let example = Self.examples[index]
        VStack(spacing: 14) {
            ZStack {
                // Every example, invisible, so the card keeps one height.
                ForEach(Self.examples.indices, id: \.self) { i in
                    line(i, done: false).hidden()
                    line(i, done: true).hidden()
                }
                line(index, done: stage == .done)
                    .id("\(index)-\(stage == .done)")
                    .transition(.blurReplace)
            }

            HStack(spacing: 6) {
                Image(systemName: stage == .done ? "checkmark" : "waveform")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 14, height: 14)
                Text("“\(example.instruction)”")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.solidLabel.opacity(0.85))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .glassEffect(.regular, in: .capsule)
            .opacity(stage == .selected ? 0 : 1)
            .scaleEffect(stage == .selected ? 0.9 : 1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .surface()
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(stage == .done ? 2.6 : 1.3))
                withAnimation(reduceMotion ? nil : .kaze) {
                    switch stage {
                    case .selected: stage = .speaking
                    case .speaking: stage = .done
                    case .done:
                        stage = .selected
                        index = (index + 1) % Self.examples.count
                    }
                }
            }
        }
    }

    private func line(_ index: Int, done: Bool) -> some View {
        let example = Self.examples[index]
        let text = done ? example.result : example.text
        return Text(text)
            .font(.system(size: 16, weight: done ? .semibold : .regular))
            .foregroundStyle(Color.solidLabel)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                // The selection highlight, until the edit lands.
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.accentColor.opacity(done ? 0 : 0.25))
            }
            .multilineTextAlignment(text.contains("\n") ? .leading : .center)
            .fixedSize(horizontal: false, vertical: true)
    }
}
