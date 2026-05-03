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

    private let encoder = JSONEncoder()

    init(
        hotkeyManager: HotkeyManager,
        displayManager: DisplayManager,
        socketServer: SocketServer,
        statusBarController: StatusBarController
    ) {
        self.hotkeyManager = hotkeyManager
        self.displayManager = displayManager
        self.socketServer = socketServer
        self.statusBarController = statusBarController
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

        skylight.disableUpdate()

        // Phase 1: Set all sizes (prevents overlaps that clamp sizes)
        for (a, ax) in resolved {
            var size = CGSize(width: a.frame.width, height: a.frame.height)
            if let v = AXValueCreate(.cgSize, &size) {
                let err = AXUIElementSetAttributeValue(ax, kAXSizeAttribute as CFString, v)
                FrameLog.emit(source: .cmdAxSize,
                              windowId: a.windowId, pid: a.pid, rect: a.frame,
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
                              result: "no-bounds")
            }
        }
    }

    private func fmtCoord(_ d: CGFloat) -> String {
        let s = String(format: "%.1f", Double(d))
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }

    private func executeFocusWindow(windowId: UInt32, pid: Int32) {
        FocusLog.emit(source: .cmdFocusWindow, windowId: windowId, pid: pid)
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

    private func executeCloseWindow(windowId: UInt32, pid: Int32) {
        _ = AXWindowService.closeWindow(windowId: windowId, pid: pid)
    }

    private func executeHideWindows(_ windowIds: [UInt32]) {
        fputs("CMD: hide-windows ids=\(windowIds)\n", stderr)
        guard !windowIds.isEmpty else { return }

        // Move windows just past the right screen edge via AX.
        // SkyLight SLSMoveWindow can't move other apps' windows (permission).
        // AX works because we have Accessibility permission.
        let screenMaxX = NSScreen.screens.map { $0.frame.maxX }.max() ?? 5000
        let hideX = screenMaxX + 100

        for wid in windowIds {
            if let snap = SkyLightQuery.queryWindow(wid) {
                AXWindowService.setFrame(
                    CGRect(x: hideX, y: 0, width: snap.frame.width, height: snap.frame.height),
                    windowId: wid,
                    pid: snap.pid,
                    currentHint: snap.frame
                )
            }
        }
    }

    private func executeShowWindows(_ windowIds: [UInt32]) {
        fputs("CMD: show-windows ids=\(windowIds)\n", stderr)
        // SetFrames follows immediately and repositions windows correctly.
    }
}
