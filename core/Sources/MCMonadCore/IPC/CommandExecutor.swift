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
        fputs("CMD: set-frames count=\(frames.count)\n", stderr)
        guard let skylight = SkyLight.shared else {
            logger.error("SkyLight not available for setFrames")
            return
        }

        // Resolve AX elements once
        let resolved: [(FrameAssignment, AXUIElement)] = frames.compactMap { a in
            AXWindowService.findAXWindow(windowId: a.windowId, pid: a.pid).map { (a, $0) }
        }

        skylight.disableUpdate()

        // Phase 1: Set all sizes (prevents overlaps that clamp sizes)
        for (a, ax) in resolved {
            var size = CGSize(width: a.frame.width, height: a.frame.height)
            if let v = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(ax, kAXSizeAttribute as CFString, v)
            }
        }

        // Phase 2: Set all positions
        for (a, ax) in resolved {
            var pos = CGPoint(x: a.frame.origin.x, y: a.frame.origin.y)
            if let v = AXValueCreate(.cgPoint, &pos) {
                AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString, v)
            }
        }

        // Phase 3: Set sizes again (fix any clamped during moves)
        for (a, ax) in resolved {
            var size = CGSize(width: a.frame.width, height: a.frame.height)
            if let v = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(ax, kAXSizeAttribute as CFString, v)
            }
        }

        skylight.reenableUpdate()

        // Phase 4: Raise all visible windows to cover hidden windows
        // that refused to move offscreen (e.g. Slack).
        // AXRaise only works within an app, so also use SkyLight to
        // order visible windows above everything.
        var seenPids = Set<Int32>()
        for (a, ax) in resolved {
            AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
            // Activate each unique app so its windows come to front
            if seenPids.insert(a.pid).inserted {
                NSRunningApplication(processIdentifier: a.pid)?.activate()
            }
        }
    }

    private func executeFocusWindow(windowId: UInt32, pid: Int32) {
        fputs("CMD: focus-window wid=\(windowId) pid=\(pid)\n", stderr)
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
        // Move windows far offscreen. SetFrames will reposition them when
        // they become visible again on a workspace switch.
        for windowId in windowIds {
            if let snap = SkyLightQuery.queryWindow(windowId) {
                // Move offscreen but keep original size (some apps enforce minimums)
                AXWindowService.setFrame(
                    CGRect(x: -20000, y: -20000, width: snap.frame.width, height: snap.frame.height),
                    windowId: windowId,
                    pid: snap.pid,
                    currentHint: snap.frame
                )
            }
        }
    }

    private func executeShowWindows(_ windowIds: [UInt32]) {
        // Windows will be repositioned by the SetFrames command that
        // follows. Nothing to do here.
    }
}
