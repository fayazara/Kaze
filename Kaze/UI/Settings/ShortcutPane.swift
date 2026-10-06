import SwiftUI

struct ShortcutPane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var prefs = app.preferences
        SettingsPage {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Dictation shortcut")
                        Text("Works in every app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    ShortcutRecorderView(shortcut: prefs.shortcut) { app.setShortcut($0) }
                }
                HStack {
                    Text("Popular")
                        .foregroundStyle(.secondary)
                    Spacer()
                    GlassSegmentedPicker(
                        options: Shortcut.suggestions,
                        selection: Binding(get: { prefs.shortcut }, set: { app.setShortcut($0) }),
                        title: \.displayName,
                        height: 28
                    )
                }
                if !app.permissions.accessibility {
                    Label("The shortcut needs Accessibility permission. Allow it in General.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }

            if prefs.shortcut.usesFnKey {
                Section {
                    FnKeyTip()
                }
            }

            Section {
                ForEach(ActivationMode.allCases) { mode in
                    ActivationModeRow(mode: mode, isSelected: prefs.activationMode == mode) {
                        prefs.activationMode = mode
                    }
                }
            } header: {
                Text("How it works")
            } footer: {
                Label("Press esc at any time to cancel a dictation.", systemImage: "escape")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ActivationModeRow: View {
    let mode: ActivationMode
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.solidLabel : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .font(.system(size: 14))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(mode.title)
                        if mode == .automatic { Tag(text: "Recommended") }
                    }
                    Text(mode.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// macOS runs its own action (emoji picker, Dictation, input source) when the
/// Globe/fn key is released on its own, which steals focus from the paste.
struct FnKeyTip: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "globe")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.solidLabel.opacity(0.8))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 6) {
                Text("Set the fn key to do nothing")
                    .font(.callout.weight(.semibold))
                Text("In Keyboard settings, set **Press 🌐 key to** → **Do Nothing**. Otherwise macOS opens the emoji picker or Apple Dictation each time you let go of fn, which can swallow your text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Keyboard Settings") { AVPermissions.openKeyboardSettings() }
                    .controlSize(.small)
            }
        }
    }
}
