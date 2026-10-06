import AVFoundation
import SwiftUI

struct GeneralPane: View {
    @Environment(AppModel.self) private var app
    @State private var devices = AudioInputDevice.all()
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        @Bindable var prefs = app.preferences
        SettingsPage {
            Section {
                PermissionRow(
                    title: "Microphone",
                    detail: "To hear you while you dictate.",
                    symbol: "mic.fill",
                    granted: app.permissions.microphone,
                    action: { Task { await app.permissions.requestMicrophone() } }
                )
                PermissionRow(
                    title: "Accessibility",
                    detail: "For the global shortcut and to paste into other apps.",
                    symbol: "accessibility",
                    granted: app.permissions.accessibility,
                    action: {
                        AVPermissions.promptForAccessibility()
                        AVPermissions.openAccessibilitySettings()
                    }
                )
            } header: {
                Text("Permissions")
            }

            Section("Microphone") {
                Picker("Input", selection: $prefs.microphoneID) {
                    Text("System Default" + (AudioInputDevice.defaultDeviceName.map { " (\($0))" } ?? ""))
                        .tag(String?.none)
                    if !devices.isEmpty { Divider() }
                    ForEach(devices) { device in
                        Text(device.name).tag(String?.some(device.id))
                    }
                }
            }

            Section {
                Toggle("Restore clipboard after pasting", isOn: $prefs.restoreClipboard)
                Toggle("Add a space after each dictation", isOn: $prefs.addTrailingSpace)
            } header: {
                Text("Pasting")
            } footer: {
                Text("Kaze pastes through the clipboard, then puts back whatever you had copied.")
            }

            Section("Feedback") {
                Toggle("Play sounds", isOn: $prefs.playSounds)
                Toggle(isOn: $prefs.showLivePreview) {
                    Text("Show words live in the notch")
                    Text("Available with Apple Speech, which transcribes as you speak.")
                }
            }

            Section("System") {
                Toggle("Open Kaze at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in LoginItem.set(enabled) }
                LabeledContent("Setup") {
                    Button("Run Setup Again…") { WindowManager.shared.showOnboarding() }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in devices = AudioInputDevice.all() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in devices = AudioInputDevice.all() }
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let symbol: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(granted ? Color.solidLabel.opacity(0.8) : Color.orange)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("Allowed", systemImage: "checkmark")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                GlassCapsuleButton(title: "Allow", height: 28, action: action)
            }
        }
        .animation(.easeOut, value: granted)
    }
}
