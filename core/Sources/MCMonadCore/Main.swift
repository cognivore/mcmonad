import AppKit
@preconcurrency import ApplicationServices
import os

private let logger = Logger(subsystem: "com.mcmonad.core", category: "Main")

/// Bridges SkyLightEventObserver delegate events to the socket server.
@MainActor
final class EventBridge: SkyLightEventDelegate {
    let socketServer: SocketServer
    /// Window IDs we have reported as created but not yet destroyed.
    private var managedWindowIds: Set<UInt32> = []

    init(socketServer: SocketServer) {
        self.socketServer = socketServer
    }

    /// Check all managed windows still exist in the window server.
    /// Fire windowDestroyed for any that have vanished.
    func validateWindows() {
        let stale = managedWindowIds.filter { wid in
            SkyLightQuery.queryWindow(wid) == nil
        }
        for wid in stale {
            managedWindowIds.remove(wid)
            socketServer.send(.windowDestroyed(windowId: wid))
        }
    }

    func skyLightEventObserver(
        _ observer: SkyLightEventObserver,
        didReceive event: CGSWindowEvent
    ) {
        switch event {
        case .created(let windowId, _):
            // Query SkyLight for the snapshot, then enrich with AX
            if let snap = SkyLightQuery.queryWindow(windowId) {
                guard let info = AXWindowService.info(
                    windowId: snap.windowId,
                    pid: snap.pid
                ) else {
                    // Can't read AX info — skip (menus, tooltips, etc.)
                    return
                }

                // Only manage windows that have a close button — this filters
                // out context menus, tooltips, popups, and other transient UI
                guard info.hasCloseButton else { return }

                observer.subscribeToWindows([windowId])
                managedWindowIds.insert(windowId)
                socketServer.send(.windowCreated(info))
            }

        case .destroyed(let windowId, _):
            managedWindowIds.remove(windowId)
            socketServer.send(.windowDestroyed(windowId: windowId))

        case .closed(let windowId):
            managedWindowIds.remove(windowId)
            socketServer.send(.windowDestroyed(windowId: windowId))

        case .frameChanged(let windowId):
            if let bounds = SkyLight.shared.getWindowBounds(windowId) {
                socketServer.send(.windowFrameChanged(windowId: windowId, frame: bounds))
            }

        case .frontAppChanged(let pid):
            fputs("BRIDGE: frontAppChanged pid=\(pid)\n", stderr)
            // Validate managed windows — catch closes that SkyLight missed
            validateWindows()
            socketServer.send(.frontAppChanged(pid: pid))

        case .titleChanged:
            // Title changes are not forwarded over IPC in the current protocol
            break
        }
    }
}

@main
struct MCMonadCoreApp {
    static func main() {
        logger.info("mcmonad-core starting")

        // 1. Check / prompt accessibility permission
        let options = [
            "AXTrustedCheckOptionPrompt" as CFString: true as CFBoolean
        ] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            logger.warning(
                "Accessibility permission not yet granted — some features will fail until granted"
            )
        }

        // 2. SkyLight is required — access triggers load (fatal on failure)
        _ = SkyLight.shared

        // 3. Configure as background daemon — no dock icon, no menu bar
        NSApplication.shared.setActivationPolicy(.accessory)

        // Run the rest on MainActor
        MainActor.assumeIsolated {
            launchServices()
        }

        // Main runloop — never returns
        // Required for Carbon event handlers and NSScreen notifications
        NSApplication.shared.run()
    }

    @MainActor
    private static func launchServices() {
        // Status bar icon
        let statusBar = StatusBarController()
        statusBar.setup()

        // Create services
        let hotkeyManager = HotkeyManager()
        let displayManager = DisplayManager()

        // Create SocketServer + CommandExecutor
        let socketServer = SocketServer()
        let executor = CommandExecutor(
            hotkeyManager: hotkeyManager,
            displayManager: displayManager,
            socketServer: socketServer,
            statusBarController: statusBar
        )

        // Route commands from socket to executor
        socketServer.onCommand = { command in
            executor.execute(command)
        }

        // Wire SkyLightEventObserver (singleton, delegate-based) to socket
        let eventBridge = EventBridge(socketServer: socketServer)
        let eventObserver = SkyLightEventObserver.shared
        eventObserver.delegate = eventBridge

        // Wire hotkey callbacks to socket events
        hotkeyManager.onHotkeyPressed = { hotkeyId in
            socketServer.send(.hotkeyPressed(hotkeyId: hotkeyId))
        }

        // Wire display change callbacks to socket events
        displayManager.onScreensChanged = { screens in
            socketServer.send(.screensChanged(screens: screens))
        }
        displayManager.startObserving()

        // App activation via NSWorkspace (reliable, unlike SkyLight 1508)
        let workspace = NSWorkspace.shared
        workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            fputs("NSWORKSPACE: didActivateApplication pid=\(pid)\n", stderr)
            Task { @MainActor in
                socketServer.send(.frontAppChanged(pid: pid))
            }
        }

        // On client connection: send Ready + current screens
        socketServer.onClientConnected = {
            logger.info("Haskell client connected — sending ready event")
            socketServer.send(.ready)

            let screens = displayManager.currentScreens()
            socketServer.send(.screensChanged(screens: screens))
        }

        // Option+mouse drag: move (LMB) and resize (RMB) windows
        let dragHandler = MouseDragHandler()
        dragHandler.onDragCompleted = { windowId, pid, frame in
            socketServer.send(.windowDragCompleted(
                windowId: windowId, pid: pid, frame: frame
            ))
        }
        dragHandler.start()

        // Periodic window validation — catches windows that vanish without
        // firing SkyLight 804/1326 (e.g. quickly closed system dialogs).
        // Runs every 2 seconds on the main run loop.
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in
                eventBridge.validateWindows()
            }
        }

        // Start event observer
        eventObserver.start()

        // Start socket server (accept loop runs on background thread)
        socketServer.start()

        logger.info("mcmonad-core fully initialized")

        // Keep references alive for the lifetime of the process
        _keepAlive = (statusBar, hotkeyManager, displayManager, socketServer, executor, eventBridge, dragHandler)
    }

    // Static storage to prevent ARC from deallocating services
    nonisolated(unsafe) static var _keepAlive: Any?
}
