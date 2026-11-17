import AppKit
@preconcurrency import ApplicationServices
import os

private let logger = Logger(subsystem: "com.mcmonad.core", category: "Main")

/// Bridges SkyLightEventObserver delegate events to the socket server.
@MainActor
final class EventBridge: SkyLightEventDelegate {
    let socketServer: SocketServer
    let focusTracker: AXFocusTracker
    let displayManager: DisplayManager
    /// Window IDs we have reported as created but not yet destroyed.
    private var managedWindowIds: Set<UInt32> = []
    /// Reverse map for destroy/close events (which only carry wid).
    private var windowIdToPid: [UInt32: pid_t] = [:]
    /// Per-PID set of currently-managed window ids. Drives trackApp/
    /// untrackApp so the AX observer for an app exists exactly when at
    /// least one of its windows is managed.
    private var pidWindowIds: [pid_t: Set<UInt32>] = [:]
    /// Negative cache for `adoptOrphanWindows`: window id -> the sweep
    /// tick at which AX classification last rejected it.
    ///
    /// Without this the sweep would re-run a cross-process AX round-trip
    /// every 2s, forever, for every window that SkyLight considers
    /// visible but AX classifies as unmanageable (palettes, helper
    /// windows, anything without a close button) — of which a busy
    /// desktop has many. Entries are retried on a backoff rather than
    /// blacklisted permanently, because an AX read can fail transiently
    /// when the owning app is busy and a window that was genuinely
    /// unmanageable at one moment may not be at the next.
    private var rejectedWindowIds: [UInt32: Int] = [:]
    /// Monotonic sweep counter, the clock for `rejectedWindowIds`.
    private var sweepTick = 0
    /// Managed window id -> number of consecutive reconcile sweeps it has
    /// existed in the window server but failed the manage-eligibility
    /// filter. See `validateWindows`.
    private var ineligibleStreak: [UInt32: Int] = [:]

    /// Sweeps to wait before re-testing a window AX previously rejected.
    /// 15 ticks x 2s = ~30s, so the steady-state cost of a permanently
    /// unmanageable window is one AX call per 30s instead of one per 2s.
    private static let rejectRetryTicks = 15
    /// Upper bound on the negative cache. Purely a leak guard: entries
    /// are normally evicted when their window is destroyed.
    private static let rejectCacheCap = 1024
    /// Consecutive sweeps a managed window may exist-but-fail-eligibility
    /// before it is retired. A native fullscreen Space transition makes a
    /// live window fail eligibility for a fraction of a second (well under
    /// one 2s sweep); an app that hid its window instead of destroying it
    /// (Adobe's around-quit panels) fails it indefinitely. 5 x 2s = 10s
    /// cleanly separates the two: the transition never accrues a streak,
    /// the hidden window always crosses the threshold.
    private static let ineligibleRetireStreak = 5

    /// System-UI processes whose windows must never be managed, even
    /// though they pass the close-button test. macOS notification alerts
    /// (UserNotificationCenter) are level-0 windows WITH close buttons —
    /// on 2026-07-24 they were being tiled 1146x1410 onto whatever
    /// workspace was current, focused, and then auto-dismissed seconds
    /// later, hijacking the layout and stealing focus on every system
    /// notification. Notification Center's banner daemon is included for
    /// completeness (its banners are normally filtered by level anyway).
    private static let systemUIBundleIds: Set<String> = [
        "com.apple.UserNotificationCenter",
        "com.apple.notificationcenterui",
    ]

