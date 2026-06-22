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

    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var timers: [ActiveTimer] = []
    private var nextId = 1
    private var tick: Timer?
    private var hudPanel: NSPanel?

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
        let what = t.label.isEmpty ? "Timer" : t.label
        showHUD(text: "⏰  \(what) — time's up")
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

    /// A small, non-activating, click-through HUD shown briefly on the screen
    /// under the mouse. Auto-dismisses; never steals key focus.
    private func showHUD(text: String) {
        hudPanel?.orderOut(nil)

        let width: CGFloat = 420
        let height: CGFloat = 64
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSVisualEffectView(frame: panel.contentView!.bounds)
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true
        container.autoresizingMask = [.width, .height]

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 20, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 16),
        ])
        panel.contentView = container

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let vis = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: vis.midX - width / 2,
                y: vis.maxY - height - vis.height * 0.18
            ))
        }
        panel.orderFrontRegardless()
        hudPanel = panel

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if self?.hudPanel === panel { self?.hudPanel = nil }
            panel.orderOut(nil)
        }
    }
}
