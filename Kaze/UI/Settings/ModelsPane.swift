import SwiftUI

struct ModelsPane: View {
    @Environment(AppModel.self) private var app
    @State private var languages: [Locale] = []

    private var groups: [(String, [SpeechModel])] {
        [
            ("Built in", [.apple]),
            ("NVIDIA Parakeet", [.parakeetV2, .parakeetV3]),
            ("OpenAI Whisper", [.whisperSmallEnglish, .whisperBase, .whisperLargeTurbo]),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                ForEach(groups, id: \.0) { title, models in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        ForEach(models) { model in
                            ModelCard(
                                model: model,
                                isSelected: app.preferences.speechModel == model,
                                badge: model == .parakeetV2 ? "Best for English" : nil
                            )
                        }
                    }
                }

                languageSection

                Label("Every model runs entirely on your Mac. Your voice never leaves it.", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .task {
            app.models.refresh()
            languages = await AppleSpeechEngine.supportedLanguages()
                .sorted { ($0.localizedString(forIdentifier: $0.identifier) ?? "") < ($1.localizedString(forIdentifier: $1.identifier) ?? "") }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Choose how Kaze hears you")
                .font(.title2.weight(.semibold))
            Text("Apple Speech works instantly and shows words as you speak. Parakeet is the fastest and most accurate for English. Whisper covers the most languages.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var languageSection: some View {
        let model = app.preferences.speechModel
        VStack(alignment: .leading, spacing: 8) {
            Text("Language")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            HStack {
                if model.isEnglishOnly {
                    Text("\(model.title) transcribes English only.")
                        .foregroundStyle(.secondary)
                } else if model.family == .parakeet {
                    Text("Parakeet v3 detects the language automatically.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Spoken language", selection: Binding(get: { app.preferences.language }, set: { app.setLanguage($0) })) {
                        Text("Automatic (\(Locale.current.localizedString(forLanguageCode: Locale.current.language.languageCode?.identifier ?? "en") ?? "System"))")
                            .tag(String?.none)
                        Divider()
                        ForEach(languages, id: \.identifier) { locale in
                            Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                                .tag(String?.some(locale.identifier))
                        }
                    }
                    .frame(maxWidth: 360)
                }
                Spacer()
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.secondary))
        }
    }
}
