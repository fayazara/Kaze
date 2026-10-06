import AppKit
import SwiftUI

struct AboutPane: View {
    @Environment(AppModel.self) private var app

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        SettingsPage {
            Section {
                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 88, height: 88)
                    Text("Kaze")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text(version)
                        .foregroundStyle(.secondary)
                    Text("Private, on-device dictation for your Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        Link("GitHub", destination: URL(string: "https://github.com/fayazara/Kaze")!)
                        Text("·").foregroundStyle(.tertiary)
                        Link("Releases", destination: URL(string: "https://github.com/fayazara/Kaze/releases")!)
                    }
                    .font(.callout)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }

            Section("Updates") {
                if app.updater.isAvailable {
                    Toggle("Check for updates automatically", isOn: Binding(get: { app.updater.automaticallyChecks }, set: { app.updater.automaticallyChecks = $0 }))
                    Button("Check for Updates…") { app.updater.checkForUpdates() }
                } else {
                    Text("Updates are disabled in development builds.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Built with") {
                Credit(name: "Parakeet TDT", detail: "NVIDIA, run with FluidAudio on Core ML")
                Credit(name: "Whisper", detail: "OpenAI, run with WhisperKit by Argmax")
                Credit(name: "SpeechAnalyzer", detail: "Apple, built into macOS")
                Credit(name: "\(FormatterModel.name)", detail: "by \(FormatterModel.author), run with MLX. Apache 2.0 with naming clause.")
                Credit(name: "Sparkle", detail: "Software updates")
            }
        }
    }
}

private struct Credit: View {
    let name: String
    let detail: String

    var body: some View {
        LabeledContent(name) {
            Text(detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}
