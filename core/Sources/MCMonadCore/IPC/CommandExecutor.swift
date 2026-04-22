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
        }
    }

    // MARK: - Command Implementations

    private func executeSetFrames(_ frames: [FrameAssignment]) {
        fputs("CMD: set-frames count=\(frames.count)\n", stderr)
        guard let skylight = SkyLight.shared else {
            logger.error("SkyLight not available for setFrames")
            return
        }

        skylight.disableUpdate()
        defer { skylight.reenableUpdate() }

        for assignment in frames {
            // Read current frame as hint for write ordering (grow vs shrink)
            let currentFrame = skylight.getWindowBounds(assignment.windowId)
            _ = AXWindowService.setFrame(
                assignment.frame,
                windowId: assignment.windowId,
                pid: assignment.pid,
                currentHint: currentFrame
            )
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
        for windowId in windowIds {
            _ = AXWindowService.setMinimized(windowId: windowId, minimized: true)
        }
    }

    private func executeShowWindows(_ windowIds: [UInt32]) {
        for windowId in windowIds {
            _ = AXWindowService.setMinimized(windowId: windowId, minimized: false)
        }
    }
}
