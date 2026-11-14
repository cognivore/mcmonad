import CoreGraphics

/// Pure lookup behind the query socket: which windows are on the workspace
/// shown on a given screen.
enum WorkspaceWindowLookup {
    /// The windows on the screen whose frame is closest to the requested one,
    /// followed by the ignored windows `ignoredWindowIds` attributes to it.
    /// Matching is by distance rather than exact equality, since window-server
    /// geometry (visibleFrame, scale factors) can differ by a few pixels from
    /// what a caller observes through its own screen APIs.
    static func windowIds(
        forScreenFrame target: CGRect,
        in snapshot: OverlaySnapshot?,
        ignoredWindowIds: (OverlaySnapshot) -> [UInt32]
    ) -> [UInt32] {
        guard let snapshot else { return [] }
        let closest = snapshot.screens.min { lhs, rhs in
            distance(lhs.frame, target) < distance(rhs.frame, target)
        }
        guard let closest else { return [] }
        return closest.windows.map(\.windowId) + ignoredWindowIds(snapshot)
    }

    static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        hypot(a.origin.x - b.origin.x, a.origin.y - b.origin.y)
    }
}
