import AppKit
import os

// AI-generated text: model claude-opus-5-5; reasoning effort unavailable (not exposed by the harness).

/// Owns the "later" inbox for the daemon: whether it is on (the settings
/// home-manager wrote), the last snapshot read from bd, saving a window
/// for later, acting on a bead, and the menu-bar item that keeps the ready
/// count in sight so nothing saved is forgotten.
///
/// bd is the only authority on the inbox. This holds a snapshot to draw
/// from and re-reads after every change it makes, on a timer, and whenever
/// the launcher or the menu opens, so a bead closed from a terminal or by
/// an agent drops out here too.
@MainActor
final class LaterController: NSObject, NSMenuDelegate {
    private static let logger = Logger(subsystem: "com.mcmonad.core", category: "Later")

    // MARK: Wiring (set by Main)

    /// The window manager's current windows, to describe the window a note
    /// is about and to tell whether a bead's window still exists.
    var snapshotProvider: (() -> OverlaySnapshot?)?
    var onFocusWindow: ((UInt32, Int32) -> Void)?
    var onViewWorkspace: ((String) -> Void)?
    /// Open the launcher on the Later list, at one bead's actions if given.
    var onOpenLauncher: ((BeadID?) -> Void)?
    /// Open the launcher in command mode with this text typed.
    var onOpenLauncherWithText: ((String) -> Void)?
    /// The inbox changed (or could not be read); redraw what shows it.
    var onChanged: (() -> Void)?

    // MARK: State

    private(set) var settings: LaterSettings.Load = .off
    private(set) var snapshot: LaterSnapshot?
    /// The last call that failed, until one succeeds.
    private(set) var fault: LaterFault?
    /// Saves started and not yet answered.
    private var saving = 0
    private var refreshing = false
    private var refreshAgain = false
    private var tick: Timer?
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()

    static let refreshEvery: TimeInterval = 60

    var isOn: Bool {
        if case .on = settings { return true }
        return false
    }

    private var inbox: LaterInbox? {
        if case .on(let s) = settings { return LaterInbox(cli: s.cli) }
        return nil
    }

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    // MARK: Settings and refresh