    init(socketServer: SocketServer, focusTracker: AXFocusTracker, displayManager: DisplayManager) {
        self.socketServer = socketServer
        self.focusTracker = focusTracker
        self.displayManager = displayManager
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

    /// The periodic reconcile, run on a 2s timer from `main`.
    ///
    /// Two halves that must stay paired. `validateWindows` retires
    /// windows that are gone; `adoptOrphanWindows` picks up windows that
    /// exist and are manageable but that the brain has never been told
    /// about. Before the adopt half existed, *any* way of losing a
    /// window — a spurious destroy, a missed SkyLight 1325, an IPC write
    /// that landed while the brain was restarting — was permanent: the
    /// window stayed alive and on screen with nobody to park it. Now the
    /// worst case is a ~2s glitch.
    func reconcileWindows() {
        sweepTick &+= 1
        validateWindows()
        adoptOrphanWindows()
    }

    /// Retire managed windows that are gone, or that have persistently
    /// stopped being manageable.
    ///
    /// Two retirement reasons, separated by *time*, because no single
    /// SkyLight bit tells them apart:
    ///
    ///   `gone`  — the window server has no record at all. Retire at once.
    ///     `windowExists` is unfiltered on purpose: a live window mid
    ///     native-fullscreen transition transiently fails the eligibility
    ///     filter (visible attribute cleared, tags reshuffled), and the
    ///     old code — which used the *filtered* query as its liveness
    ///     test — retired those, orphaning them with no way back. That was
    ///     the "LibreWolf/Chrome as a background on every workspace" flood.
    ///
    ///   `hidden` — the record exists but the window has failed the
    ///     manage-eligibility filter for `ineligibleRetireStreak`
    ///     consecutive sweeps (~10s). Some apps hide a window instead of
    ///     destroying it (Adobe's around-quit Creative Cloud panels), so
    ///     it lingers forever, eligible for a layout tile it can never
    ///     fill — a ghost. A fullscreen transition never lasts a whole
    ///     2s sweep, so it never accrues a streak; a genuinely hidden
    ///     window always crosses the threshold. `windowExists` was too
    ///     permissive on its own; this is the missing upper bound.
    func validateWindows() {
        let screens = displayManager.currentScreens()
        // Snapshot: `retire` mutates `managedWindowIds`.
        for wid in Array(managedWindowIds) {
            if !SkyLightQuery.windowExists(wid) {
                retire(wid, reason: "gone")
                continue
            }
            // Present in the server. Is it still a manageable window?
            if SkyLightQuery.queryWindow(wid) != nil {
                ineligibleStreak.removeValue(forKey: wid)
                continue
            }
            // queryWindow's eligibility filter (visible attribute / tag
            // bits) can transiently fail for a window mcmonad has parked
            // off-screen to simulate a hidden workspace — an unrelated
            // app's own hide/show or Space churn can knock SkyLight's
            // bookkeeping around enough to do this for several seconds.
            // A parked window is never a mystery (mcmonad put it exactly
            // there), so confirm via the live AX frame — same ground
            // truth parking itself writes to, per restoreAllParkedWindows
            // — before trusting queryWindow's verdict.
            if let pid = windowIdToPid[wid],
               let frame = AXWindowService.readFrame(windowId: wid, pid: pid),
               isAlreadyParked(frame, screens: screens) {
                ineligibleStreak.removeValue(forKey: wid)
                continue
            }
            let streak = (ineligibleStreak[wid] ?? 0) + 1
            if streak >= Self.ineligibleRetireStreak {
                retire(wid, reason: "hidden")
            } else {
                ineligibleStreak[wid] = streak
            }
        }
    }

    /// A destroy/close is only spurious if the window still exists AND its
    /// owning app still lists it via AX — `windowExists` alone can stay
    /// true for a window an app has already swapped out internally,
    /// leaving a dead id as a phantom layout slot for seconds otherwise.
    private func isSpuriousDestroy(_ windowId: UInt32, stillExists: Bool) -> Bool {
        guard stillExists else { return false }
        guard let pid = windowIdToPid[windowId] else { return false }
        return AXWindowService.findAXWindow(windowId: windowId, pid: pid) != nil
    }

    /// Retract a managed window from the brain and clear its bookkeeping.
    private func retire(_ wid: UInt32, reason: String) {
        let pid = windowIdToPid[wid].map { String($0) } ?? "-"
        removeManagedWindow(windowId: wid)
        rejectedWindowIds.removeValue(forKey: wid)
        ineligibleStreak.removeValue(forKey: wid)
        socketServer.send(.windowDestroyed(windowId: wid))
        logStderr("RECONCILE: retire wid=\(wid) pid=\(pid) reason=\(reason)\n")
    }

    /// Report any manageable window the brain has never heard about.
    ///
    /// `managedWindowIds` is the dedupe key: it means "reported to the
    /// brain and not yet retracted", so a window the brain's manage hook
    /// deliberately ignored is still in it and is never re-offered. That
    /// is what stops this sweep from re-running the manage hook — and
    /// the whole layout pass behind it — every 2 seconds.
    func adoptOrphanWindows() {
        let ownPid = getpid()
        for snap in SkyLightQuery.queryAllVisibleWindows() {
            guard snap.pid != ownPid else { continue }
            guard !managedWindowIds.contains(snap.windowId) else { continue }
            if let rejectedAt = rejectedWindowIds[snap.windowId],
               sweepTick - rejectedAt < Self.rejectRetryTicks {
                continue
            }
            adoptWindow(snap, viaSweep: true)
        }
    }

    /// Classify a SkyLight snapshot with AX and, if it is manageable,
    /// register it and tell the brain. Shared by the SkyLight `created`
    /// event and the orphan sweep so both apply exactly the same filter.
    private func adoptWindow(_ snap: WindowSnapshot, viaSweep: Bool = false) {
        // Never manage our own panels and overlays.
        guard snap.pid != getpid() else { return }

        guard let info = AXWindowService.info(
            windowId: snap.windowId,
            pid: snap.pid
        ) else {
            // Can't read AX info — menus, tooltips, or a busy app.
            noteRejected(snap.windowId)
            return
        }

        // Only manage windows that have a close button — this filters
        // out context menus, tooltips, popups, and other transient UI
        guard info.hasCloseButton else {
            noteRejected(snap.windowId)
            return
        }

        // System notification alerts pass the close-button test but are
        // transient UI all the same — never manage them.
        if let bundleId = info.bundleId,
           Self.systemUIBundleIds.contains(bundleId) {
            noteRejected(snap.windowId)
            return
        }

        rejectedWindowIds.removeValue(forKey: snap.windowId)
        _ = SkyLightEventObserver.shared.subscribeToWindows([snap.windowId])
        addManagedWindow(windowId: snap.windowId, pid: snap.pid)
        socketServer.send(.windowCreated(info))
        if viaSweep {
            // Should be rare. A run of these means windows are being lost
            // somewhere upstream and the sweep is papering over it.
            logStderr(
                "RECONCILE: adopt wid=\(snap.windowId) pid=\(snap.pid) "
                    + "tHash=\(TitleHash.hash(windowId: snap.windowId, pid: snap.pid))\n"
            )
        }
    }

    /// Record an AX-classification rejection, evicting the oldest
    /// entries if the cache has grown past its cap.
    private func noteRejected(_ windowId: UInt32) {
        rejectedWindowIds[windowId] = sweepTick
        guard rejectedWindowIds.count > Self.rejectCacheCap else { return }
        let keep = rejectedWindowIds
            .sorted { $0.value > $1.value }
            .prefix(Self.rejectCacheCap)
            .map { ($0.key, $0.value) }
        rejectedWindowIds = Dictionary(uniqueKeysWithValues: keep)
    }

    func skyLightEventObserver(
        _: SkyLightEventObserver,
        didReceive event: CGSWindowEvent
    ) {
        switch event {
        case .created(let windowId, _):
            // A created notification can be spurious — SkyLight fires one
            // for a window that's already managed, most commonly around a
            // cross-screen AX move. Re-adopting it would re-run the manage
            // hook and a full layout pass for a window the brain already
            // knows about, so a window already in `managedWindowIds` is
            // left alone.
            guard !managedWindowIds.contains(windowId) else {
                logStderr("RECONCILE: ignore created wid=\(windowId) reason=already-managed\n")
                break
            }
            if let snap = SkyLightQuery.queryWindow(windowId) {
                adoptWindow(snap)
            }

        case .destroyed(let windowId, _):
            let stillExists = SkyLightQuery.windowExists(windowId)
            // A destroy notification can be spurious — SkyLight fires one
            // for a window that's still alive, most commonly around a
            // cross-screen AX move. Trusting it blindly means unmanaging a
            // live window and telling the brain it's gone, which the
            // reconcile sweep then "fixes" a couple seconds later by
            // re-adopting it as brand new — sending it through the manage
            // hook and a full layout pass again, which is what actually
            // causes focus to jump. Verify liveness first, the same way
            // `validateWindows` already does for its own check.
            guard !isSpuriousDestroy(windowId, stillExists: stillExists) else {
                logStderr("RECONCILE: ignore destroyed wid=\(windowId) reason=still-exists\n")
                break
            }
            removeManagedWindow(windowId: windowId)
            rejectedWindowIds.removeValue(forKey: windowId)
            ineligibleStreak.removeValue(forKey: windowId)
            TitleHash.invalidate(windowId: windowId)
            socketServer.send(.windowDestroyed(windowId: windowId))

        case .closed(let windowId):
            let stillExists = SkyLightQuery.windowExists(windowId)
            guard !isSpuriousDestroy(windowId, stillExists: stillExists) else {
                logStderr("RECONCILE: ignore closed wid=\(windowId) reason=still-exists\n")
                break
            }
            removeManagedWindow(windowId: windowId)
            rejectedWindowIds.removeValue(forKey: windowId)
            ineligibleStreak.removeValue(forKey: windowId)
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
            TitleHash.invalidate(windowId: windowId)
            guard let pid = windowIdToPid[windowId] else { break }
            if let title = SkyLight.shared.getWindowTitle(windowId) {
                socketServer.send(.windowTitleChanged(windowId: windowId, pid: pid, title: title))
            } else if let info = AXWindowService.info(windowId: windowId, pid: pid) {
                socketServer.send(.windowTitleChanged(windowId: windowId, pid: pid, title: info.title))
            }
        }
    }

    /// Puts every parked window back in the middle of its screen. Hidden
    /// workspaces are not macOS Spaces: their windows are parked almost
    /// entirely off screen (see 'executeHideWindows'), so a daemon that
    /// stops for good would otherwise leave them stranded there.
    ///
    /// Only windows that are parked right now are touched. A visible
    /// window is already where the user can reach it, and so is one that
    /// drifted back on screen, so there is nothing to rescue and moving
    /// it would only scramble the layout on every restart.
    ///
    /// Exception to Rule 1 (no window-placement decisions in core): this is
    /// an exit-time mitigation. It runs after mcmonad has stopped taking
    /// layout actions, so the brain is not involved and no frames are sent
    /// to it for this purpose.
    func restoreParkedWindows() {
        let screens = displayManager.currentScreens()
        guard !screens.isEmpty else { return }
        for wid in managedWindowIds {
            // SkyLightQuery's cached frame can lag behind an AX-only move
            // (parking is done via AX, which SkyLight doesn't resync on) —
            // read the live AX frame instead, same ground truth parking
            // itself writes to.
            guard let pid = windowIdToPid[wid],
                  let frame = AXWindowService.readFrame(windowId: wid, pid: pid),
                  isAlreadyParked(frame, screens: screens),
                  let home = homeScreen(for: frame, among: screens)
            else { continue }
            AXWindowService.setFrame(
                centeredFrame(of: frame.size, on: home.frame),
                windowId: wid,
                pid: pid,
                currentHint: frame
            )
        }
    }
}

/// Runs `cleanup` on the main queue when the process is asked to stop
/// (SIGTERM from launchd or `kill`, SIGINT from a terminal), then exits.
/// SIGKILL cannot be observed, so a hard kill still skips it.
///
/// The signals are delivered through dispatch sources, not a `signal()`
/// handler: a handler runs on whatever the interrupted thread was doing,
/// where allocating (as starting a Task does) can deadlock inside malloc
/// and leave the daemon neither running nor exited.
@MainActor
final class TerminationWatch {
    private var sources: [DispatchSourceSignal] = []

