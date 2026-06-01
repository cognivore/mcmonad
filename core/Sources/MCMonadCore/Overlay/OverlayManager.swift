import AppKit
import os

/// Owns one transparent, click-through overlay window per visible
/// workspace, drawn at a high window level so it sits above
/// application windows. Toggled on/off by `setEnabled`; redraws on
/// every `apply` call.
///
/// The overlay window covers each NSScreen's `visibleFrame` so its
/// coordinate space aligns 1:1 with the wire-format coordinates
/// produced by `DisplayManager.currentScreens()` (top-left origin
/// for the same area).
@MainActor
final class OverlayManager {
    private static let logger = Logger(
        subsystem: "com.mcmonad.core",
        category: "OverlayManager"
    )

    private var enabled: Bool = false
    /// One overlay window per displayed workspace (keyed by screen
    /// index, which matches the snapshot's screenId).
    private var windows: [Int: NSWindow] = [:]
    private var lastSnapshot: OverlaySnapshot?

    /// Snapshot the menubar reads from. Updated on every apply,
    /// including when overlay is disabled.
    private(set) var cachedSnapshot: OverlaySnapshot?

    /// Called when overlay enable state changes (toggled by the
    /// menubar's debug switch).
    var onUserToggledDebug: (() -> Void)?

    /// Called on the false -> true transition of `enabled`. Hook for
    /// runtime self-tests that should only run while the user is in
    /// debug mode (e.g. the AX <-> SkyLight bridge probe). Not fired
    /// on subsequent applies, only on the entry edge.
    var onEnabledTurnedOn: (() -> Void)?

    func setEnabled(_ on: Bool) {
        guard enabled != on else { return }
        enabled = on
        if on {
            if let snap = lastSnapshot {
                redraw(snap)
            }
            onEnabledTurnedOn?()
        } else {
            tearDownAll()
        }
    }

    func isEnabled() -> Bool { enabled }

    /// Push a new snapshot. Always updates the menubar cache. Triggers
    /// overlay redraw only when enabled.
    func apply(_ snapshot: OverlaySnapshot) {
        lastSnapshot = snapshot
        cachedSnapshot = snapshot
        guard enabled else { return }
        redraw(snapshot)
    }

    // MARK: - Internals

    private func redraw(_ snapshot: OverlaySnapshot) {
        // Reconcile windows: keep one per snapshot screenId, drop stale,
        // create missing.
        let liveIds = Set(snapshot.screens.map { $0.screenId })
        for (sid, win) in windows where !liveIds.contains(sid) {
            win.orderOut(nil)
            windows.removeValue(forKey: sid)
        }

        for screen in snapshot.screens {
            let win = ensureWindow(forScreenId: screen.screenId)
            guard let win, let view = win.contentView as? OverlayView else { continue }

            // Cache actual frames once per redraw (rather than in draw(_:))
            let entries: [OverlayRenderEntry] = screen.windows.map { entry in
                let actual = SkyLight.shared.getWindowBounds(entry.windowId)
                return OverlayRenderEntry(entry: entry, actualFrame: actual)
            }
            view.apply(
                workspaceFrame: screen.frame,
                workspaceTag: screen.workspaceTag,
                entries: entries
            )
        }
    }

    private func ensureWindow(forScreenId screenId: Int) -> NSWindow? {
        if let existing = windows[screenId] {
            // Reposition in case display config changed
            if let nsScreen = nsScreenFor(screenId: screenId) {
                let visible = nsScreen.visibleFrame
                if existing.frame != visible {
                    existing.setFrame(visible, display: false)
                }
            }
            if !existing.isVisible {
                existing.orderFrontRegardless()
            }
            return existing
        }
        guard let nsScreen = nsScreenFor(screenId: screenId) else {
            Self.logger.warning("No NSScreen for screenId=\(screenId)")
            return nil
        }
        let visible = nsScreen.visibleFrame
        let win = NSWindow(
            contentRect: visible,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: nsScreen
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)) + 1)
        win.ignoresMouseEvents = true
        win.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary
        ]
        win.isReleasedWhenClosed = false
        win.hidesOnDeactivate = false

        let view = OverlayView(frame: NSRect(origin: .zero, size: visible.size))
        view.autoresizingMask = [.width, .height]
        win.contentView = view
        win.orderFrontRegardless()
        windows[screenId] = win
        return win
    }

    private func nsScreenFor(screenId: Int) -> NSScreen? {
        let screens = NSScreen.screens
        guard screenId >= 0 && screenId < screens.count else { return nil }
        return screens[screenId]
    }

    private func tearDownAll() {
        for (_, win) in windows {
            win.orderOut(nil)
        }
        windows.removeAll()
    }
}
