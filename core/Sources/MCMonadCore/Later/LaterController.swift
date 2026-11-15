import AppKit
import os

// AI-generated text: model claude-opus-5-5; reasoning effort unavailable (not exposed by the harness).

/// Owns the "later" inbox for the daemon: whether this build has it (the
/// `later` it was built with), the last snapshot read from `later`, saving
/// a window for later, acting on a bead, and the menu-bar item that keeps
/// the ready count in sight so nothing saved is forgotten.
///
/// `later` is the only authority on the inbox, and bd behind it. This holds
/// a snapshot to draw from and re-reads after every change it makes, on a
/// timer, and whenever the launcher or the menu opens, so a bead closed
/// from a terminal or by an agent drops out here too.
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

    /// The `later` this build has; nil means the inbox is not part of it.
    private let inbox: LaterInbox?
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

    var isOn: Bool { inbox != nil }

    /// `cli`: the `later` this build has, if any.
    init(cli: String?) {
        inbox = cli.map { LaterInbox(cli: $0) }
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        Self.logger.info("later: \(cli == nil ? "not in this build" : "on", privacy: .public)")
        guard isOn else { return }
        tick = Timer.scheduledTimer(withTimeInterval: Self.refreshEvery, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    /// Read the inbox again. Calls made while one is running collapse into
    /// one more read after it.
    func refresh() {
        guard let inbox else { return }
        if refreshing { refreshAgain = true; return }
        refreshing = true
        Task { @MainActor [weak self] in
            let result = await inbox.snapshot()
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
        return LaterSource(window: .mac(windowId: w.windowId, pid: w.pid), app: w.appName ?? "?",
                           title: w.title ?? "", workspace: w.workspaceTag ?? tag)
    }

    /// The window a note is about: as the window manager knows it, or, for
    /// a window it does not manage (an ignored panel), by its app alone.
    func describe(windowId: UInt32, pid: Int32) -> LaterSource {
        if let s = source(windowId: windowId, pid: pid) { return s }
        let app = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "process \(pid)"
        return LaterSource(window: .mac(windowId: windowId, pid: pid), app: app, title: "", workspace: nil)
    }

    /// The bead's window is still open on this Mac: same id, same process.
    func originAlive(_ origin: LaterOrigin?) -> Bool {
        guard case .mac(let id, let pid)? = origin?.window else { return false }
        return source(windowId: id, pid: pid) != nil
    }

    // MARK: Saving

    /// Save the note in `words` about `source` (the window the launcher was
    /// opened over, nil if none): capture the window, then hand everything
    /// to `later save`. Returns at once; the menu-bar count shows the save
    /// in flight and then its result.
    func save(words: String, source: LaterSource?) {
        guard let inbox else { return }
        let displays = NSScreen.screens.compactMap { screen -> Later.Display? in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return Later.Display(bounds: CGDisplayBounds(n.uint32Value), scale: screen.backingScaleFactor)
        }
        saving += 1
        updateStatusItem()
        Task { @MainActor [weak self] in
            var taken = LaterCapture.Taken(screenshot: nil, text: nil, missing: [])
            if case .mac(let id, _)? = source?.window {
                taken = await LaterCapture.take(windowId: id, displays: displays)
            }
            let request = LaterSaveRequest(words: words, source: source, screenshot: taken.screenshot,
                                           text: taken.text, missing: taken.missing)
            let result = await inbox.save(request)
            // `later` moved the picture in; if it did not, it is ours to remove.
            if let shot = taken.screenshot { try? FileManager.default.removeItem(atPath: shot) }
            guard let self else { return }
            self.saving -= 1
            switch result {
            case .success(let saved):
                Self.logger.info("later: saved \(saved.id.raw, privacy: .public)")
                self.fault = nil
            case .failure(let f):
                self.fault = f
            }
            self.refresh()
            self.updateStatusItem()
        }
    }

    // MARK: Acting on a bead

    /// Start (or continue) a bead: `later` marks it started and gives the
    /// prompt; put that on the clipboard and go back to the window it was
    /// saved from, or to its workspace if that window has closed.
    func start(_ id: BeadID) {
        guard let inbox else { return }
        Task { @MainActor [weak self] in
            let result = await inbox.start(id)
            guard let self else { return }
            switch result {
            case .success(let started):
                self.copyToClipboard(started.prompt)
                if case .mac(let wid, let pid)? = started.origin?.window, self.originAlive(started.origin) {
                    self.onFocusWindow?(wid, pid)
                } else if let ws = started.origin?.workspace {
                    self.onViewWorkspace?(ws)
                }
            case .failure(let f):
                self.fault = f
            }
            self.refresh()
        }
    }

    func copyPrompt(_ id: BeadID) {
        guard let inbox else { return }
        Task { @MainActor [weak self] in
            let result = await inbox.prompt(id)
            guard let self else { return }
            switch result {
            case .success(let prompt): self.copyToClipboard(prompt)
            case .failure(let f): self.fault = f; self.updateStatusItem(); self.onChanged?()
            }
        }
    }

    func openScreenshot(_ id: BeadID) {
        guard let path = snapshot?.bead(id)?.origin?.screenshot else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// The inbox as a page: its graph, screenshots and everything saved.
    func openView() {
        guard let inbox else { return }
        mutate { await inbox.view() }
    }

    func snooze(_ id: BeadID) {
        guard let inbox else { return }
        mutate { await inbox.snooze(id) }
    }

    func done(_ id: BeadID) {
        guard let inbox else { return }
        mutate { await inbox.done(id) }
    }

    func wake(_ id: BeadID) {
        guard let inbox else { return }
        mutate { await inbox.wake(id) }
    }

    func putBack(_ id: BeadID) {
        guard let inbox else { return }
        mutate { await inbox.putBack(id) }
    }

    /// Run one call, keep its fault if it failed, then read the inbox.
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
        guard isOn, ready > 0 || saving > 0 || fault != nil else {
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
        if fault != nil { title += " ⚠" }
        statusItem?.button?.title = title
        statusItem?.button?.toolTip = "Saved for later: \(ready) ready to start"
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuild(menu)
        refresh()
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let now = Date()
        if let s = snapshot {
            let waiting = s.beads.count - s.readyCount - s.startedCount
            menu.addItem(disabled("Later — \(s.readyCount) ready · \(s.startedCount) started · \(waiting) waiting"))
            for bead in s.beads.filter({ $0.standing != .waiting }).prefix(20) {
                let mark = bead.standing == .started ? "▸" : "◆"
                let item = NSMenuItem(title: "\(mark) \(Later.clip(bead.title, 70))   ·  P\(bead.priority) · \(Later.age(from: bead.createdAt, to: now))",
                                      action: #selector(openBeadClicked(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = bead.id.raw
                menu.addItem(item)
            }
            if !s.unreadable.isEmpty {
                menu.addItem(disabled("\(s.unreadable.count) bead(s) could not be read; see `\(Later.cliName) list`"))
            }
        } else {
            menu.addItem(disabled("Later — reading the inbox…"))
        }
        if let fault {
            menu.addItem(.separator())
            menu.addItem(disabled("⚠ " + Later.clip(fault.description, 160)))
            menu.addItem(action("Copy the error", #selector(copyFaultClicked(_:))))
        }
        menu.addItem(.separator())
        menu.addItem(action("Open the graph, with screenshots…", #selector(viewClicked(_:))))
        menu.addItem(action("Browse in the launcher", #selector(browseClicked(_:))))
        menu.addItem(action("Save the focused window for later…", #selector(saveClicked(_:))))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openBeadClicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        onOpenLauncher?(BeadID(raw: raw))
    }

    @objc private func viewClicked(_ sender: Any?) { openView() }

    @objc private func browseClicked(_ sender: Any?) { onOpenLauncher?(nil) }

    @objc private func saveClicked(_ sender: Any?) { onOpenLauncherWithText?("later ") }

    @objc private func copyFaultClicked(_ sender: Any?) {
        guard let fault else { return }
        copyToClipboard(fault.description)
    }
}
