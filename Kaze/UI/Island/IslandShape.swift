import SwiftUI

/// The island silhouette: concave "shoulders" where it meets the top edge of
/// the screen (like the hardware notch), and rounded bottom corners.
///
/// `rect` includes the shoulders, so the body is `rect.width - 2 * topRadius`
/// wide. Every dimension is animatable so the shape morphs smoothly between
/// the closed (notch-sized), compact and expanded layouts.
struct IslandShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        // Clamp radii so the path never self-intersects at small sizes.
        let top = max(0, min(topRadius, rect.width / 4, rect.height / 2))
        let bottom = max(0, min(bottomRadius, (rect.width - 2 * top) / 2, rect.height - top))

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // Left shoulder curves inward and down.
        path.addQuadCurve(to: CGPoint(x: rect.minX + top, y: rect.minY + top),
                          control: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
                          control: CGPoint(x: rect.minX + top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
                          control: CGPoint(x: rect.maxX - top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        // Right shoulder.
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// Where the island sits on a given screen.
struct IslandGeometry: Equatable {
    /// Size of the hardware notch, or of a virtual one on screens without it.
    var notchSize: CGSize
    var hasNotch: Bool

    static func forScreen(_ screen: NSScreen) -> IslandGeometry {
        let inset = screen.safeAreaInsets.top
        if inset > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            return IslandGeometry(notchSize: CGSize(width: width, height: inset), hasNotch: true)
        }
        // No notch: grow out of the top edge from a notch-like footprint.
        let menuBarHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        return IslandGeometry(notchSize: CGSize(width: 190, height: menuBarHeight), hasNotch: false)
    }

    static let fallback = IslandGeometry(notchSize: CGSize(width: 190, height: 32), hasNotch: false)
}
