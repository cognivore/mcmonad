import CoreGraphics
import Foundation

/// Picks a corner of `screen` to park a window in. Tries all four corners
/// at the window's full size and returns the first that doesn't overlap any
/// other screen; falls back to shrinking the parked size only when a
/// screen is boxed in on all four sides (e.g. a 2x2 grid), since no corner
/// can hide a full-size window there without spilling onto a neighbour.
/// Computed fresh on every call — screens can be connected or disconnected
/// at any time.
func freeCorner(for screen: CGRect, among allScreens: [ScreenInfo], windowSize: CGSize) -> (CGPoint, CGSize) {
    let others = allScreens.map(\.frame).filter { $0 != screen }
    let candidates = [
        CGPoint(x: screen.maxX - 1, y: screen.maxY - 1),
        CGPoint(x: screen.minX - (windowSize.width - 1), y: screen.maxY - 1),
        CGPoint(x: screen.maxX - 1, y: screen.minY - (windowSize.height - 1)),
        CGPoint(x: screen.minX - (windowSize.width - 1), y: screen.minY - (windowSize.height - 1)),
    ]
    for origin in candidates {
        let target = CGRect(origin: origin, size: windowSize)
        let overlapsAnother = others.contains { $0.intersects(target) }
        if !overlapsAnother {
            return (origin, windowSize)
        }
    }
    return (CGPoint(x: screen.maxX - 1, y: screen.maxY - 1), CGSize(width: 2, height: 2))
}

/// Is this frame already parked in one of a screen's four corners (or
/// shrunk down for the no-free-corner fallback)?
///
/// Every corner `freeCorner` can choose exposes only a ~1px sliver in BOTH
/// dimensions on its home screen (and none at all on any other screen, by
/// construction) — an ordinary tiled window always has a large exposure in
/// at least one dimension on its own screen, so checking both is what tells
/// a genuinely parked window apart from one merely tiled flush against a
/// screen edge.
func isAlreadyParked(_ frame: CGRect, screens: [ScreenInfo]) -> Bool {
    let widestExposure = screens
        .map { $0.frame.intersection(frame) }
        .map { $0.size }
        .max { $0.width * $0.height < $1.width * $1.height } ?? .zero
    return widestExposure.width <= 2 && widestExposure.height <= 2
}
