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

        // Suppress AXEnhancedUserInterface on every involved app for the
        // duration of the writes AND the phase-5 readback. The hide path
        // already gets this via AXWindowService.setFrame; without it here,
        // a browser that has flipped the flag on (Chrome/LibreWolf do once
        // their a11y engine engages — a native-fullscreen round-trip is a
        // reliable trigger) has these tile/unpark writes acknowledged but
        // animated-and-dropped, wedging the window wherever it happens to
        // be: on top of every workspace, or lost as the 1px sliver in the
        // park corner.
        let suppressedEUI = AXWindowService.suppressEnhancedUserInterface(
            pids: Set(resolved.map { $0.0.pid })
        )
        defer { AXWindowService.restoreEnhancedUserInterface(suppressedEUI) }

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
                if !obeyed {
                    scheduleReverify(windowId: a.windowId, pid: a.pid,
                                     want: a.frame)
                }
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

    /// A DEFIED verdict from the synchronous phase-5 readback is a false
    /// positive for apps that apply AX geometry writes asynchronously
    /// (Gecko once its a11y engine has engaged — even with
    /// AXEnhancedUserInterface suppressed around the write, the app
    /// processes the queued setter on its own time). Re-read once after a
    /// grace period and log the ground truth so DEFIED lines can be told
    /// apart from genuinely refused moves without hand-correlating later
    /// `observed` events. Observability only — the brain's declarative
    /// re-assertion is the corrective path.
    private func scheduleReverify(windowId: UInt32, pid: Int32, want: CGRect) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            let tHash = TitleHash.hash(windowId: windowId, pid: pid)
            let wantStr = "want=(\(fmtCoord(want.origin.x)),"
                        + "\(fmtCoord(want.origin.y)),"
                        + "\(fmtCoord(want.width)),"
                        + "\(fmtCoord(want.height))) graceMs=500"
            guard let actual = SkyLight.shared.getWindowBounds(windowId) else {
                FrameLog.emit(source: .reverified, windowId: windowId,
                              pid: pid, tHash: tHash, result: "no-bounds",
                              extra: wantStr)
                return
            }
            let obeyed = abs(actual.origin.x - want.origin.x) < 1.5
                      && abs(actual.origin.y - want.origin.y) < 1.5
                      && abs(actual.width - want.width) < 1.5
                      && abs(actual.height - want.height) < 1.5
            FrameLog.emit(
                source: .reverified,
                windowId: windowId, pid: pid, rect: actual, tHash: tHash,
                result: obeyed ? "obeyed-late" : "still-defied",
                extra: wantStr
            )
        }
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

        let allScreens = displayManager.currentScreens()

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
            // Already parked: x pinned at a corner (macOS' titlebar clamp
            // only pulls y back, so x is the discriminator). Skip the AX
            // write — this makes hide re-assertion idempotent-cheap, and the
            // brain leans on that by re-sending the full park list on every
            // front-app change / drift report to heal the silent bulk
            // un-park macOS performs on hidden windows during fullscreen
            // Space transitions. Checked against EVERY screen's right edge,
            // not the resolved `screen`: a parked frame hangs almost
            // entirely off its own display, so on multi-monitor setups
            // `screen(forFrame:)` resolves the neighbour and a
            // single-screen check would re-park (and slowly migrate) the
            // window on every re-assert.
            //
            // The right-edge test alone is NOT sufficient: on a horizontal
            // multi-monitor layout the right screen's minX equals the left
            // screen's maxX, so every ordinary window tiled on the right
            // display sits at x >= (left screen's maxX) - 2 and would be
            // mistaken for parked — leaving the second monitor's windows
            // permanently unhideable. Pair it with the sliver test: a truly
            // parked window shows at most a ~1px column on any display.
            if isAlreadyParked(snap.frame, screens: allScreens) {
                continue
            }
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

/// Is this frame already parked in some screen's bottom-right corner?
///
/// Two conditions, both required. The origin must be pinned at a screen's
/// right edge (parks set x = maxX - 1; macOS' titlebar clamp only pulls y
/// back on-screen, so x survives), AND the frame must show no more than a
/// sliver on any display. The second half is what keeps adjacent monitors
/// apart: on a side-by-side layout the right display's minX *is* the left
/// display's maxX, so an ordinary window tiled at the right screen's left
/// edge passes the edge test while still being fully visible.
func isAlreadyParked(_ frame: CGRect, screens: [ScreenInfo]) -> Bool {
    let atRightEdge = screens.contains { frame.origin.x >= $0.frame.maxX - 2 }
    guard atRightEdge else { return false }
    let widestExposure = screens
        .map { $0.frame.intersection(frame) }
        .map { $0.isNull ? 0 : $0.width }
        .max() ?? 0
    return widestExposure <= 2
}
