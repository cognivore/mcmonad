import AppKit
import os

/// The menu-bar countdown timer widget.
///
/// Timer *state* lives in the Haskell brain — the list of running timers,
/// their ids, labels, fire times, and origin workspaces are owned there,
/// persisted across Mod-q / launchd restart, and pushed here as a
/// `set-timers` command (`setTimers`). This controller is the *renderer +
/// clock*: it owns an `NSStatusItem` (separate from the workspace
/// indicator) that shows the soonest countdown live (e.g. "⏱ 14:32"), and
/// fires the "time's up" reminder when a deadline passes. It never invents
/// or mutates timer state on its own — every user action (start, snooze,
/// cancel, jump) is reported back over IPC and returns as a fresh
/// `setTimers`.
///
/// Timers are driven by a single 1-second tick rather than one
/// `scheduledTimer` per countdown: the tick both refreshes the displayed
/// remaining time and fires any timer whose `fireAt` has passed. Fire is
/// detected against the absolute epoch `fireAt`, so a timer fires at the
/// correct wall-clock moment even if it was restored mid-flight after a
/// restart (and fires immediately if its deadline already passed while
/// mcmonad was down).
///
/// On fire: a system sound plays and a transient, non-activating HUD panel
/// announces "time's up" with Snooze / Jump-to-workspace / Dismiss. We
/// deliberately avoid `UNUserNotificationCenter` (which needs a
/// fully-registered bundle + entitlements that a bare, directly-exec'd
/// daemon binary doesn't reliably have) — the sound + HUD path works
/// regardless of how the daemon was launched.
@MainActor
final class TimerController: NSObject, NSMenuDelegate {
    private static let logger = Logger(
        subsystem: "com.mcmonad.core",
        category: "Timer"
    )

    /// A fired-timer reminder card: a persistent, interactive HUD that stays on
    /// screen until dismissed, snoozed, or jumped-from. `label` and `workspace`
    /// are kept so Snooze can re-arm the same timer (preserving its origin) and
    /// Jump can switch to where it was started.
    private struct Reminder {
        let id: Int
        let panel: NSPanel
        let label: String
        let workspace: String
    }

    // MARK: - Callbacks (wired in Main to socket events)

    /// A timer's deadline passed (by id). The brain drops it from state.
    var onFired: ((Int) -> Void)?
    /// The user cancelled one running timer from the menubar (by id).
    var onCancel: ((Int) -> Void)?
    /// The user cancelled every running timer from the menubar.
    var onCancelAll: (() -> Void)?
    /// The user hit Snooze: start a fresh timer (seconds, label, origin
    /// workspace) — routed back to the brain so it keeps the original origin.
    var onSnooze: ((TimeInterval, String, String) -> Void)?
    /// The user hit "Jump to workspace": switch to the timer's origin tag.
    var onJumpToWorkspace: ((String) -> Void)?

    // MARK: - State (mirror of the brain's authoritative list)

    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    /// The full timer list as last pushed by the brain.
    private var timers: [TimerSpec] = []
    /// Ids we've already fired this daemon session. Guards against a timer
    /// re-firing in the window between our fire (which optimistically leaves
    /// it in `timers`) and the brain's next `setTimers` removing it. Pruned
    /// to the ids actually present whenever a list arrives, so monotonic ids
    /// keep it bounded and never block a genuinely-new timer.
    private var firedIds: Set<Int> = []
    private var tick: Timer?

    /// Fired-timer reminders, oldest first. Each stays up until the user clicks
    /// Dismiss, Snooze, or Jump — a missed timer must never silently vanish.
    /// Relaid out on add/remove so the stack has no gaps.
    private var reminders: [Reminder] = []
    private var nextReminderId = 1

    private static let reminderWidth: CGFloat = 480
    private static let reminderHeight: CGFloat = 92
    private static let reminderGap: CGFloat = 10
    private static let snoozeSeconds: TimeInterval = 5 * 60

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    // MARK: - Public API (driven by the brain)

