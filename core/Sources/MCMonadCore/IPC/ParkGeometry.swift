import CoreGraphics
import Foundation

/// The largest extent, in points, that a parked window may show of itself
/// on a display in at least one dimension.
let parkSliver: CGFloat = 2

/// Is this frame parked: on every display, what shows of it is at most a
/// sliver in one dimension (or nothing at all)?
///
/// A tiled or floating window always has a real two-dimensional exposure
/// on its own display, so this tells a parked window from one tiled flush
/// against a screen edge. It is deliberately a statement about every
/// display and not about one corner: a park on a screen with neighbours
/// on both sides leaves a one-point row on the neighbour too, and that is
/// still a park. The brain applies the same rule
/// (`MCMonad.Operations.frameIsParked`); the two must agree, because the
/// brain decides when to re-send a park and the core decides whether a
/// re-sent park still needs a write.
func isAlreadyParked(_ frame: CGRect, screens: [ScreenInfo]) -> Bool {
    screens.allSatisfy { screen in
        let shown = screen.frame.intersection(frame)
        return shown.isNull || shown.width <= parkSliver || shown.height <= parkSliver
    }
}

/// Where to put a window of `windowSize` so that it is parked, for a
/// window living on `screen`. The window keeps its size: shrinking it
/// would make every terminal and browser reflow on each workspace switch.
///
/// Only the two bottom corners are candidates. A window is hidden by
/// hanging it off a left or right edge; macOS pulls a window whose title
/// bar is above the top of a display back down, and may pull one that is
/// below the bottom back up, so the horizontal overhang is the part that
/// has to hold.
///
/// Preference, first match wins:
///   0. a bottom corner of the window's own screen with no display at all
///      beside it in the direction the window hangs, so that nothing macOS
///      does to the vertical position can bring it into view;
///   1. a bottom corner of the window's own screen that shows nothing on
///      any other display;
///   2. a bottom corner of its own screen that is still a park (a sliver
///      on a neighbour), which is all a screen with a neighbour on each
///      side can offer;
///   3. a bottom corner of another display that shows nothing elsewhere,
///      nearest first, for a screen boxed in so tightly that its own
///      corners would put the window in full view on a neighbour;
///   4. the own bottom-right corner.
/// Computed fresh on every call: displays come and go.
func parkOrigin(for screen: CGRect, among allScreens: [ScreenInfo], windowSize: CGSize) -> CGPoint {
    func corners(_ s: CGRect) -> [CGPoint] {
        [CGPoint(x: s.maxX - 1, y: s.maxY - 1),
         CGPoint(x: s.minX - (windowSize.width - 1), y: s.maxY - 1)]
    }
    func target(_ origin: CGPoint) -> CGRect { CGRect(origin: origin, size: windowSize) }
    func showsOnlyOn(_ home: CGRect, _ origin: CGPoint) -> Bool {
        isAlreadyParked(target(origin), screens: allScreens)
            && !allScreens.contains { $0.frame != home && $0.frame.intersects(target(origin)) }
    }
    func nothingBeside(_ origin: CGPoint) -> Bool {
        let t = target(origin)
        return !allScreens.contains { $0.frame != screen && $0.frame.maxX > t.minX && $0.frame.minX < t.maxX
            && !($0.frame.minX >= screen.minX && $0.frame.maxX <= screen.maxX) }
    }
    let own = corners(screen)
    if let free = own.first(where: { nothingBeside($0) && showsOnlyOn(screen, $0) }) { return free }
    if let clean = own.first(where: { showsOnlyOn(screen, $0) }) { return clean }
    if let parked = own.first(where: { isAlreadyParked(target($0), screens: allScreens) }) { return parked }
    let others = allScreens.map(\.frame).filter { $0 != screen }.sorted {
        hypot($0.midX - screen.midX, $0.midY - screen.midY) < hypot($1.midX - screen.midX, $1.midY - screen.midY)
    }
    for other in others {
        if let clean = corners(other).first(where: { showsOnlyOn(other, $0) }) { return clean }
    }
    return own[0]
}
