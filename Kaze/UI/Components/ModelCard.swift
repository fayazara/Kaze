import SwiftUI

/// A selectable card for one speech model, with its download/manage control.
struct ModelCard: View {
    let model: SpeechModel
    var isSelected: Bool
    var badge: String? = nil
    var compact = false

    @Environment(AppModel.self) private var app
    @State private var hovering = false
    @Namespace private var glass

    private var state: InstallState { app.models.state(of: model) }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ModelGlyph(family: model.family, size: compact ? 30 : 36)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.title)
                        .font(.system(size: 13.5, weight: .semibold))
                    Text(model.family.vendor)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if let badge { Tag(text: badge) }
                }
                Text(model.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !compact {
                    HStack(spacing: 14) {
                        RatingDots(label: "Speed", value: model.speedRating)
                        RatingDots(label: "Accuracy", value: model.accuracyRating)
                        Label(model.languages, systemImage: "globe")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .padding(.top, 3)
                }
            }

            Spacer(minLength: 8)

            GlassEffectContainer(spacing: 8) {
                trailingControl
            }
            .motion(value: stateKey)
        }
        .padding(compact ? 12 : 14)
        .surface(selected: isSelected || hovering)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.solidLabel.opacity(isSelected ? 0.55 : 0), lineWidth: 1.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onHover { hovering = $0 }
        .onTapGesture { select() }
        .contextMenu {
            if state.isInstalled, model.requiresDownload {
                Button("Delete Model", role: .destructive) { app.models.delete(model) }
            }
        }
        .motion(.kazeQuick, value: isSelected)
        .motion(.kazeQuick, value: hovering)
    }

    /// Coarse state used to drive the morph between controls.
    private var stateKey: String {
        switch state {
        case .downloading: "downloading"
        case .installed: isSelected ? "inUse" : "installed"
        default: String(describing: state)
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch state {
        case .checking:
            ProgressView().controlSize(.small)
        case .notInstalled, .downloading, .failed:
            VStack(alignment: .trailing, spacing: 4) {
                GlassProgressButton(
                    title: model.downloadSize.map { "Get · \($0)" } ?? "Get",
                    systemImage: "arrow.down",
                    progress: { if case .downloading(let p) = state { return p } else { return nil } }(),
                    width: 140,
                    morph: ("control", glass),
                    start: { app.selectSpeechModel(model) },
                    cancel: { app.models.cancelDownload(model) }
                )
                if case .failed(let message) = state {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: 160, alignment: .trailing)
                }
            }
        case .preparing:
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("Optimizing for this Mac")
                        .font(.caption.weight(.medium))
                    Text("One-time, a few minutes")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ProgressView().controlSize(.small)
            }
            .transition(.blurReplace)
        case .installed:
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.solidBackground)
                    .frame(width: 30, height: 30)
                    .glassEffect(.regular.tint(.solidLabel), in: .circle)
                    .glassEffectID("control", in: glass)
                    .help("In use")
            } else {
                GlassCapsuleButton(title: "Use", height: 30, morph: ("control", glass)) { select() }
            }
        case .unavailable(let reason):
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 150, alignment: .trailing)
        }
    }

    private func select() {
        guard state != .checking else { return }
        if case .unavailable = state { return }
        app.selectSpeechModel(model)
    }
}
