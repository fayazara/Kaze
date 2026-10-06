import AppKit
import SwiftUI

// Kaze's visual language: monochrome ink on Liquid Glass. No brand colors and
// no gradients; motion and glass morphing carry the personality.

extension Color {
    /// Pure black in light mode, pure white in dark. `.primary` inside a
    /// button picks up the window tint, and `.labelColor` is translucent.
    static let solidLabel = Color(nsColor: NSColor(name: nil) { $0.isDark ? .white : .black })
    static let solidBackground = Color(nsColor: NSColor(name: nil) { $0.isDark ? .black : .white })
    /// The one functional color: recording.
    static let recordRed = Color(red: 0.91, green: 0.0, blue: 0.17)
}

private extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

extension Animation {
    /// Shared spring for things that appear, part and settle.
    static let kaze = Animation.bouncy(duration: 0.45, extraBounce: 0.08)
    /// Tighter spring for presses, hovers and small state flips.
    static let kazeQuick = Animation.snappy(duration: 0.25, extraBounce: 0.12)
}

private struct MotionModifier<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// Animates changes to `value` with Kaze's spring, respecting Reduce Motion.
    func motion<Value: Equatable>(_ animation: Animation = .kaze, value: Value) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }

    /// A quiet rounded surface for cards and groups.
    func surface(selected: Bool = false, radius: CGFloat = 14) -> some View {
        background(.primary.opacity(selected ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

enum Theme {
    /// The vendor's logo, as a template image that takes the current ink.
    static func logo(for family: SpeechModel.Family) -> Image {
        switch family {
        case .apple: Image(systemName: "apple.logo")
        case .parakeet: Image("nvidia-icon")
        case .whisper: Image("openai-icon")
        }
    }

    static let superwhisperLogo = Image("superwhisper-icon")
}

/// A vendor logo drawn in solid ink at a given size.
struct LogoMark: View {
    let image: Image
    var size: CGFloat

    var body: some View {
        image
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}

// MARK: - Glass controls

/// A round clear-glass icon button. Pass `morph` to let it melt in and out of
/// its neighbours inside a `GlassEffectContainer`.
struct GlassIconButton: View {
    let systemImage: String
    let help: String
    var size: CGFloat = 32
    var symbolSize: CGFloat = 12
    var tint: Color? = nil
    var morph: (id: String, namespace: Namespace.ID)?
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: symbolSize, weight: .medium))
                .foregroundStyle(tint == nil ? Color.solidLabel.opacity(isEnabled ? 0.9 : 0.3) : Color.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(tint.map { .regular.tint($0).interactive(isEnabled) } ?? .regular.interactive(isEnabled), in: .circle)
        .modifier(GlassMorph(morph: morph))
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A clear-glass capsule button with a label. `isProminent` inks it solid for
/// the primary action of a screen.
struct GlassCapsuleButton: View {
    let title: String
    var systemImage: String?
    var isProminent = false
    var height: CGFloat = 34
    var morph: (id: String, namespace: Namespace.ID)?
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .contentTransition(.symbolEffect(.replace))
                }
                Text(title)
                    .contentTransition(.numericText())
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isProminent ? Color.solidBackground : Color.solidLabel.opacity(isEnabled ? 0.9 : 0.3))
            .padding(.horizontal, 16)
            .frame(height: height)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(isProminent ? .regular.tint(.solidLabel).interactive(isEnabled) : .regular.interactive(isEnabled), in: .capsule)
        .modifier(GlassMorph(morph: morph))
        .fixedSize()
        .accessibilityLabel(title)
    }
}

/// A glass capsule that doubles as a progress bar: it fills with solid ink as
/// work proceeds, with the label shown in reverse over the filled part.
/// Tapping while running cancels.
struct GlassProgressButton: View {
    let title: String
    var systemImage: String?
    /// `nil` when idle; 0...1 while running.
    let progress: Double?
    var runningTitle: String = "Downloading"
    var width: CGFloat = 150
    var height: CGFloat = 30
    var morph: (id: String, namespace: Namespace.ID)?
    let start: () -> Void
    let cancel: () -> Void
    @State private var hovering = false

    var body: some View {
        let running = progress != nil
        Button { running ? cancel() : start() } label: {
            GeometryReader { proxy in
                let filled = proxy.size.width * min(max(progress ?? 0, 0), 1)
                ZStack(alignment: .leading) {
                    if running {
                        Rectangle().fill(Color.solidLabel).frame(width: filled)
                            .frame(maxHeight: .infinity)
                            .transition(.opacity)
                    }
                    label(running: running).foregroundStyle(Color.solidLabel.opacity(0.9))
                    if running {
                        label(running: running).foregroundStyle(Color.solidBackground)
                            .mask(alignment: .leading) { Rectangle().frame(width: filled) }
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
                .clipShape(Capsule())
                .motion(.smooth(duration: 0.35), value: progress)
            }
            .frame(width: width, height: height)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .modifier(GlassMorph(morph: morph))
        .onHover { hovering = $0 }
        .help(running ? "Cancel" : title)
    }

    private func label(running: Bool) -> some View {
        HStack(spacing: 6) {
            if running {
                Text(hovering ? "Cancel" : "\(runningTitle) \((progress ?? 0).formatted(.percent.precision(.fractionLength(0))))")
                    .monospacedDigit()
                    .contentTransition(.numericText())
            } else {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .frame(maxWidth: .infinity)
    }
}

private struct GlassMorph: ViewModifier {
    let morph: (id: String, namespace: Namespace.ID)?
    func body(content: Content) -> some View {
        if let morph { content.glassEffectID(morph.id, in: morph.namespace) } else { content }
    }
}

// MARK: - Small pieces

/// A single keyboard key, drawn like a physical key cap.
struct KeyCap: View {
    let label: String
    var size: Size = .regular

    enum Size { case small, regular, large }

    private var fontSize: CGFloat {
        switch size {
        case .small: 11
        case .regular: 13
        case .large: 20
        }
    }

    var body: some View {
        Text(label)
            .font(.system(size: fontSize, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.solidLabel)
            .padding(.horizontal, size == .large ? 14 : 7)
            .frame(minWidth: size == .large ? 48 : (size == .small ? 20 : 28),
                   minHeight: size == .large ? 48 : (size == .small ? 20 : 26))
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: size == .large ? 12 : 7, style: .continuous))
    }
}

struct ShortcutCaps: View {
    let shortcut: Shortcut
    var size: KeyCap.Size = .regular

    var body: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: size == .large ? 8 : 4) {
                ForEach(Array(shortcut.keyCaps.enumerated()), id: \.offset) { _, cap in
                    KeyCap(label: cap, size: size)
                }
            }
        }
    }
}

/// Five-segment rating meter in solid ink.
struct RatingDots: View {
    let label: String
    let value: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            HStack(spacing: 2.5) {
                ForEach(0..<5) { index in
                    Capsule()
                        .fill(Color.solidLabel.opacity(index < value ? 0.8 : 0.12))
                        .frame(width: 10, height: 4)
                }
            }
        }
    }
}

