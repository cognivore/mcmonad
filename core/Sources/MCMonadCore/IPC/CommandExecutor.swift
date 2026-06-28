import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os

private let logger = Logger(subsystem: "com.mcmonad.core", category: "CommandExecutor")

@MainActor
final class CommandExecutor {
    let hotkeyManager: HotkeyManager
    let displayManager: DisplayManager
    let socketServer: SocketServer
    let statusBarController: StatusBarController
    let overlayManager: OverlayManager

    /// Callback invoked with the list of windows produced by
    /// 'executeQueryWindows'. The owner uses it to enrol existing
    /// windows in subsystems that ordinarily only fire on
    /// SkyLight-observed creation (notably AXFocusTracker). Set
    /// from Main once the EventBridge that handles it is built.
    var onExistingWindowsEnumerated: (([WindowInfo]) -> Void)?

    /// Invoked when Haskell asks to open the fuzzy window-search dropdown
    /// (the legacy `show-window-picker` command). Wired in Main to open the
    /// Spotlight panel in window mode.
    var onShowWindowPicker: (() -> Void)?

    /// Invoked when Haskell asks to open the Spotlight launcher (the
    /// `show-spotlight` command), carrying the requested mode string
    /// ("command" or "window"). Wired in Main to the SpotlightController.
    var onShowSpotlight: ((String) -> Void)?

    /// Invoked when Haskell pushes the authoritative timer list (the
    /// `set-timers` command). Wired in Main to TimerController.setTimers.
    var onSetTimers: (([TimerSpec]) -> Void)?

    private let encoder = JSONEncoder()

    init(
        hotkeyManager: HotkeyManager,
        displayManager: DisplayManager,
        socketServer: SocketServer,
        statusBarController: StatusBarController,
        overlayManager: OverlayManager
    ) {
        self.hotkeyManager = hotkeyManager
        self.displayManager = displayManager
        self.socketServer = socketServer
        self.statusBarController = statusBarController
        self.overlayManager = overlayManager
    }

    func execute(_ command: IPCCommand) {
        switch command {
        case .setFrames(let frames):
            executeSetFrames(frames)
        case .focusWindow(let windowId, let pid):
            executeFocusWindow(windowId: windowId, pid: pid)
        case .queryWindows:
            executeQueryWindows()
        case .queryScreens:
            executeQueryScreens()
        case .registerHotkeys(let hotkeys):
            executeRegisterHotkeys(hotkeys)
        case .closeWindow(let windowId, let pid):
            executeCloseWindow(windowId: windowId, pid: pid)
        case .hideWindows(let windowIds):
            executeHideWindows(windowIds)
        case .showWindows(let windowIds):
            executeShowWindows(windowIds)
        case .setWorkspaceIndicator(let tag):
            statusBarController.updateWorkspace(tag)
        case .warpMouse(let x, let y):
            CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
        case .setDebugOverlays(let on):
            overlayManager.setEnabled(on)
        case .setOverlayState(let snapshot):
            overlayManager.apply(snapshot)
        case .queryFocusedWindow:
            executeQueryFocusedWindow()
        case .showWindowPicker:
            onShowWindowPicker?()
        case .showSpotlight(let mode):
            onShowSpotlight?(mode)
        case .setTimers(let timers):
            onSetTimers?(timers)
        }
    }

    // MARK: - Command Implementations

