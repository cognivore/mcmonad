import AppKit
@preconcurrency import ApplicationServices
import os

private let logger = Logger(subsystem: "com.mcmonad.core", category: "Main")

/// Bridges SkyLightEventObserver delegate events to the socket server.
@MainActor
final class EventBridge: SkyLightEventDelegate {
    let socketServer: SocketServer
    let focusTracker: AXFocusTracker
    /// Window IDs we have reported as created but not yet destroyed.
    private var managedWindowIds: Set<UInt32> = []
    /// Reverse map for destroy/close events (which only carry wid).
    private var windowIdToPid: [UInt32: pid_t] = [:]
    /// Per-PID set of currently-managed window ids. Drives trackApp/
    /// untrackApp so the AX observer for an app exists exactly when at
    /// least one of its windows is managed.
    private var pidWindowIds: [pid_t: Set<UInt32>] = [:]

    init(socketServer: SocketServer, focusTracker: AXFocusTracker) {
        self.socketServer = socketServer
        self.focusTracker = focusTracker
    }

    /// Bootstrap entry for windows that already existed when mcmonad-core
    /// started — every window that didn't come through a SkyLight
    /// 'created' event in this process. Without this, AX focus events
    /// never fire for those apps after a daemon restart and the
    /// cross-window focus-precision fix degrades to its PID-only
    /// fallback. Called by 'CommandExecutor.executeQueryWindows' just
    /// before the response is sent to Haskell.
    func bootstrapExistingWindow(windowId: UInt32, pid: pid_t) {
        addManagedWindow(windowId: windowId, pid: pid)
    }

    /// Register a managed window. Starts AX focus tracking for the PID on
    /// the first window of that PID.
    private func addManagedWindow(windowId: UInt32, pid: pid_t) {
        managedWindowIds.insert(windowId)
        windowIdToPid[windowId] = pid
        let wasEmpty = (pidWindowIds[pid]?.isEmpty ?? true)
        pidWindowIds[pid, default: []].insert(windowId)
        if wasEmpty {
            focusTracker.trackApp(pid: pid)
        }
    }

    /// Unregister a managed window. Stops AX focus tracking for the PID
    /// once the last window of that PID is gone.
    private func removeManagedWindow(windowId: UInt32) {
        managedWindowIds.remove(windowId)
        guard let pid = windowIdToPid.removeValue(forKey: windowId) else { return }
        if var wids = pidWindowIds[pid] {
            wids.remove(windowId)
            if wids.isEmpty {
                pidWindowIds.removeValue(forKey: pid)
                focusTracker.untrackApp(pid: pid)
            } else {
                pidWindowIds[pid] = wids
            }
        }
    }

    /// Check all managed windows still exist in the window server.
    /// Fire windowDestroyed for any that have vanished.
    func validateWindows() {
        let stale = managedWindowIds.filter { wid in
            SkyLightQuery.queryWindow(wid) == nil
        }
        for wid in stale {
            removeManagedWindow(windowId: wid)
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
                addManagedWindow(windowId: windowId, pid: snap.pid)
                socketServer.send(.windowCreated(info))
            }

        case .destroyed(let windowId, _):
            removeManagedWindow(windowId: windowId)
            TitleHash.invalidate(windowId: windowId)
            socketServer.send(.windowDestroyed(windowId: windowId))

        case .closed(let windowId):
            removeManagedWindow(windowId: windowId)
            TitleHash.invalidate(windowId: windowId)
            socketServer.send(.windowDestroyed(windowId: windowId))

        case .frameChanged(let windowId):
            if let bounds = SkyLight.shared.getWindowBounds(windowId) {
                FrameLog.emit(source: .observed, windowId: windowId, rect: bounds,
                              tHash: TitleHash.hash(windowId: windowId))
                socketServer.send(.windowFrameChanged(windowId: windowId, frame: bounds))
            } else {
                FrameLog.emit(source: .observed, windowId: windowId,
                              tHash: TitleHash.hash(windowId: windowId),
                              result: "no-bounds")
            }

        case .frontAppChanged(let pid):
            // Validate managed windows — catch closes that SkyLight missed
            validateWindows()
            FocusLog.emit(source: .emitFrontAppChanged, pid: pid,
                          extra: "via=skylightBridge")
            socketServer.send(.frontAppChanged(pid: pid))

        case .titleChanged(let windowId):
            // Title changes are not forwarded over IPC in the current
            // protocol, but we drop the cached hash so the next
            // FRAME/FOCUS line for this window picks up the new title.
            TitleHash.invalidate(windowId: windowId)
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

        // Wire AXFocusTracker — gives us per-window focus events from AX,
        // which carry the actual focused windowId (unlike SkyLight 1508 and
        // NSWorkspace activation, which only know the app PID). Without
        // this, multi-window apps (browsers, etc.) collapse to "focus the
        // first window of this PID" when the user clicks any of them.
        let focusTracker = AXFocusTracker()
        AXFocusTracker.shared = focusTracker
        focusTracker.onFocusedWindowChanged = { [weak socketServer] windowId, pid in
            FocusLog.emit(source: .emitFocusedWindowChanged,
                          windowId: windowId, pid: pid,
                          extra: "via=axFocusedWindowChanged")
            socketServer?.send(.focusedWindowChanged(windowId: windowId, pid: pid))
        }

        // Wire SkyLightEventObserver (singleton, delegate-based) to socket
        let eventBridge = EventBridge(socketServer: socketServer, focusTracker: focusTracker)
        let eventObserver = SkyLightEventObserver.shared
        eventObserver.delegate = eventBridge

        // Bootstrap existing-at-startup windows into the event bridge so
        // their pids enrol AXFocusTracker. SkyLight 'created' only fires
        // for windows born after the observer started, so a daemon
        // restart needs this fallback path through QueryWindows.
        executor.onExistingWindowsEnumerated = { [weak eventBridge] windowInfos in
            guard let eventBridge else { return }
            for info in windowInfos {
                eventBridge.bootstrapExistingWindow(windowId: info.windowId, pid: info.pid)
            }
        }

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
            FocusLog.emit(source: .nsWorkspaceActivation, pid: pid,
                          extra: "appBundleId=\(app.bundleIdentifier ?? "-")")
            Task { @MainActor in
                FocusLog.emit(source: .emitFrontAppChanged, pid: pid,
                              extra: "via=nsWorkspaceActivation")
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