    /// Read the settings file again; a changed answer redraws and refreshes.
    /// Cheap (one small file), so it runs whenever the launcher opens.
    func reloadSettings() {
        let file = LaterSettings.file(home: NSHomeDirectory())
        let data = FileManager.default.contents(atPath: file)
        let load = LaterSettings.load(data, file: file)
        guard load != settings else { return }
        settings = load
        switch load {
        case .off:
            Self.logger.info("later: off (no \(file, privacy: .public))")
            snapshot = nil
            fault = nil
            tick?.invalidate(); tick = nil
        case .unusable:
            Self.logger.error("later: settings unusable")
            snapshot = nil
            tick?.invalidate(); tick = nil
        case .on:
            Self.logger.info("later: on")
            if tick == nil {
                tick = Timer.scheduledTimer(withTimeInterval: Self.refreshEvery, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
            }
            refresh()
        }
        updateStatusItem()
        onChanged?()
    }

    /// Read the inbox again. Calls made while one is running collapse into
    /// one more read after it.
    func refresh() {
        guard let inbox else { return }
        if refreshing { refreshAgain = true; return }
        refreshing = true
        Task { @MainActor [weak self] in
            let result = await inbox.snapshot(now: Date())
            guard let self else { return }
            self.refreshing = false
            switch result {
            case .success(let s):
                self.snapshot = s
                self.fault = nil
            case .failure(let f):
                // The last good snapshot stays on screen with the fault beside it.
                self.fault = f
            }
            self.updateStatusItem()
            self.onChanged?()
            if self.refreshAgain {
                self.refreshAgain = false
                self.refresh()
            }
        }
    }

    // MARK: Windows

    /// The window `windowId` as the window manager knows it.
    func source(windowId: UInt32, pid: Int32) -> LaterSource? {
        guard let snap = snapshotProvider?() else { return nil }
        let all = snap.screens.flatMap { s in s.windows.map { ($0, s.workspaceTag) } }
            + snap.hiddenWorkspaces.flatMap { ws in ws.windows.map { ($0, ws.tag) } }
        guard let (w, tag) = all.first(where: { $0.0.windowId == windowId && $0.0.pid == pid }) else { return nil }
        return LaterSource(windowId: w.windowId, pid: w.pid, app: w.appName ?? "?",
                           title: w.title ?? "", workspace: w.workspaceTag ?? tag)
    }

    /// The window a note is about: as the window manager knows it, or, for
    /// a window it does not manage (an ignored panel), by its app alone.
    func describe(windowId: UInt32, pid: Int32) -> LaterSource {
        if let s = source(windowId: windowId, pid: pid) { return s }
        let app = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "process \(pid)"
        return LaterSource(windowId: windowId, pid: pid, app: app, title: "", workspace: nil)
    }

    /// The bead's window is still open: same id, same process.
    func originAlive(_ bead: Bead) -> Bool {
        guard let o = bead.origin else { return false }
        return source(windowId: o.windowId, pid: o.pid) != nil
    }

    // MARK: Saving

    /// Save `note` about `source` (the window the launcher was opened over,
    /// nil if none): capture the window, then create the bead. Returns at
    /// once; the count in the menu bar shows the save in flight and then
    /// its result.
    func save(note: LaterNote, source: LaterSource?) {
        guard case .on(let s) = settings, let title = Later.title(note: note, source: source) else { return }
        let inbox = LaterInbox(cli: s.cli)
        let now = Date()
        let displays = NSScreen.screens.compactMap { screen -> Later.Display? in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return Later.Display(bounds: CGDisplayBounds(n.uint32Value), scale: screen.backingScaleFactor)
        }
        saving += 1
        updateStatusItem()
        Task { @MainActor [weak self] in
            var taken = LaterCapture.Taken(screenshot: nil, text: nil, missing: [])
            if let source {
                taken = await LaterCapture.take(windowId: source.windowId, into: s.attachments, at: now, displays: displays)
            }
            let origin = source.map {
                BeadOrigin(windowId: $0.windowId, pid: $0.pid, app: $0.app, title: $0.title,
                           workspace: $0.workspace, screenshot: taken.screenshot, savedAt: now.iso)
            }
            let description = Later.description(source: source, screenshot: taken.screenshot,
                                                screenText: taken.text, missing: taken.missing, savedAt: now)
            let result = await inbox.create(title: title, description: description, priority: note.priority,
                                            labels: Later.labels(source: source),
                                            metadata: origin.map(Later.metadata))
            guard let self else { return }
            self.saving -= 1
            switch result {
            case .success(let bead):
                Self.logger.info("later: saved \(bead.id.raw, privacy: .public)")
                self.fault = nil
            case .failure(let f):
                self.fault = f
            }
            self.refresh()
            self.updateStatusItem()
        }
    }

    // MARK: Acting on a bead

    func prompt(_ id: BeadID) -> String? {
        snapshot?.bead(id).map { Later.prompt(for: $0) }
    }

    /// Start (or continue) a bead: mark it started, put its prompt on the
    /// clipboard, and go back to the window it was saved from, or to its
    /// workspace if that window has closed.
    func start(_ id: BeadID) {
        guard let inbox, let bead = snapshot?.bead(id) else { return }
        copyToClipboard(Later.prompt(for: bead))
        if let o = bead.origin {
            if originAlive(bead) {
                onFocusWindow?(o.windowId, o.pid)
            } else if let ws = o.workspace {
                onViewWorkspace?(ws)
            }
        }
        if bead.status != .inProgress {
            mutate { await inbox.claim(id) }
        }
    }

    func copyPrompt(_ id: BeadID) {
        guard let p = prompt(id) else { return }
        copyToClipboard(p)
    }

    func openScreenshot(_ id: BeadID) {
        guard let path = snapshot?.bead(id)?.origin?.screenshot else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func snooze(_ id: BeadID) {
        guard let inbox else { return }
        mutate { await inbox.snooze(id, until: Later.snoozeUntil) }
    }

    func done(_ id: BeadID) {
        guard let inbox else { return }
        mutate { await inbox.close(id) }
    }

    func putBack(_ id: BeadID) {
        guard let inbox else { return }
        mutate { await inbox.putBack(id) }
    }

    /// Run one change, keep its fault if it failed, then read the inbox.
    private func mutate(_ change: @escaping @Sendable () async -> Result<Void, LaterFault>) {
        Task { @MainActor [weak self] in
            let result = await change()
            guard let self else { return }
            if case .failure(let f) = result { self.fault = f }
            self.refresh()
        }
    }

    private func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: Menu-bar item

    /// Shown while anything is ready, being saved, or wrong; otherwise gone,
    /// like the timer's item, so an empty inbox costs no menu-bar space.
    private func updateStatusItem() {
        let ready = snapshot?.readyCount ?? 0
        var unusable = false
        if case .unusable = settings { unusable = true }
        guard unusable || (isOn && (ready > 0 || saving > 0 || fault != nil)) else {
            if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
            statusItem = nil
            return
        }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.menu = menu
            statusItem = item
        }
        var title = "◆ \(ready)"
        if saving > 0 { title += " +\(saving)…" }
        if fault != nil || !isOn { title += " ⚠" }
        statusItem?.button?.title = title
        statusItem?.button?.toolTip = "Saved for later: \(ready) ready to start"
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuild(menu)
        refresh()
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        if case .unusable(let why) = settings {
            menu.addItem(disabled("⚠ Later inbox settings are unusable"))
            menu.addItem(disabled(Later.clip(why, 160)))
            return
        }
        let now = Date()
        if let s = snapshot {
            let waiting = s.beads.count - s.readyCount - s.startedCount
            menu.addItem(disabled("Later — \(s.readyCount) ready · \(s.startedCount) started · \(waiting) waiting"))
            let shown = s.beads.filter { s.standing($0) != .waiting }.prefix(20)
            for bead in shown {
                let mark = s.standing(bead) == .started ? "▸" : "◆"
                let item = NSMenuItem(title: "\(mark) \(Later.clip(bead.title, 70))   ·  P\(bead.priority) · \(Later.age(from: bead.createdAt, to: now))",
                                      action: #selector(openBeadClicked(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = bead.id.raw
                menu.addItem(item)
            }
            if s.unreadable > 0 {
                menu.addItem(disabled("\(s.unreadable) bead(s) could not be read; see `\(Later.cliName) list`"))
            }
        } else {
            menu.addItem(disabled("Later — reading the inbox…"))
        }
        if let fault {
            menu.addItem(.separator())
            menu.addItem(disabled("⚠ " + Later.clip(fault.description, 160)))
            let copy = NSMenuItem(title: "Copy the error", action: #selector(copyFaultClicked(_:)), keyEquivalent: "")
            copy.target = self
            menu.addItem(copy)
        }
        menu.addItem(.separator())
        let browse = NSMenuItem(title: "Browse in the launcher", action: #selector(browseClicked(_:)), keyEquivalent: "")
        browse.target = self
        menu.addItem(browse)
        let save = NSMenuItem(title: "Save the focused window for later…", action: #selector(saveClicked(_:)), keyEquivalent: "")
        save.target = self
        menu.addItem(save)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func openBeadClicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        onOpenLauncher?(BeadID(raw: raw))
    }

    @objc private func browseClicked(_ sender: Any?) { onOpenLauncher?(nil) }

    @objc private func saveClicked(_ sender: Any?) { onOpenLauncherWithText?("later ") }

    @objc private func copyFaultClicked(_ sender: Any?) {
        guard let fault else { return }
        copyToClipboard(fault.description)
    }
}