/// A quiet pill label, e.g. "Recommended".
struct Tag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.solidLabel.opacity(0.75))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.primary.opacity(0.07), in: Capsule())
    }
}

/// Model family mark: a monochrome symbol on glass.
struct ModelGlyph: View {
    let family: SpeechModel.Family
    var size: CGFloat = 34

    /// The NVIDIA mark is wide and short, so it gets more room to read at the
    /// same visual weight as the others.
    private var logoScale: CGFloat {
        switch family {
        case .apple: 0.44
        case .parakeet: 0.66
        case .whisper: 0.52
        }
    }

    var body: some View {
        LogoMark(image: Theme.logo(for: family), size: size * logoScale)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(Color.solidLabel.opacity(0.85))
            .frame(width: size, height: size)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}

/// A row of glass capsules where the selected one is inked solid; the
/// selection morphs between options.
struct GlassSegmentedPicker<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    var symbol: ((Value) -> String)? = nil
    var height: CGFloat = 34
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(options, id: \.self) { option in
                    let selected = option == selection
                    Button { selection = option } label: {
                        HStack(spacing: 6) {
                            if let symbol { Image(systemName: symbol(option)) }
                            Text(title(option))
                        }
                        .font(.system(size: height < 32 ? 12 : 13, weight: .semibold))
                        .foregroundStyle(selected ? Color.solidBackground : Color.solidLabel.opacity(0.8))
                        .padding(.horizontal, height < 32 ? 11 : 14)
                        .frame(height: height)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(selected ? .regular.tint(.solidLabel).interactive() : .regular.interactive(), in: .capsule)
                    .glassEffectID(option, in: glass)
                }
            }
        }
        .motion(.kazeQuick, value: selection)
    }
}