    private func executeSetFrames(_ frames: [FrameAssignment]) {
        // Keep the legacy "CMD: set-frames count=N" line so prior log
        // analysis tools still grep cleanly. Detailed per-assignment
        // events come through FrameLog below.
        fputs("CMD: set-frames count=\(frames.count)\n", stderr)
        FrameLog.emit(source: .cmdSetFramesBegin, extra: "count=\(frames.count)")
        let skylight = SkyLight.shared

        // Resolve AX elements once
        let resolved: [(FrameAssignment, AXUIElement)] = frames.compactMap { a in
            if let ax = AXWindowService.findAXWindow(windowId: a.windowId, pid: a.pid) {
                return (a, ax)
            } else {
                FrameLog.emit(source: .cmdAxResolveFail,
                              windowId: a.windowId, pid: a.pid, rect: a.frame)
                return nil
            }
        }

        // Pre-move snapshot. If a window already lives at the hide
        // position (5128, 0) before this set-frames touches it, we'll
        // see it here — disambiguating "this set-frames bumped it"
        // from "it was pinned before we started".
        for (a, _) in resolved {
            let tHash = TitleHash.hash(windowId: a.windowId, pid: a.pid)
            if let preBounds = skylight.getWindowBounds(a.windowId) {
                FrameLog.emit(source: .preMove,
                              windowId: a.windowId, pid: a.pid, rect: preBounds,
                              tHash: tHash,
                              extra: "want=(\(fmtCoord(a.frame.origin.x)),"
                                   + "\(fmtCoord(a.frame.origin.y)),"
                                   + "\(fmtCoord(a.frame.width)),"
                                   + "\(fmtCoord(a.frame.height)))")
            } else {
                FrameLog.emit(source: .preMove,
                              windowId: a.windowId, pid: a.pid, rect: a.frame,
                              tHash: tHash,
                              result: "no-bounds")
            }
        }

        skylight.disableUpdate()

        // Phase 1: Set all sizes (prevents overlaps that clamp sizes)
        for (a, ax) in resolved {
            var size = CGSize(width: a.frame.width, height: a.frame.height)
            if let v = AXValueCreate(.cgSize, &size) {
                let err = AXUIElementSetAttributeValue(ax, kAXSizeAttribute as CFString, v)
                FrameLog.emit(source: .cmdAxSize,
                              windowId: a.windowId, pid: a.pid, rect: a.frame,
                              tHash: TitleHash.hash(windowId: a.windowId, pid: a.pid),
                              result: err == .success ? "ok" : "err",
                              extra: "phase=1 axStatus=\(err.rawValue)")
            }
        }

        // Phase 2: Set all positions
        for (a, ax) in resolved {
            var pos = CGPoint(x: a.frame.origin.x, y: a.frame.origin.y)
            if let v = AXValueCreate(.cgPoint, &pos) {
                let err = AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString, v)
                FrameLog.emit(source: .cmdAxPos,
                              windowId: a.windowId, pid: a.pid, rect: a.frame,
                              tHash: TitleHash.hash(windowId: a.windowId, pid: a.pid),
                              result: err == .success ? "ok" : "err",
                              extra: "phase=2 axStatus=\(err.rawValue)")
            }
        }

        // Phase 3: Set sizes again (fix any clamped during moves)
        for (a, ax) in resolved {
            var size = CGSize(width: a.frame.width, height: a.frame.height)
            if let v = AXValueCreate(.cgSize, &size) {
                let err = AXUIElementSetAttributeValue(ax, kAXSizeAttribute as CFString, v)
                FrameLog.emit(source: .cmdAxSize,
                              windowId: a.windowId, pid: a.pid, rect: a.frame,
                              tHash: TitleHash.hash(windowId: a.windowId, pid: a.pid),
                              result: err == .success ? "ok" : "err",
                              extra: "phase=3 axStatus=\(err.rawValue)")
            }
        }

        skylight.reenableUpdate()

        // Phase 4: Raise visible windows (AXRaise only, no app activation —
        // NSRunningApplication.activate() would bring ALL windows of that app
        // to front, including hidden ones on other workspaces)
        for (_, ax) in resolved {
            AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
        }

