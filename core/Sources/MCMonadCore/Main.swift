import AppKit
@preconcurrency import ApplicationServices
import os

private let logger = Logger(subsystem: "com.mcmonad.core", category: "Main")

/// Bridges SkyLightEventObserver delegate events to the socket server.
@MainActor
final class EventBridge: SkyLightEventDelegate {
    let socketServer: SocketServer

    init(socketServer: SocketServer) {
        self.socketServer = socketServer
    }

    func skyLightEventObserver(
        _ observer: SkyLightEventObserver,
        didReceive event: CGSWindowEvent
    ) {
        switch event {
        case .created(let windowId, _):
            // Query SkyLight for the snapshot, then enrich with AX
            if let snap = SkyLightQuery.queryWindow(windowId) {
                // Subscribe to per-window notifications for close events
                observer.subscribeToWindows([windowId])

                let info = AXWindowService.info(
                    windowId: snap.windowId,
                    pid: snap.pid
                ) ?? WindowInfo(
                    windowId: snap.windowId,
                    pid: snap.pid,
                    title: nil,
                    appName: nil,
                    bundleId: nil,
                    subrole: nil,
                    isDialog: false,
                    isFixedSize: false,
                    hasCloseButton: false,
                    hasFullscreenButton: false,
                    frame: snap.frame
                )
                socketServer.send(.windowCreated(info))
            }

        case .destroyed(let windowId, _):
            socketServer.send(.windowDestroyed(windowId: windowId))

        case .closed(let windowId):
            socketServer.send(.windowDestroyed(windowId: windowId))

        case .frameChanged(let windowId):
            if let bounds = SkyLight.shared?.getWindowBounds(windowId) {
                socketServer.send(.windowFrameChanged(windowId: windowId, frame: bounds))
            }

        case .frontAppChanged(let pid):
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

        // 2. Verify SkyLight loaded
        if SkyLight.shared == nil {
            logger.error(
                "SkyLight framework failed to load — window management unavailable"
            )
        }

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
        // Create services
        let hotkeyManager = HotkeyManager()
        let displayManager = DisplayManager()

        // Create SocketServer + CommandExecutor
        let socketServer = SocketServer()
        let executor = CommandExecutor(
            hotkeyManager: hotkeyManager,
            displayManager: displayManager,
            socketServer: socketServer
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

        // On client connection: send Ready + current screens
        socketServer.onClientConnected = {
            logger.info("Haskell client connected — sending ready event")
            socketServer.send(.ready)

            let screens = displayManager.currentScreens()
            socketServer.send(.screensChanged(screens: screens))
        }

        // TODO: focus-follows-mouse disabled — CGEventTap interferes with
        // right-click context menus. Needs a different approach (SkyLight
        // window-under-cursor query instead of CGEventTap).

        // Start event observer
        eventObserver.start()

        // Start socket server (accept loop runs on background thread)
        socketServer.start()

        logger.info("mcmonad-core fully initialized")

        // Keep references alive for the lifetime of the process
        _keepAlive = (hotkeyManager, displayManager, socketServer, executor, eventBridge)
    }

    // Static storage to prevent ARC from deallocating services
    nonisolated(unsafe) static var _keepAlive: Any?
}
