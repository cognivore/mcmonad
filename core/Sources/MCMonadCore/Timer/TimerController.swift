import AppKit
import os

/// The menu-bar countdown timer widget.
///
/// Owns its own `NSStatusItem`, separate from the main mcmonad workspace
/// indicator, that appears only while at least one timer is running and shows
/// the soonest-to-fire countdown live (e.g. "⏱ 14:32"). Its dropdown lists
/// every running timer with a cancel action.
///
/// Timers are driven by a single 1-second tick rather than one
/// `scheduledTimer` per countdown: the tick both refreshes the displayed
/// remaining time and fires any timer whose deadline has passed. That keeps
/// fire-handling in one place and avoids the double-fire/drift pitfalls of
/// juggling many one-shot timers.
///
/// On fire: a system sound plays and a transient, non-activating HUD panel
/// announces "time's up". We deliberately avoid `UNUserNotificationCenter`
/// (which needs a fully-registered bundle + entitlements that a bare,
/// directly-exec'd daemon binary doesn't reliably have) — the sound + HUD
/// path works regardless of how the daemon was launched.
@MainActor
final class TimerController: NSObject, NSMenuDelegate {
    private static let logger = Logger(
        subsystem: "com.mcmonad.core",
        category: "Timer"
    )

    private struct ActiveTimer {
        let id: Int
        let label: String
        let fireDate: Date
        let total: TimeInterval
    }

    /// A fired-timer reminder card: a persistent, interactive HUD that stays on
    /// screen until dismissed or snoozed. `label` is kept so Snooze can re-arm
    /// the same timer.
    private struct Reminder {
        let id: Int
        let panel: NSPanel
        let label: String
    }

    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var timers: [ActiveTimer] = []
    private var nextId = 1
    private var tick: Timer?

    /// Fired-timer reminders, oldest first. Each stays up until the user clicks
    /// Dismiss or Snooze — a missed timer must never silently vanish. Relaid
    /// out on add/remove so the stack has no gaps.
    private var reminders: [Reminder] = []
    private var nextReminderId = 1

    private static let reminderWidth: CGFloat = 460
    private static let reminderHeight: CGFloat = 92
    private static let reminderGap: CGFloat = 10
    private static let snoozeSeconds: TimeInterval = 5 * 60

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    // MARK: - Public API

    /// Start a countdown. `label` is optional free text shown in the dropdown
    /// and the "time's up" HUD.
    func start(seconds: TimeInterval, label: String) {
        let clamped = max(1, seconds)
        let t = ActiveTimer(
            id: nextId,
            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            fireDate: Date().addingTimeInterval(clamped),
            total: clamped
        )
        nextId += 1
        timers.append(t)
        Self.logger.info(
            "timer #\(t.id) started: \(Int(clamped), privacy: .public)s label=\(t.label, privacy: .public)"
        )
        ensureStatusItem()
        ensureTick()
        updateDisplay()
    }

    /// Number of timers currently running.
    var activeCount: Int { timers.count }

    // MARK: - Tick / fire

    private func ensureTick() {
        guard tick == nil else { return }
        tick = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onTick() }
        }
    }

    private func onTick() {
        let now = Date()
        let fired = timers.filter { $0.fireDate <= now }
        if !fired.isEmpty {
            timers.removeAll { $0.fireDate <= now }
            for t in fired { fire(t) }
        }
        if timers.isEmpty {
            teardown()
        } else {
            updateDisplay()
        }
    }

    private func fire(_ t: ActiveTimer) {
        Self.logger.info("timer #\(t.id) fired: \(t.label, privacy: .public)")
        playSound()
        showReminder(label: t.label)
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
        guard let soonest = timers.min(by: { $0.fireDate < $1.fireDate }) else { return }
        let remaining = max(0, soonest.fireDate.timeIntervalSinceNow)
        var title = "⏱ " + Self.format(remaining)
        if timers.count > 1 { title += " +\(timers.count - 1)" }
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

        if timers.isEmpty {
            let none = NSMenuItem(title: "(none running)", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return
        }

        for t in timers.sorted(by: { $0.fireDate < $1.fireDate }) {
            let remaining = max(0, t.fireDate.timeIntervalSinceNow)
            let name = t.label.isEmpty ? "Timer" : t.label
            let item = NSMenuItem(
                title: "\(Self.format(remaining))  —  \(name)",
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
        timers.removeAll { $0.id == id }
        if timers.isEmpty { teardown() } else { updateDisplay() }
    }

    @objc private func cancelAllClicked(_ sender: Any?) {
        timers.removeAll()
        teardown()
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
    /// fired reminders, until the user clicks Dismiss or Snooze. The card is a
    /// non-activating `popUpMenu`-level HUD, so it floats above other windows,
    /// takes clicks on its buttons without stealing focus, and is ignored by the
    /// tiling engine (its window level is outside the managed {0,3,8} set).
    private func showReminder(label rawLabel: String) {
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

        let buttonW: CGFloat = 150
        let buttonH: CGFloat = 30
        let buttonY: CGFloat = 14
        let gap: CGFloat = 12

        let snooze = NSButton(frame: NSRect(
            x: Self.reminderWidth / 2 - buttonW - gap / 2,
            y: buttonY, width: buttonW, height: buttonH))
        snooze.bezelStyle = .rounded
        snooze.title = "Snooze 5 min"
        snooze.tag = id
        snooze.target = self
        snooze.action = #selector(snoozeReminderClicked(_:))
        container.addSubview(snooze)

        let dismiss = NSButton(frame: NSRect(
            x: Self.reminderWidth / 2 + gap / 2,
            y: buttonY, width: buttonW, height: buttonH))
        dismiss.bezelStyle = .rounded
        dismiss.title = "Dismiss"
        dismiss.tag = id
        dismiss.target = self
        dismiss.action = #selector(dismissReminderClicked(_:))
        container.addSubview(dismiss)

        reminders.append(Reminder(id: id, panel: panel, label: rawLabel))
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
        dismissReminder(id: sender.tag)
        // Re-arm the same timer; it fires (and shows a fresh reminder) again
        // after the snooze interval.
        start(seconds: Self.snoozeSeconds, label: label)
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
