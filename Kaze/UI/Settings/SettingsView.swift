import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, shortcut, models, formatting, vocabulary, history, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .shortcut: "Shortcut"
        case .models: "Speech Models"
        case .formatting: "Clean Up"
        case .vocabulary: "Vocabulary"
        case .history: "History"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .shortcut: "keyboard.fill"
        case .models: "waveform"
        case .formatting: "wand.and.sparkles"
        case .vocabulary: "character.book.closed.fill"
        case .history: "clock.fill"
        case .about: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .shortcut: .blue
        case .models: .purple
        case .formatting: .pink
        case .vocabulary: .orange
        case .history: .green
        case .about: .secondary
        }
    }
}

@Observable
final class SettingsNavigation {
    var selection: SettingsPane = .general
}

struct SettingsView: View {
    @Bindable var navigation: SettingsNavigation
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { navigation.selection }, set: { if let value = $0 { navigation.selection = value } })) {
                ForEach(SettingsPane.allCases) { pane in
                    row(pane)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
            .safeAreaInset(edge: .bottom) { statusFooter }
        } detail: {
            detail
                .navigationTitle(navigation.selection.title)
        }
        .onAppear { app.permissions.beginWatching() }
        .onDisappear { app.permissions.endWatching() }
    }

    private func row(_ pane: SettingsPane) -> some View {
        Label {
            Text(pane.title)
        } icon: {
            // Symbols have different natural widths; a fixed slot keeps every
            // title on the same leading edge.
            Image(systemName: pane.symbol)
                .frame(width: 20, alignment: .center)
        }
        .tag(pane)
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.selection {
        case .general: GeneralPane()
        case .shortcut: ShortcutPane()
        case .models: ModelsPane()
        case .formatting: FormattingPane()
        case .vocabulary: VocabularyPane()
        case .history: HistoryPane()
        case .about: AboutPane()
        }
    }

    /// Always-visible readiness summary at the bottom of the sidebar.
    private var statusFooter: some View {
        let ready = app.permissions.allGranted && app.models.state(of: app.preferences.speechModel).isInstalled
        return HStack(spacing: 8) {
            Circle()
                .fill(ready ? Color.solidLabel.opacity(0.7) : Color.orange)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(ready ? "Ready" : "Needs attention")
                    .font(.system(size: 11.5, weight: .semibold))
                Text(ready ? "\(app.preferences.shortcut.displayName) · \(app.preferences.speechModel.title)" : readinessHint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var readinessHint: String {
        if !app.permissions.microphone { return "Allow microphone access" }
        if !app.permissions.accessibility { return "Allow Accessibility" }
        return "Download \(app.preferences.speechModel.title)"
    }
}

/// Consistent page scaffold: grouped form, standard insets.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
    }
}