    init(cleanup: @escaping @MainActor () -> Void) {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)   // hand the signal to the dispatch source
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    cleanup()
                    exit(0)
                }
            }
            source.resume()
            sources.append(source)
        }
    }
}

/// How long one Accessibility call may wait for an application to answer.
/// Long enough for a busy but live application, short enough that a hung
/// one costs a layout pass a second or two and not a minute.
private let axMessagingTimeout: Float = 1.0

@main
struct MCMonadCoreApp {
    static func main() {
        logger.info("mcmonad-core starting")

        // Writing to a socket or pipe whose reader has gone raises SIGPIPE,
        // whose default action ends the process. The brain exiting between
        // two events, or the model CLI exiting before it has read its
        // prompt, must surface as a failed write and nothing more.
        signal(SIGPIPE, SIG_IGN)

        // One application that has stopped answering Accessibility calls
        // must not stop the daemon. Every AX read and write here runs on
        // the main thread, and the default wait is about six seconds per
        // call; a layout pass makes several calls per window. Setting the
        // timeout on the system-wide element applies it to every element
        // this process creates.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), axMessagingTimeout)

        // 1. Check / prompt accessibility permission.
        // Remember what the executable looked like at launch, so a later
        // deploy that replaces the bundle under this process is recognisable.
        PermissionAudit.rememberLaunch()

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

        // What is kept of questions to the models once they are over: receipts
        // with no text in them, under claude.json's retention policy.
        let askLedger = AskLedger()
        statusBar.recentAsks = { [weak askLedger] in
            askLedger.map { ($0.recent(), $0.retention) } ?? ([], Ask.Retention())
        }

        // Spotlight launcher (command runner + app launcher + window search)
        let spotlight = SpotlightController(askLedger: askLedger)

        // Menu-bar countdown timer widget, driven by the Spotlight launcher.
        let timerController = TimerController()

        // Create services
        let hotkeyManager = HotkeyManager()
        let displayManager = DisplayManager()
        let overlayManager = OverlayManager()

        // Create SocketServer + CommandExecutor
        let socketServer = SocketServer()
        let queryServer = QueryServer(snapshotBox: overlayManager.snapshotBox, socketServer: socketServer)
        queryServer.start()
        let executor = CommandExecutor(
            hotkeyManager: hotkeyManager,
            displayManager: displayManager,
            socketServer: socketServer,
            statusBarController: statusBar,
            overlayManager: overlayManager
        )

        // In-memory OCR index of displayed windows. Idle until the brain's
        // config says on (the default); its text never leaves this process.
        let screenIndex = ScreenIndex()
        spotlight.screenIndex = screenIndex
        statusBar.screenIndexStatus = { [weak screenIndex] in screenIndex?.status ?? "off" }
        executor.onSetOcrIndex = { [weak screenIndex] on in
            screenIndex?.setEnabled(on)
        }
        // "What's up" summaries, kept current by the same reports: every
        // snapshot and every re-read re-fingerprints the workspaces, and
        // only the changed ones ever go back to the model — and only while
        // the user is away, which is when a recap is wanted.
        let whatsUpCache = WhatsUpCache(
            text: { [weak screenIndex] wid in screenIndex?.entry(for: wid)?.text },
            textHash: { [weak screenIndex] wid in screenIndex?.entry(for: wid)?.textHash },
            quiet: { ScreenIndex.secondsSinceInput() >= ScreenIndex.idleAfter },
            runner: AskRunner(ledger: askLedger)
        )
        spotlight.whatsUpCache = whatsUpCache
        statusBar.whatsUpMonitoringEnabled = { [weak whatsUpCache] in whatsUpCache?.isEnabled ?? false }
        statusBar.onSetWhatsUpMonitoring = { [weak whatsUpCache] in whatsUpCache?.setEnabled($0) }
        overlayManager.onSnapshotApplied = { [weak screenIndex, weak whatsUpCache, weak statusBar] snapshot in
            screenIndex?.noteSnapshot(snapshot)
            whatsUpCache?.noteSnapshot(snapshot)
            statusBar?.refreshIcon()
        }
        screenIndex.onUpdated = { [weak spotlight, weak whatsUpCache] in
            spotlight?.screenIndexUpdated()
            whatsUpCache?.noteTextChanged()
        }
        screenIndex.onPassEnded = { [weak spotlight, weak whatsUpCache] forced in
            // The idle pass is the recap for when the user steps away; a
            // forced one belongs to the "!" query that asked for it.
            if !forced { whatsUpCache?.refreshNow() }
            spotlight?.screenIndexPassEnded(forced: forced)
        }
        whatsUpCache.onUpdated = { [weak spotlight] in
            spotlight?.whatsUpUpdated()
        }

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
        // A "what's up" row: view that workspace, same path as the menubar tree.
        spotlight.onViewWorkspace = { [weak socketServer] tag in
            socketServer?.send(.menuViewWorkspace(tag: tag))
        }
        // Screen roles: the launcher lists the attached displays with the
        // roles this daemon assigned them; a pick is remembered here and
        // reaches the brain as a fresh screens-changed.
        spotlight.displays = { [weak displayManager] in
            guard let displayManager else { return [] }
            let roles = displayManager.currentRoles()
            return displayManager.attachedDisplays().compactMap { d in
                roles[d.uuid].map { (d, $0) }
            }
        }
        spotlight.onSetScreenRole = { [weak displayManager] uuid, role in
            displayManager?.assign(role, to: uuid)
        }
        // Starting a timer is a state change: report it to the brain (which
        // stamps the current workspace, assigns an id, persists it, and pushes
        // the list back via set-timers). No origin workspace here — the brain
        // uses whatever is current.
        spotlight.onStartTimer = { [weak socketServer] seconds, label in
            socketServer?.send(.timerStart(seconds: seconds, label: label))
        }

        // The "later" inbox: on when this mcmonad was built with `later`
        // (services.mcmonad.later), otherwise nothing of it shows. `later`
        // owns the beads; this reads them, saves to them, and keeps the
        // ready count in the menu bar. Going back to a bead's window or workspace
        // uses the same paths as the menubar tree.
        let later = LaterController(cli: LaterInbox.inBundle())
        spotlight.later = later
        later.snapshotProvider = { [weak overlayManager] in overlayManager?.cachedSnapshot }
        later.onFocusWindow = { [weak socketServer] wid, pid in
            socketServer?.send(.menuFocusWindow(windowId: wid, pid: pid))
        }
        later.onViewWorkspace = { [weak socketServer] tag in
            socketServer?.send(.menuViewWorkspace(tag: tag))
        }
        later.onOpenLauncher = { [weak spotlight] id in spotlight?.showLater(at: id) }
        later.onOpenLauncherWithText = { [weak spotlight] text in
            spotlight?.show(mode: .command, typing: text)
        }
        later.onChanged = { [weak spotlight] in spotlight?.laterUpdated() }

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
            let mode: SpotlightController.Mode
            switch modeStr {
            case "window": mode = .window
            // `showSpotlight "later"` in mcmonad.hs; command mode while the inbox is off.
            case "later": mode = .later
            default: mode = .command
            }
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

        // Public socket for external apps (e.g. alt-tab) to request window focus.
        // Accepts {"cmd":"focus-window","windowId":N,"pid":P} and injects it as a
        // menu-focus-window event so the Haskell brain handles it through its normal
        // focus path (workspace switch + unpark + focusIntent armed).
        // Wire AXFocusTracker — gives us per-window focus events from AX,
        // which carry the actual focused windowId (unlike SkyLight 1508 and
        // NSWorkspace activation, which only know the app PID). Without
        // this, multi-window apps (browsers, etc.) collapse to "focus the
        // first window of this PID" when the user clicks any of them.
        let focusTracker = AXFocusTracker()
        AXFocusTracker.shared = focusTracker
        focusTracker.onFocusedWindowChanged = { [weak socketServer, weak spotlight] windowId, pid in
            FocusLog.emit(source: .emitFocusedWindowChanged,
                          windowId: windowId, pid: pid,
                          extra: "via=axFocusedWindowChanged")
            // The brain decides whether the window lives on a hidden workspace
            // and switches to it; Swift only reports the AX focus event.
            socketServer?.send(.focusedWindowChanged(windowId: windowId, pid: pid))
            // Recency for the launcher's lists.
            spotlight?.recentUse.touch(RecentUse.window(windowId))
        }

        // Wire SkyLightEventObserver (singleton, delegate-based) to socket
        let eventBridge = EventBridge(socketServer: socketServer, focusTracker: focusTracker, displayManager: displayManager)
        let eventObserver = SkyLightEventObserver.shared
        eventObserver.delegate = eventBridge

        let terminationWatch = TerminationWatch { [weak eventBridge] in
            eventBridge?.restoreParkedWindows()
        }

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
        displayManager.onScreensChanged = { [weak statusBar] screens in
            socketServer.send(.screensChanged(screens: screens))
            // The connected-screen count just changed; redraw with
            // whatever snapshot is cached now (Haskell's own screens-
            // changed-triggered snapshot will correct it moments later).
            statusBar?.refreshIcon()
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

        // Periodic reconcile — retires windows that vanished without
        // firing SkyLight 804/1326 (e.g. quickly closed system dialogs),
        // and adopts manageable windows the brain was never told about.
        // Runs every 2 seconds on the main run loop.
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in
                eventBridge.reconcileWindows()
            }
        }

        // Start event observer
        eventObserver.start()

        // Start socket server (accept loop runs on background thread)
        socketServer.start()

        logger.info("mcmonad-core fully initialized")
        for line in PermissionAudit.take() {
            logStderr("PERMS: \(line.label)=\(line.value)\n")
        }

        // Keep references alive for the lifetime of the process
        _keepAlive = (statusBar, hotkeyManager, displayManager, overlayManager,
                      socketServer, queryServer, executor, eventBridge, dragHandler,
                      mouseDownMonitor, spotlight, timerController, screenIndex,
                      whatsUpCache, terminationWatch, later)
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
        logStderr("mcmonad-core: \(msg)\n")

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
        logStderr("mcmonad-core: \(stderrMsg)\n")

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