    /// Replace the rendered timer list with the brain's authoritative one.
    /// Idempotent: an empty list tears the widget down; a non-empty list
    /// (re)creates the status item and tick. Called on startup (to resume
    /// restored timers) and after every brain-side timer mutation.
    func setTimers(_ list: [TimerSpec]) {
        self.timers = list
        // Drop fired-id bookkeeping for timers no longer in the list.
        firedIds.formIntersection(Set(list.map { $0.id }))
        // Reconcile a rare cross-restart race: a timer the brain still
        // considers pending that we already fired (our fired-notice was lost
        // because the brain was mid-restart). Re-report it so the brain drops
        // it; we don't re-show the reminder (it already fired once).
        for t in list where firedIds.contains(t.id) {
            onFired?(t.id)
        }
        if pending.isEmpty {
            teardown()
        } else {
            ensureStatusItem()
            ensureTick()
            updateDisplay()
        }
    }

    /// Timers not yet fired — what the menubar counts down and the tick fires.
    private var pending: [TimerSpec] {
        timers.filter { !firedIds.contains($0.id) }
    }

    // MARK: - Tick / fire

    private func ensureTick() {
        guard tick == nil else { return }
        tick = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onTick() }
        }
    }

    private func onTick() {
        let now = Date().timeIntervalSince1970
        for t in timers where t.fireAt <= now && !firedIds.contains(t.id) {
            firedIds.insert(t.id)
            fire(t)
            // Tell the brain so it drops the timer from persisted state; the
            // brain answers with a fresh setTimers that no longer carries it.
            onFired?(t.id)
        }
        if pending.isEmpty {
            teardown()
        } else {
            updateDisplay()
        }
    }

    private func fire(_ t: TimerSpec) {
        Self.logger.info("timer #\(t.id) fired: \(t.label, privacy: .public)")
        playSound()
        showReminder(label: t.label, workspace: t.workspace)
    }

    private func teardown() {
        tick?.invalidate()
        tick = nil
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    // MARK: - Status item + display

    private func ensureStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = menu
        statusItem = item
    }

    private func updateDisplay() {
        let p = pending
        guard let soonest = p.min(by: { $0.fireAt < $1.fireAt }) else {
            teardown()
            return
        }
        let remaining = max(0, soonest.fireAt - Date().timeIntervalSince1970)
        var title = "⏱ " + Self.format(remaining)
        if p.count > 1 { title += " +\(p.count - 1)" }
        statusItem?.button?.title = title
    }

    /// Round up so the last visible second is "0:01", not a flash of "0:00".
    static func format(_ remaining: TimeInterval) -> String {
        let secs = Int(remaining.rounded(.up))
        let h = secs / 3600
        let m = (secs % 3600) / 60
        let s = secs % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: "Timers", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        let running = pending
        if running.isEmpty {
            let none = NSMenuItem(title: "(none running)", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return
        }

        let now = Date().timeIntervalSince1970
        for t in running.sorted(by: { $0.fireAt < $1.fireAt }) {
            let remaining = max(0, t.fireAt - now)
            let name = t.label.isEmpty ? "Timer" : t.label
            let suffix = t.workspace.isEmpty ? "" : "  ·  \(t.workspace)"
            let item = NSMenuItem(
                title: "\(Self.format(remaining))  —  \(name)\(suffix)",
                action: #selector(cancelClicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = NSNumber(value: t.id)
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
        let cancelAll = NSMenuItem(
            title: "Cancel all",
            action: #selector(cancelAllClicked(_:)),
            keyEquivalent: ""
        )
        cancelAll.target = self
        menu.addItem(cancelAll)
    }

    @objc private func cancelClicked(_ sender: NSMenuItem) {
        guard let id = (sender.representedObject as? NSNumber)?.intValue else { return }
        // The brain owns the list: report the cancel and let the resulting
        // setTimers update what we render.
        onCancel?(id)
    }

    @objc private func cancelAllClicked(_ sender: Any?) {
        onCancelAll?()
    }

    // MARK: - Feedback (sound + HUD)

    private func playSound() {
        if let sound = NSSound(named: NSSound.Name("Glass")) {
            sound.play()
        } else {
            NSSound.beep()
        }
    }

    /// Show a persistent reminder card for a fired timer. Unlike a toast it does
    /// NOT auto-dismiss: a missed timer stays on screen, stacked under any other
    /// fired reminders, until the user clicks Dismiss, Snooze, or Jump. The card
    /// is a non-activating `popUpMenu`-level HUD, so it floats above other
    /// windows, takes clicks on its buttons without stealing focus, and is
    /// ignored by the tiling engine (its window level is outside the managed
    /// {0,3,8} set).
    private func showReminder(label rawLabel: String, workspace: String) {
        let id = nextReminderId
        nextReminderId += 1
        let trimmed = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? "Timer" : trimmed

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.reminderWidth, height: Self.reminderHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .vibrantDark)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSVisualEffectView(frame: panel.contentView!.bounds)
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.55).cgColor
        container.autoresizingMask = [.width, .height]
        panel.contentView = container

        let message = NSTextField(labelWithString: "⏰  \(title) — time's up")
        message.font = .systemFont(ofSize: 18, weight: .medium)
        message.textColor = .labelColor
        message.alignment = .center
        message.lineBreakMode = .byTruncatingTail
        message.frame = NSRect(x: 16, y: Self.reminderHeight - 44,
                               width: Self.reminderWidth - 32, height: 28)
        container.addSubview(message)

        // Three buttons, centred as a row: Snooze · Jump to workspace · Dismiss.
        // The Jump button is omitted only when the timer has no recorded origin
        // (which shouldn't happen — the brain always stamps the current tag).
        let hasWorkspace = !workspace.isEmpty
        let buttonH: CGFloat = 30
        let buttonY: CGFloat = 14
        let gap: CGFloat = 10
        let buttonW: CGFloat = 150
        let count = hasWorkspace ? 3 : 2
        let totalW = CGFloat(count) * buttonW + CGFloat(count - 1) * gap
        var x = (Self.reminderWidth - totalW) / 2

        let snooze = NSButton(frame: NSRect(x: x, y: buttonY, width: buttonW, height: buttonH))
        snooze.bezelStyle = .rounded
        snooze.title = "Snooze 5 min"
        snooze.tag = id
        snooze.target = self
        snooze.action = #selector(snoozeReminderClicked(_:))
        container.addSubview(snooze)
        x += buttonW + gap

        if hasWorkspace {
            let jump = NSButton(frame: NSRect(x: x, y: buttonY, width: buttonW, height: buttonH))
            jump.bezelStyle = .rounded
            jump.title = "Jump to \(workspace)"
            jump.toolTip = "Switch to the workspace this timer was started from"
            jump.tag = id
            jump.target = self
            jump.action = #selector(jumpReminderClicked(_:))
            container.addSubview(jump)
            x += buttonW + gap
        }

        let dismiss = NSButton(frame: NSRect(x: x, y: buttonY, width: buttonW, height: buttonH))
        dismiss.bezelStyle = .rounded
        dismiss.title = "Dismiss"
        dismiss.tag = id
        dismiss.target = self
        dismiss.action = #selector(dismissReminderClicked(_:))
        container.addSubview(dismiss)

        reminders.append(Reminder(id: id, panel: panel, label: rawLabel, workspace: workspace))
        relayoutReminders()
        panel.orderFrontRegardless()
    }

    /// Re-stack reminder cards from a fixed top-centre anchor so dismissing one
    /// closes the gap. Newest cards sit lower in the stack.
    private func relayoutReminders() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let vis = screen.visibleFrame
        let x = vis.midX - Self.reminderWidth / 2
        let topY = vis.maxY - Self.reminderHeight - vis.height * 0.12
        for (i, r) in reminders.enumerated() {
            let y = topY - CGFloat(i) * (Self.reminderHeight + Self.reminderGap)
            r.panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    @objc private func snoozeReminderClicked(_ sender: NSButton) {
        guard let r = reminders.first(where: { $0.id == sender.tag }) else { return }
        let label = r.label
        let workspace = r.workspace
        dismissReminder(id: sender.tag)
        // Re-arm via the brain so the snoozed copy keeps the original origin
        // workspace; it fires (and shows a fresh reminder) after the interval.
        onSnooze?(Self.snoozeSeconds, label, workspace)
    }

    @objc private func jumpReminderClicked(_ sender: NSButton) {
        guard let r = reminders.first(where: { $0.id == sender.tag }) else { return }
        let workspace = r.workspace
        dismissReminder(id: sender.tag)
        onJumpToWorkspace?(workspace)
    }

    @objc private func dismissReminderClicked(_ sender: NSButton) {
        dismissReminder(id: sender.tag)
    }

    private func dismissReminder(id: Int) {
        guard let idx = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[idx].panel.orderOut(nil)
        reminders.remove(at: idx)
        relayoutReminders()
    }
}
