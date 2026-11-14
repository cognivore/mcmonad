import CoreGraphics

/// Which screen a parked window belongs to: the one it shows a corner on
/// (a non-empty exposure that is a sliver in both dimensions). A park can
/// also leave a one-point row on a neighbour, which is larger in area, so
/// the corner is looked for first and the largest overlap is only the
/// answer for a frame that is not parked.
func homeScreen(for frame: CGRect, among screens: [ScreenInfo]) -> ScreenInfo? {
    func shown(_ s: ScreenInfo) -> CGRect { s.frame.intersection(frame) }
    if let corner = screens.first(where: {
        let r = shown($0)
        return !r.isNull && r.width > 0 && r.height > 0 && r.width <= parkSliver && r.height <= parkSliver
    }) { return corner }
    func area(_ s: ScreenInfo) -> CGFloat { let r = shown(s); return r.isNull ? 0 : r.width * r.height }
    return screens.max { area($0) < area($1) }
}

/// A frame of `size` centered on `screen`.
func centeredFrame(of size: CGSize, on screen: CGRect) -> CGRect {
    CGRect(x: screen.midX - size.width / 2,
           y: screen.midY - size.height / 2,
           width: size.width, height: size.height)
}
