import CoreGraphics

/// Which screen a parked window belongs to. A corner park exposes a tiny
/// sliver on exactly its home screen and nothing on any other (see
/// 'freeCorner'), so the screen with the largest (even if small)
/// intersection with the frame is the one to restore onto.
func homeScreen(for frame: CGRect, among screens: [ScreenInfo]) -> ScreenInfo? {
    func overlapArea(_ s: ScreenInfo) -> CGFloat {
        let r = s.frame.intersection(frame)
        return r.width * r.height
    }
    return screens.max { overlapArea($0) < overlapArea($1) }
}

/// A frame of `size` centered on `screen`.
func centeredFrame(of size: CGSize, on screen: CGRect) -> CGRect {
    CGRect(x: screen.midX - size.width / 2,
           y: screen.midY - size.height / 2,
           width: size.width, height: size.height)
}
