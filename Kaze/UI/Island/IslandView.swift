import AppKit
import SwiftUI

/// Presentation state owned by the island window.
@Observable
final class IslandPresentation {
    var isPresented = false
    var geometry = IslandGeometry.fallback
}

/// The Dynamic Island-style status surface that grows out of the notch.
///
/// Three layouts, all derived from the dictation phase:
/// - **closed**: exactly the notch's size, so it's invisible against the hardware notch
/// - **compact**: "wings" on either side of the notch (status left, waveform right)
/// - **expanded**: grows downward to show live text or an error message
struct IslandView: View {
    let dictation: DictationController
    let presentation: IslandPresentation

    /// Listening needs room for the timer and waveform; every other state
    /// shows one glyph per side, so the island hugs the notch more tightly.
    private var wingWidth: CGFloat { showsWave ? 84 : 40 }

    /// The waveform persists from listening through processing and changes
    /// its motion instead of being swapped out.
    private var showsWave: Bool {
        switch dictation.phase {
        case .listening, .transcribing, .formatting, .nothingHeard: true
        default: false
        }
    }

    private var waveMode: ActivityWave.Mode {
        switch dictation.phase {
        case .transcribing: dictation.isWaitingForModel ? .loading : .transcribing
        case .formatting: .cleaning
        case .nothingHeard: .silent
        default: .live
        }
    }
    private let shoulder: CGFloat = 8
    private let spring = Animation.kaze

    private var notch: CGSize { presentation.geometry.notchSize }

    /// Bumped each time nothing was heard, to play a small "nope" shake.
    @State private var shakes = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Layout: Equatable {
        case closed, compact, expanded
    }

    private var layout: Layout {
        guard presentation.isPresented else { return .closed }
        switch dictation.phase {
        case .idle: return .closed
        case .listening: return dictation.liveText.isEmpty ? .compact : .expanded
        case .failed: return .expanded
        default: return .compact   // includes .nothingHeard
        }
    }

    /// Coarse phase identity; wing content blur-morphs when it changes.
    private var phaseKey: String {
        switch dictation.phase {
        case .idle: "idle"
        case .listening: "listening"
        case .transcribing, .formatting: "working"
        case .done: "done"
        case .failed: "failed"
        case .nothingHeard: "nothing"
        }
    }

    private var bodySize: CGSize {
        switch layout {
        case .closed:
            CGSize(width: notch.width, height: presentation.geometry.hasNotch ? notch.height : 0)
        case .compact:
            CGSize(width: notch.width + wingWidth * 2, height: notch.height)
        case .expanded:
            CGSize(width: max(notch.width + wingWidth * 2, 420), height: notch.height + expandedContentHeight)
        }
    }

    private var expandedContentHeight: CGFloat {
        if case .failed = dictation.phase { return 34 }
        return 52
    }

    private var bottomRadius: CGFloat {
        switch layout {
        case .closed: presentation.geometry.hasNotch ? 10 : 4
        case .compact: min(16, notch.height / 2)
        case .expanded: 22
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                IslandShape(topRadius: shoulder, bottomRadius: bottomRadius)
                    .fill(.black)
                    .shadow(color: .black.opacity(layout == .closed ? 0 : 0.35), radius: 14, y: 6)

                content
                    .padding(.horizontal, shoulder)
                    .opacity(layout == .closed ? 0 : 1)
                    .blur(radius: layout == .closed ? 6 : 0)
                    .animation(layout == .closed ? .easeOut(duration: 0.12) : .easeOut(duration: 0.25).delay(0.08), value: layout == .closed)
            }
            .frame(width: bodySize.width + shoulder * 2, height: bodySize.height)
            .clipShape(IslandShape(topRadius: shoulder, bottomRadius: bottomRadius))
            .animation(spring, value: layout)
            .animation(spring, value: bodySize)
            .keyframeAnimator(initialValue: CGFloat(0), trigger: shakes) { island, x in
                island.offset(x: x)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(0, duration: 0.12)   // let the bars settle first
                    SpringKeyframe(-7, duration: 0.07)
                    SpringKeyframe(6, duration: 0.08)
                    SpringKeyframe(-4, duration: 0.08)
                    SpringKeyframe(2, duration: 0.08)
                    SpringKeyframe(0, duration: 0.12)
                }
            }
            .onChange(of: dictation.phase) { _, phase in
                if phase == .nothingHeard, !reduceMotion { shakes += 1 }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ZStack(alignment: .leading) {
                    leading.id(phaseKey).transition(.blurReplace)
                }
                .frame(width: wingWidth, alignment: .leading)
                .padding(.leading, 14)
                Spacer(minLength: notch.width - 28)
                ZStack(alignment: .trailing) {
                    if showsWave {
                        ActivityWave(mode: waveMode, levels: Array(dictation.levels.suffix(11)))
                            .frame(height: 18)
                            .transition(.blurReplace)
                    } else {
                        trailing.id(phaseKey).transition(.blurReplace)
                    }
                }
                .frame(width: wingWidth, alignment: .trailing)
                .padding(.trailing, 14)
            }
            .frame(height: notch.height)
            .animation(.kaze, value: phaseKey)

