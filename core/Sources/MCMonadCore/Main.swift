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
            // Never report our OWN activation. mcmonad-core has no managed
            // windows, so the brain can't act on it usefully — and worse,
            // when the window-search panel takes key focus the core becomes
            // frontmost, the Haskell FocusIntent sees a divergence from the
            // window it last focused, and re-issues FocusWindow to push
            // focus back to that window. That steals key from the panel and
            // dismisses it ("blink then disappear"). Suppress at the source.
            guard pid != getpid() else { break }
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

        // 1. Check / prompt accessibility permission.
        // AX is the only permission mcmonad-core needs; without it,
        // findAXWindow returns nil for every wid, frame writes no-op,
        // focus raises no-op, and hotkeys appear to do nothing. Refuse
        // to start. The prompt dialog persists across exit; launchd
        // respawns the daemon after the user grants permission.
        let options = [
            "AXTrustedCheckOptionPrompt" as CFString: true as CFBoolean
        ] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            showFatalAlertAndExit(
                title: "mcmonad cannot start: Accessibility not granted",
                body: """
                mcmonad-core needs Accessibility permission to enumerate \
                windows and move/focus them. Without it the window manager \
                cannot function — hotkeys would fire but nothing would move.

                Grant the permission in System Settings > Privacy & Security \
                > Accessibility (toggle 'mcmonad-core' to on). After granting, \
                launchd will respawn mcmonad-core automatically.
                """,
                deepLinkSettings: true
            )
        }

        // 2. SkyLight is required — access triggers load (fatal on failure)
        _ = SkyLight.shared

        // 3. Configure as background daemon — no dock icon, no menu bar.
        // Functional checks of the AX <-> SkyLight bridge are NOT done at
        // boot: they belong to the runtime debug mode (the Haskell-owned
        // `debugOverlays` flag, toggled from the menubar). Wiring lives
        // in launchServices() — see OverlayManager.onEnabledTurnedOn.
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

        // Spotlight launcher (command runner + app launcher + window search)
        let spotlight = SpotlightController()

        // Menu-bar countdown timer widget, driven by the Spotlight launcher.
        let timerController = TimerController()

        // Create services
        let hotkeyManager = HotkeyManager()
        let displayManager = DisplayManager()
        let overlayManager = OverlayManager()

        // Create SocketServer + CommandExecutor
        let socketServer = SocketServer()
        let executor = CommandExecutor(
            hotkeyManager: hotkeyManager,
            displayManager: displayManager,
            socketServer: socketServer,
            statusBarController: statusBar,
            overlayManager: overlayManager
        )

        // Menu reads the cached snapshot from OverlayManager
        statusBar.snapshotProvider = { [weak overlayManager] in
            overlayManager?.cachedSnapshot
        }
        statusBar.onToggleDebugOverlays = { [weak socketServer] in
            socketServer?.send(.menuToggleDebug)
        }

        // When debug mode flips on (via menubar -> Haskell -> setDebugOverlays
        // -> OverlayManager.setEnabled(true)), run the AX <-> SkyLight bridge
        // probe so the user gets evidence the private SPI still works.
        overlayManager.onEnabledTurnedOn = {
            MCMonadCoreApp.probeAXSkyLightBridge()
        }
        statusBar.onFocusWindow = { [weak socketServer] wid, pid in
            socketServer?.send(.menuFocusWindow(windowId: wid, pid: pid))
        }
        statusBar.onViewWorkspace = { [weak socketServer] tag in
            socketServer?.send(.menuViewWorkspace(tag: tag))
        }

        // Spotlight launcher wiring. Window mode reads the same cached
        // snapshot the menubar tree uses and reports a pick through the
        // existing menu-focus-window path (which focuses the window and jumps
        // to its workspace). Command mode launches apps and starts timers
        // entirely inside the daemon — app launch flows back as a normal
        // window-created event; timers drive the menu-bar widget directly.
        spotlight.snapshotProvider = { [weak overlayManager] in
            overlayManager?.cachedSnapshot
        }
        spotlight.onFocusWindow = { [weak socketServer] wid, pid in
            socketServer?.send(.menuFocusWindow(windowId: wid, pid: pid))
        }
        // Starting a timer is a state change: report it to the brain (which
        // stamps the current workspace, assigns an id, persists it, and pushes
        // the list back via set-timers). No origin workspace here — the brain
        // uses whatever is current.
        spotlight.onStartTimer = { [weak socketServer] seconds, label in
            socketServer?.send(.timerStart(seconds: seconds, label: label))
        }

        // TimerController is a pure renderer/clock; its state arrives via the
        // set-timers command, and every user action flows back to the brain.
        executor.onSetTimers = { [weak timerController] timers in
            timerController?.setTimers(timers)
        }
        timerController.onFired = { [weak socketServer] id in
            socketServer?.send(.timerFired(id: id))
        }
        timerController.onCancel = { [weak socketServer] id in
            socketServer?.send(.timerCancel(id: id))
        }
        timerController.onCancelAll = { [weak socketServer] in
            socketServer?.send(.timerCancelAll)
        }
        // Snooze re-arms via the brain so the copy keeps its origin workspace.
        timerController.onSnooze = { [weak socketServer] seconds, label, workspace in
            socketServer?.send(.timerSnooze(seconds: seconds, label: label, workspace: workspace))
        }
        // "Jump to workspace": the brain switches there AND journals the jump.
        timerController.onJump = { [weak socketServer] label, workspace in
            socketServer?.send(.timerJump(label: label, workspace: workspace))
        }
        // Dismiss: reported purely so the brain can journal it (no state change).
        timerController.onDismiss = { [weak socketServer] label, workspace in
            socketServer?.send(.timerDismiss(label: label, workspace: workspace))
        }
        statusBar.onSearchWindows = { [weak spotlight] in
            spotlight?.show(mode: .window)
        }
        // Legacy Opt+Shift+P → show-window-picker → Spotlight in window mode.
        executor.onShowWindowPicker = { [weak spotlight] in
            spotlight?.toggle(mode: .window)
        }
        // Opt+P / Opt+Shift+P → Haskell → show-spotlight command → here.
        executor.onShowSpotlight = { [weak spotlight] modeStr in
            let mode: SpotlightController.Mode =
                (modeStr == "window") ? .window : .command
            spotlight?.toggle(mode: mode)
        }

        // Request mic/speech permission shortly after startup — but only once
        // the run loop is actually running. Calling requestAuthorization from
        // launchServices() (before NSApplication.run()) makes SFSpeechRecognizer
        // resolve straight to .denied without ever presenting the prompt, which
        // then poisons voiceAuthorized=false and blocks the panel from asking
        // too. Deferring onto the main actor guarantees .run() is live (and no
        // Spotlight panel is up) so the TCC prompt presents cleanly.
        Task { @MainActor [weak spotlight] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            spotlight?.primeVoiceAuthorization()
        }

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
            // Ignore our own activation — see the matching guard in
            // EventBridge.frontAppChanged for why (window-search panel
            // would otherwise be dismissed by the focus push-back).
            guard pid != getpid() else { return }
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

        // Global mouse-down monitor: surfaces a 'user has just clicked'
        // signal to the Haskell side so it can disarm 'focusIntent' and
        // honour the AX/NSWorkspace event that follows the click. See
        // 'MouseDownMonitor.swift' for the full rationale.
        let mouseDownMonitor = MouseDownMonitor()
        mouseDownMonitor.onUserMouseDown = { [weak socketServer] in
            socketServer?.send(.userMouseDown)
        }
        mouseDownMonitor.start()

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
        _keepAlive = (statusBar, hotkeyManager, displayManager, overlayManager,
                      socketServer, executor, eventBridge, dragHandler,
                      mouseDownMonitor, spotlight, timerController)
    }

    // Static storage to prevent ARC from deallocating services
    nonisolated(unsafe) static var _keepAlive: Any?

    // MARK: - Boot preconditions

    /// Verifies the AX <-> SkyLight bridge actually works on this machine
    /// right now. Enumerates visible top-level windows via SkyLight, then
    /// for each one calls AXWindowService.findAXWindow (which internally
    /// uses _AXUIElementGetWindow) to confirm the private SPI maps an
    /// AXUIElement back to the same CGWindowID SkyLight just reported.
    ///
    /// Wired to fire when the user toggles debug mode on from the menubar
    /// (which flips Haskell's `debugOverlays`, which flips
    /// `OverlayManager.setEnabled`). Non-fatal: a failure here pops an
    /// NSAlert with the breakdown but does not exit. The WM is already
    /// running and the user is the one who asked for the diagnostic.
    @MainActor
    static func probeAXSkyLightBridge() {
        let snapshots = SkyLightQuery.queryAllVisibleWindows()

        guard !snapshots.isEmpty else {
            logger.fault(
                "AX<->SkyLight bridge probe found no visible top-level windows. Bridge cannot be exercised right now."
            )
            return
        }

        let ownPid = getpid()
        var bridged = 0
        var failureCounts: [String: Int] = [:]

        for snap in snapshots {
            if snap.pid == ownPid { continue }
            if AXWindowService.findAXWindow(
                windowId: snap.windowId,
                pid: snap.pid
            ) != nil {
                bridged += 1
                continue
            }
            failureCounts[classifyAXFailure(pid: snap.pid), default: 0] += 1
        }

        logger.info(
            "AX<->SkyLight bridge probe: \(bridged)/\(snapshots.count) windows bridged"
        )

        if bridged == 0 {
            let summary = failureCounts
                .map { "\($0.key)=\($0.value)" }
                .sorted()
                .joined(separator: ", ")
            showNonFatalAlert(
                title: "AX <-> SkyLight bridge is broken",
                body: """
                mcmonad enumerated \(snapshots.count) visible windows via \
                SkyLight but could not map any of them back to an \
                AXUIElement. Without this mapping (private SPI \
                _AXUIElementGetWindow), mcmonad cannot resize, focus, or \
                close any window — every operation will silently no-op.

                Failure breakdown: \(summary)

                Most likely cause: Accessibility permission for mcmonad-core \
                was revoked or its code signature changed since being \
                granted. Re-grant it in System Settings > Privacy & \
                Security > Accessibility. If the problem persists after a \
                re-grant, this macOS version may have removed \
                _AXUIElementGetWindow and mcmonad needs to be updated.
                """
            )
        }
    }

    /// Inspect why findAXWindow failed for a given pid so the user gets
    /// an actionable failure breakdown rather than a count of nils.
    private static func classifyAXFailure(pid: pid_t) -> String {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsRef
        )
        switch result {
        case .success: return "no-matching-wid-in-ax-windows"
        case .cannotComplete: return "ax-cannot-complete"
        case .apiDisabled: return "ax-api-disabled"
        case .notImplemented: return "ax-not-implemented"
        case .invalidUIElement: return "ax-invalid-ui-element"
        default: return "ax-error-\(result.rawValue)"
        }
    }

    /// Show a critical NSAlert and return without exiting. Used for
    /// runtime diagnostic failures (e.g. AX<->SkyLight bridge probe in
    /// debug mode).
    @MainActor
    private static func showNonFatalAlert(title: String, body: String) {
        let msg = "\(title)\n\(body)"
        logger.fault("\(msg, privacy: .public)")
        fputs("mcmonad-core: \(msg)\n", stderr)

        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Dismiss")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn,
           let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
           ) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Show a critical NSAlert with the supplied body and exit(78). Used
    /// for unrecoverable boot-time precondition failures so the user gets
    /// an actionable popup instead of a silent daemon that pretends to
    /// work. Returns Never.
    private static func showFatalAlertAndExit(
        title: String,
        body: String,
        deepLinkSettings: Bool
    ) -> Never {
        let stderrMsg = "\(title)\n\(body)"
        logger.fault("\(stderrMsg, privacy: .public)")
        fputs("mcmonad-core: \(stderrMsg)\n", stderr)

        // NSApp/NSAlert are MainActor-isolated. main() is the program
        // entry point, so we are on the main thread, but the compiler
        // doesn't know that — assumeIsolated tells it explicitly.
        MainActor.assumeIsolated {
            // Temporarily become a regular app so the alert can take
            // focus. We exit immediately after, so this never conflicts
            // with the .accessory policy on the success path.
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            app.activate(ignoringOtherApps: true)

            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = body
            alert.alertStyle = .critical

            if deepLinkSettings {
                alert.addButton(withTitle: "Open Accessibility Settings")
                alert.addButton(withTitle: "Quit")
                let response = alert.runModal()
                if response == .alertFirstButtonReturn,
                   let url = URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                   ) {
                    NSWorkspace.shared.open(url)
                }
            } else {
                alert.addButton(withTitle: "Quit")
                _ = alert.runModal()
            }
        }

        exit(78) // EX_CONFIG
    }
}
