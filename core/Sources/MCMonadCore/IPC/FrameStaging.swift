// AI-generated text: model claude-fable-5-2; reasoning effort unavailable
// (not exposed by the harness).
import CoreGraphics
import Foundation

/// Where to put a window first, so that it can be resized before it is
/// moved to `target`, or nil when it can go straight there.
///
/// A window is resized where it stands. One that is still its old size
/// when it arrives at the target origin can reach onto a neighbouring
/// display, and a window lying across two displays is held to the
/// neighbour's height and takes no width from an Accessibility write: a
/// terminal that was the full width of a 3440-point display, shown again
/// as its right-hand two thirds, stayed 3440 wide and 1085 high (the
/// laptop display's height) over every other tile, through every
/// re-send. Writing the size first does not help a window coming out of
/// the park corner, where the size write is not applied.
///
/// So such a window first goes to the point nearest the target origin at
/// which its current size lies inside the target's display, is resized
/// there, and only then moves to the target. The target size fits at
/// that point too, because the point is never right of or below the
/// target origin.
///
/// - Parameters:
///   - target: the frame the window is to end up with.
///   - current: the window's size now.
///   - screen: the display `target` is on.
///   - others: every other display.
func stagingOrigin(target: CGRect, current: CGSize, screen: CGRect, others: [CGRect]) -> CGPoint? {
    let arriving = CGRect(origin: target.origin, size: current)
    let spills = others.contains { other in
        let shown = other.intersection(arriving)
        return !shown.isNull && shown.width > parkSliver && shown.height > parkSliver
    }
    guard spills else { return nil }
    let x = max(screen.minX, min(target.minX, screen.maxX - current.width))
    let y = max(screen.minY, min(target.minY, screen.maxY - current.height))
    return CGPoint(x: x, y: y)
}