        // Phase 5: deterministic readback. Independent of the SkyLight
        // observer (which is coalesced and silenced for moves inside the
        // disableUpdate bracket above). Tells us per assignment whether
        // the window actually ended up where we asked.
        for (a, _) in resolved {
            let tHash = TitleHash.hash(windowId: a.windowId, pid: a.pid)
            if let actual = skylight.getWindowBounds(a.windowId) {
                let dx = actual.origin.x - a.frame.origin.x
                let dy = actual.origin.y - a.frame.origin.y
                let dw = actual.width    - a.frame.width
                let dh = actual.height   - a.frame.height
                // 1.5px tolerance — round-trip through CGFloat / AXValue
                // can introduce sub-pixel rounding noise.
                let obeyed = abs(dx) < 1.5 && abs(dy) < 1.5
                          && abs(dw) < 1.5 && abs(dh) < 1.5
                FrameLog.emit(
                    source: .verified,
                    windowId: a.windowId, pid: a.pid, rect: actual,
                    tHash: tHash,
                    result: obeyed ? "obeyed" : "DEFIED",
                    extra: "want=(\(fmtCoord(a.frame.origin.x)),"
                         + "\(fmtCoord(a.frame.origin.y)),"
                         + "\(fmtCoord(a.frame.width)),"
                         + "\(fmtCoord(a.frame.height))) "
                         + "delta=(\(fmtCoord(dx)),\(fmtCoord(dy)),"
                         + "\(fmtCoord(dw)),\(fmtCoord(dh)))"
                )
            } else {
                FrameLog.emit(source: .verified,
                              windowId: a.windowId, pid: a.pid, rect: a.frame,
                              tHash: tHash,
                              result: "no-bounds")
            }
        }
    }

    private func fmtCoord(_ d: CGFloat) -> String {
        let s = String(format: "%.1f", Double(d))
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }

    private func executeFocusWindow(windowId: UInt32, pid: Int32) {
        FocusLog.emit(source: .cmdFocusWindow, windowId: windowId, pid: pid,
                      tHash: TitleHash.hash(windowId: windowId, pid: pid))
        WindowFocus.focusWindow(pid: pid, windowId: windowId)
    }

    private func executeQueryWindows() {
        let snapshots = SkyLightQuery.queryAllVisibleWindows()
        var windowInfos: [WindowInfo] = []

        for snap in snapshots {
            if let info = AXWindowService.info(windowId: snap.windowId, pid: snap.pid) {
                windowInfos.append(info)
            }
            // If AX can't read the window, skip it — don't fabricate data
        }

        // Notify the owner BEFORE sending the response so the
        // EventBridge can register these windows (and start AX
        // focus tracking for their pids) by the time Haskell starts
        // emitting commands that depend on focus events.
        onExistingWindowsEnumerated?(windowInfos)

        let response = QueryWindowsResponse(windows: windowInfos)
        do {
            let data = try encoder.encode(response)
            socketServer.sendRaw(data)
        } catch {
            logger.error("Failed to encode query-windows response: \(error)")
        }
    }

    private func executeQueryScreens() {
        let screens = displayManager.currentScreens()
        let response = QueryScreensResponse(screens: screens)
        do {
            let data = try encoder.encode(response)
            socketServer.sendRaw(data)
        } catch {
            logger.error("Failed to encode query-screens response: \(error)")
        }
    }

    private func executeRegisterHotkeys(_ hotkeys: [HotkeySpec]) {
        hotkeyManager.register(hotkeys)
    }

    /// Answer a `query-focused-window` by reporting the window macOS
    /// currently considers focused: the frontmost application's AX focused
    /// window, mapped back to a CGWindowID via _AXUIElementGetWindow. This
    /// is the only reliable source after a Dock-icon click, where the
    /// activated app's focused window may sit on an off-screen workspace
    /// that mcmonad's StackSet focus never followed. Emits nothing if the
    /// focus can't be resolved (no fabricated answer).
    private func executeQueryFocusedWindow() {
        guard let target = WindowFocus.frontmostFocusedWindow() else {
            FocusLog.emit(source: .cmdFocusWindow,
                          result: "no-frontmost-focused-window")
            return
        }
        FocusLog.emit(source: .cmdFocusWindow,
                      windowId: target.windowId, pid: target.pid,
                      tHash: TitleHash.hash(windowId: target.windowId, pid: target.pid),
                      extra: "via=queryFocusedWindow")
        socketServer.send(.focusedWindowQueryResponse(
            windowId: target.windowId, pid: target.pid
        ))
    }

    private func executeCloseWindow(windowId: UInt32, pid: Int32) {
        _ = AXWindowService.closeWindow(windowId: windowId, pid: pid)
    }

    private func executeHideWindows(_ windowIds: [UInt32]) {
        fputs("CMD: hide-windows ids=\(windowIds)\n", stderr)
        guard !windowIds.isEmpty else { return }

        // Park each window 1px inside the bottom-right corner of the screen it
        // is on, leaving only a ~1px sliver visible. The origin MUST stay
        // inside the display union: a window placed *fully* off-screen gets
        // yanked back on-screen by AppKit (a titled NSWindow "automatically
        // constrains itself to the screen") — that was the "Photoshop ghost on
        // an empty workspace" bug, caused by the old `screenMaxX + 100` target.
        // The surviving sliver doubles as a manual drag-handle if the daemon
        // dies. Mirrors AeroSpace's hideInCorner. SkyLight can't move other
        // apps' windows (permission); AX can, since we hold Accessibility.
        for wid in windowIds {
            guard let snap = SkyLightQuery.queryWindow(wid) else {
                FrameLog.emit(source: .cmdHideMove, windowId: wid, result: "no-snap")
                continue
            }
            guard let screen = displayManager.screen(forFrame: snap.frame) else {
                FrameLog.emit(source: .cmdHideMove, windowId: wid, pid: snap.pid,
                              result: "no-screen")
                continue
            }
            let corner = CGPoint(x: screen.frame.maxX - 1, y: screen.frame.maxY - 1)
            let target = CGRect(origin: corner, size: snap.frame.size)
            FrameLog.emit(source: .cmdHideMove,
                          windowId: wid, pid: snap.pid, rect: target,
                          tHash: TitleHash.hash(windowId: wid, pid: snap.pid),
                          extra: "corner from=(\(fmtCoord(snap.frame.origin.x)),"
                               + "\(fmtCoord(snap.frame.origin.y))) "
                               + "screen=(\(fmtCoord(screen.frame.origin.x)),"
                               + "\(fmtCoord(screen.frame.origin.y)),"
                               + "\(fmtCoord(screen.frame.width)),"
                               + "\(fmtCoord(screen.frame.height)))")
            AXWindowService.setFrame(
                target,
                windowId: wid,
                pid: snap.pid,
                currentHint: snap.frame
            )
        }
    }

    private func executeShowWindows(_ windowIds: [UInt32]) {
        fputs("CMD: show-windows ids=\(windowIds)\n", stderr)
        // SetFrames follows immediately and repositions windows correctly.
    }
}