            if layout == .expanded {
                expandedContent
                    .padding(.horizontal, 22)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
    }

    // MARK: - Wings

    @ViewBuilder
    private var leading: some View {
        switch dictation.phase {
        case .listening(let handsFree):
            HStack(spacing: 7) {
                RecordingDot()
                if let since = dictation.listeningSince {
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        Text(Self.elapsed(since: since, now: context.date))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.9))
                            .contentTransition(.numericText())
                    }
                }
                if handsFree {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .transition(.scale.combined(with: .opacity))
                }
            }
        case .transcribing, .formatting:
            // The recording's final length, frozen.
            if let since = dictation.listeningSince, let end = dictation.stoppedAt {
                Text(Self.elapsed(since: since, now: end))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.leading, 15)
            }
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .symbolEffect(.bounce, value: dictation.phase)
        case .failed, .nothingHeard, .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch dictation.phase {
        case .done(let pasted):
            if pasted, let icon = dictation.targetApp?.icon {
                // Where the text went.
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
            } else {
                StageGlyph(systemImage: "doc.on.clipboard")
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var expandedContent: some View {
        switch dictation.phase {
        case .failed(let message):
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        default:
            Text(dictation.liveText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(2)
                .truncationMode(.head)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.interpolate)
                .animation(.easeOut(duration: 0.15), value: dictation.liveText)
        }
    }

    private static func elapsed(since: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - Pieces

private struct RecordingDot: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 8, height: 8)
            .background(
                Circle()
                    .fill(Color.red.opacity(0.45))
                    .scaleEffect(pulsing ? 2.2 : 1)
                    .opacity(pulsing ? 0 : 1)
            )
            .onAppear {
                withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { pulsing = true }
            }
    }
}

/// Bars that follow the real input level, newest on the right.
/// The island's waveform. Live, it follows the microphone; afterwards the
/// same bars keep moving to show what Kaze is doing, blending from their last
/// live position so the change never pops.
struct ActivityWave: View {
    enum Mode: Equatable {
        case live, transcribing, loading, cleaning
        /// Nothing was heard: the bars settle into flat dots.
        case silent
    }

    let mode: Mode
    let levels: [Float]

    @State private var modeChangedAt = Date.distantPast
    @State private var frozen: [CGFloat] = []

    private let count = 11

    var body: some View {
        TimelineView(.animation(paused: mode == .live)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let blend = min(1, max(0, context.date.timeIntervalSince(modeChangedAt) / 0.45))
            GeometryReader { proxy in
                HStack(alignment: .center, spacing: 2.5) {
                    ForEach(0..<count, id: \.self) { index in
                        let value = height(index, t: t, blend: blend)
                        Capsule()
                            .fill(.white.opacity(opacity(index, t: t, value: value)))
                            .frame(width: 3, height: max(3, proxy.size.height * value * taper(index)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
        }
        .animation(mode == .live ? .easeOut(duration: 0.09) : nil, value: levels)
        .onChange(of: mode) { _, _ in
            frozen = (0..<count).map(liveHeight)
            modeChangedAt = Date()
        }
    }

    private func liveHeight(_ index: Int) -> CGFloat {
        guard index < levels.count else { return 0 }
        return CGFloat(pow(Double(levels[index]), 0.6))
    }

    private func height(_ index: Int, t: Double, blend: Double) -> CGFloat {
        if mode == .live { return liveHeight(index) }
        let i = Double(index)
        let target: Double
        switch mode {
        case .transcribing:
            // A wave travelling right to left.
            target = 0.22 + 0.6 * (0.5 + 0.5 * sin(t * 6.5 + i * 0.65))
        case .loading:
            // All bars breathing together, slowly.
            target = 0.2 + 0.28 * (0.5 + 0.5 * sin(t * 2.4))
        case .cleaning:
            // An uneven shimmer.
            target = 0.25 + 0.55 * (0.5 + 0.5 * sin(t * 4.2 + i * 1.3)) * (0.55 + 0.45 * sin(t * 1.9 + i * 0.7))
        case .live, .silent:
            target = 0
        }
        let start = index < frozen.count ? Double(frozen[index]) : target
        let eased = blend * blend * (3 - 2 * blend)
        return CGFloat(start + (target - start) * eased)
    }

    private func opacity(_ index: Int, t: Double, value: CGFloat) -> Double {
        switch mode {
        case .live: 0.55 + 0.45 * Double(value)
        case .cleaning: 0.45 + 0.4 * (0.5 + 0.5 * sin(t * 3 + Double(index) * 0.9))
        case .silent: 0.35
        default: 0.5 + 0.4 * Double(value)
        }
    }

    /// Taper the edges so the bars read as one shape.
    private func taper(_ index: Int) -> CGFloat {
        CGFloat(0.55 + 0.45 * sin(Double(index + 1) / Double(count + 1) * .pi))
    }
}

/// A quiet stage icon for the trailing wing.
private struct StageGlyph: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.6))
            .symbolEffect(.pulse, options: .repeating)
    }
}
