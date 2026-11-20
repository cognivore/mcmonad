import AppKit
import os

// AI-assisted update (the "Questions to Claude" submenu, addAsks; Codex
// first, Claude as fallback): model claude-opus-5-5; reasoning effort
// unavailable (not exposed by the harness).
// AI-assisted update (Keep awake: addAwake, its actions, and "Open Login
// Items…" under Permissions): model claude-opus-5-5; reasoning effort
// unavailable (not exposed by the harness).

/// The mcmonad-core menubar item.
///
/// Displays:
///   - One small tag per connected screen, ordered left-to-right by
///     physical position, showing that screen's current workspace —
///     inspired by AeroSpace's menu bar icon. The active screen's tag
///     is rendered as a filled pill; the others are plain text. Redrawn
///     on every overlay snapshot and every screen-count change, so it
///     always matches however many displays are attached right now.
///   - A dropdown menu rebuilt on every open from the cached overlay
///     snapshot pushed from Haskell, showing each visible workspace
///     with its windows indented underneath, then hidden workspaces,
///     then a debug-overlays toggle at the bottom.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private static let logger = Logger(
        subsystem: "com.mcmonad.core",
        category: "StatusBar"
    )

    private var statusItem: NSStatusItem?
    private let menu = NSMenu()

    /// Snapshot read at menu-open time, supplied by the OverlayManager.
    /// `() -> OverlaySnapshot?` so we always get the freshest value.
    var snapshotProvider: (() -> OverlaySnapshot?)?
    /// The screen index's one-line status, read fresh on every open.
    var screenIndexStatus: (() -> String)?
    /// The receipts of recent questions to the models, newest first, and the
    /// policy they are kept under.
    var recentAsks: (() -> ([Ask.Receipt], Ask.Retention))?
    var whatsUpMonitoringEnabled: (() -> Bool)?
    var onSetWhatsUpMonitoring: ((Bool) -> Void)?
    /// Keep awake; nil when this MCMonadCore.app has no `awake`.
    var awake: AwakeController?

    /// Fires when the user clicks the "Debug frame overlays" item.
    /// The main module wires this to send `menuToggleDebug` to Haskell.
    var onToggleDebugOverlays: (() -> Void)?

    /// Fires when the user clicks a window entry inside a workspace
    /// submenu. The main module wires this to send `menuFocusWindow`.
    var onFocusWindow: ((UInt32, Int32) -> Void)?

    /// Fires when the user clicks a workspace row. The main module
    /// wires this to send `menuViewWorkspace`.
    var onViewWorkspace: ((String) -> Void)?

    /// Fires when the user clicks "Search windows…". The main module
    /// wires this to open the fuzzy window-search dropdown.
    var onSearchWindows: (() -> Void)?

    /// The menubar button, so the search dropdown can anchor under it.
    var statusButton: NSStatusBarButton? { statusItem?.button }

    func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        self.statusItem = item
        refreshIcon()
    }

    /// Redraws the per-screen tag icon from the latest cached snapshot.
    /// Call after every overlay-snapshot push and every screen-count
    /// change (see StatusBarController wiring in Main.swift).
    func refreshIcon() {
        guard let button = statusItem?.button else { return }
        let screens = snapshotProvider?()?.screens ?? []
        guard !screens.isEmpty else {
            button.image = Self.fallbackIcon()
            button.title = modeMarker ?? ""
            return
        }
        button.image = Self.makeScreenTagsIcon(screens: screens, modeMarker: modeMarker)
        button.title = ""
    }

    /// The old static icon, used only before Haskell's first snapshot
    /// arrives (no per-screen data to draw yet).
    private static func fallbackIcon() -> NSImage {
        let bundle = Bundle.main
        if let iconPath = bundle.path(forResource: "MenuBarIcon", ofType: "png"),
           let icon = NSImage(contentsOfFile: iconPath) {
            icon.isTemplate = true
            icon.size = NSSize(width: 18, height: 18)
            return icon
        }
        let execDir = ProcessInfo.processInfo.arguments[0]
        let resourceDir = (execDir as NSString)
            .deletingLastPathComponent + "/../Resources"
        if let icon = NSImage(contentsOfFile: resourceDir + "/MenuBarIcon.png") {
            icon.isTemplate = true
            icon.size = NSSize(width: 18, height: 18)
            return icon
        }
        // Nothing to load — a blank 1x1 template so the status item still
        // occupies a slot (its title carries "MC" as a last resort).
        let blank = NSImage(size: NSSize(width: 1, height: 1))
        blank.isTemplate = true
        return blank
    }

    /// One pill/tag per screen, left-to-right by physical position
    /// (`frame.origin.x`), sized to the menu bar's ~18-22pt height and
    /// widened dynamically to fit however many screens are attached.
    ///
    /// Template images are alpha-only masks — AppKit tints them per the
    /// current light/dark menu bar, ignoring any RGB we draw. So the
    /// active screen's highlight can't be a color: instead its pill is
    /// filled opaque and its tag text is cut out of that fill with
    /// `.destinationOut` (erasing alpha where the glyphs are), which
    /// reads as light-text-on-a-solid-pill once tinted either way.
    /// Inactive screens are just plain opaque text, no pill.
    private static func makeScreenTagsIcon(screens: [OverlayScreenEntry], modeMarker: String?) -> NSImage {
        let height: CGFloat = 18
        let vPad: CGFloat = 1.5
        let hPad: CGFloat = 4
        let gap: CGFloat = 4
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.black
        ]

        let ordered = screens.sorted { $0.frame.origin.x < $1.frame.origin.x }
        var tags: [(text: NSAttributedString, size: NSSize, isActive: Bool)] = ordered.map { s in
            let str = NSAttributedString(string: s.workspaceTag, attributes: textAttrs)
            return (str, str.size(), s.isActive)
        }
        if let modeMarker {
            let str = NSAttributedString(string: modeMarker, attributes: textAttrs)
            tags.append((str, str.size(), false))
        }
        let pillWidths = tags.map { $0.size.width + hPad * 2 }
        let totalWidth = pillWidths.reduce(0, +) + gap * CGFloat(max(0, tags.count - 1))
        let size = NSSize(width: max(totalWidth, 1), height: height)

        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            var x: CGFloat = 0
            for (tag, width) in zip(tags, pillWidths) {
                let pillRect = NSRect(x: x, y: vPad, width: width, height: height - vPad * 2)
                let textOrigin = NSPoint(
                    x: pillRect.midX - tag.size.width / 2,
                    y: pillRect.midY - tag.size.height / 2
                )
                if tag.isActive {
                    NSBezierPath(roundedRect: pillRect, xRadius: 3, yRadius: 3).fill()
                    ctx.saveGState()
                    ctx.setBlendMode(.destinationOut)
                    tag.text.draw(at: textOrigin)
                    ctx.restoreGState()
                } else {
                    tag.text.draw(at: textOrigin)
                }
                x += width + gap
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The marker the brain appends to its workspace indicator while a
    /// non-default input mode (resize mode and the like) is active, drawn
    /// after the per-screen tags. Nil in the default mode.
    private var modeMarker: String?

    /// Haskell's `SetWorkspaceIndicator`: the current workspace's tag,
    /// followed by a space and a marker while a non-default input mode is
    /// active. The tags themselves are drawn per screen from the overlay
    /// snapshot, so only the marker is taken from here; without it there
    /// is no sign anywhere that keys are in another mode.
    func updateWorkspace(_ indicator: String) {
        let marker = indicator.split(separator: " ").count > 1 && indicator.hasSuffix(Self.modeMarkerSymbol)
            ? Self.modeMarkerSymbol : nil
        guard marker != modeMarker else { return }
        modeMarker = marker
        refreshIcon()
    }

    /// U+2020 DAGGER, as sent by `MCMonad.Operations.windows`.
    private static let modeMarkerSymbol = "\u{2020}"

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        rebuild(menu: menu)
    }

    // MARK: - Menu construction

    private func rebuild(menu: NSMenu) {
        menu.removeAllItems()
        let snap = snapshotProvider?()

        // Header
        let header = NSMenuItem(
            title: "mcmonad",
            action: nil,
            keyEquivalent: ""
        )
        header.isEnabled = false
        menu.addItem(header)
        let monitoring = whatsUpMonitoringEnabled?() ?? false
        let monitoringItem = NSMenuItem(
            title: "What's up monitoring: \(monitoring ? "On" : "Off") — sends to OpenAI (Anthropic as fallback)",
            action: #selector(toggleWhatsUpMonitoring(_:)), keyEquivalent: "")
        monitoringItem.target = self
        monitoringItem.state = monitoring ? .on : .off
        menu.addItem(monitoringItem)
        if let status = screenIndexStatus?() {
            let row = NSMenuItem(title: "Screen index: \(status)", action: nil, keyEquivalent: "")
            row.isEnabled = false
            menu.addItem(row)
        }
        if let (receipts, retention) = recentAsks?() {
            addAsks(receipts, retention: retention, to: menu)
        }
        if let awake {
            addAwake(awake, to: menu)
        }
        menu.addItem(NSMenuItem.separator())

        // Fuzzy window search — opens the keyboard-driven dropdown.
        let searchItem = NSMenuItem(
            title: "Search windows…",
            action: #selector(searchWindowsClicked(_:)),
            keyEquivalent: ""
        )
        searchItem.target = self
        menu.addItem(searchItem)
        menu.addItem(NSMenuItem.separator())

        guard let snap = snap else {
            let waiting = NSMenuItem(
                title: "Waiting for state…",
                action: nil,
                keyEquivalent: ""
            )
            waiting.isEnabled = false
            menu.addItem(waiting)
            menu.addItem(NSMenuItem.separator())
            addDebugToggle(to: menu, currentlyOn: false)
            addFooter(to: menu)
            return
        }

        // DISPLAYED section
        let displayedHeader = NSMenuItem(
            title: "DISPLAYED", action: nil, keyEquivalent: ""
        )
        displayedHeader.isEnabled = false
        menu.addItem(displayedHeader)

        for screen in snap.screens {
            addWorkspaceItem(to: menu,
                             screenId: screen.screenId,
                             frame: screen.frame,
                             tag: screen.workspaceTag,
                             windows: screen.windows,
                             isHidden: false)
        }

        // HIDDEN section
        if !snap.hiddenWorkspaces.isEmpty {
            menu.addItem(NSMenuItem.separator())
            let hiddenHeader = NSMenuItem(
                title: "HIDDEN", action: nil, keyEquivalent: ""
            )
            hiddenHeader.isEnabled = false
            menu.addItem(hiddenHeader)
            for ws in snap.hiddenWorkspaces {
                addWorkspaceItem(to: menu,
                                 screenId: nil,
                                 frame: nil,
                                 tag: ws.tag,
                                 windows: ws.windows,
                                 isHidden: true)
            }
        }

        menu.addItem(NSMenuItem.separator())
        addPermissions(to: menu)
        addDebugToggle(to: menu, currentlyOn: snap.debugOverlays)
        addFooter(to: menu)
    }

    /// The daemon's own view of its grants and identity, read fresh every
    /// time the menu opens. Nothing in it prompts.
    /// "Questions to models", with a row per receipt kept: when, which
    /// feature, how it ended, how long, tokens, how many windows or
    /// workspaces the answer named, and which CLIs it went to. Never what
    /// was asked.
    private func addAsks(_ receipts: [Ask.Receipt], retention: Ask.Retention, to menu: NSMenu) {
        let tokens = receipts.reduce(0) { $0 + $1.tokens }
        let title = receipts.isEmpty
            ? "Questions to models: none in \(retention.hours) h"
            : "Questions to models: \(receipts.count) in \(retention.hours) h · \(tokens) tokens"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        for receipt in receipts.prefix(40) {
            let row = NSMenuItem(title: receipt.menuLine(clock: clock.string(from:)), action: nil, keyEquivalent: "")
            row.isEnabled = false
            sub.addItem(row)
        }
        if receipts.count > 40 {
            let more = NSMenuItem(title: "… \(receipts.count - 40) earlier", action: nil, keyEquivalent: "")
            more.isEnabled = false
            sub.addItem(more)
        }
        sub.addItem(NSMenuItem.separator())
        let kept = NSMenuItem(title: retention.receipts == .log
                                ? "Kept in memory and in mcmonad-core.log (ASK: lines)"
                                : "Kept in memory only", action: nil, keyEquivalent: "")
        kept.isEnabled = false
        sub.addItem(kept)
        item.submenu = sub
        menu.addItem(item)
    }

    /// "Keep awake": the running session's line and Stop, or the lengths
    /// to start one with. Everything shown is awake's own words.
    private func addAwake(_ awake: AwakeController, to menu: NSMenu) {
        let sub = NSMenu()
        func note(_ title: String) {
            let row = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            row.isEnabled = false
            sub.addItem(row)
        }
        let title: String
        if awake.isRunning {
            let report = awake.report
            title = "Keep awake: \(report?.line ?? "starting…")\(report?.warning == nil ? "" : " ⚠")"
            if let warning = report?.warning { note("⚠ \(warning)") }
            if let holders = report?.holders, !holders.isEmpty {
                note("Also keeping the Mac awake:")
                for h in holders { note("   \(h.process) (pid \(h.pid)): \(h.what)") }
            }
            sub.addItem(NSMenuItem.separator())
            let stop = NSMenuItem(title: "Stop (normal sleep comes back)", action: #selector(stopAwakeClicked(_:)), keyEquivalent: "")
            stop.target = self
            sub.addItem(stop)
        } else {
            title = "Keep awake"
            note("Locked and dark with the lid closed; then the Mac sleeps")
            note("Or type “awake 2h” in the launcher")
            for choice in AwakeController.choices {
                let item = NSMenuItem(title: choice.title, action: #selector(startAwakeClicked(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = choice.length
                sub.addItem(item)
            }
            if let outcome = awake.outcome {
                sub.addItem(NSMenuItem.separator())
                note("Last: \(outcome)")
            }
        }
        // The standing macOS last gave; asking again happens off the main thread.
        AwakeController.refreshGuard()
        if AwakeController.guardStatus != .enabled {
            sub.addItem(NSMenuItem.separator())
            note("⚠ Guard \(AwakeController.guardLine)")
            let open = NSMenuItem(title: "Open Login Items…", action: #selector(openLoginItemsClicked(_:)), keyEquivalent: "")
            open.target = self
            sub.addItem(open)
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = sub
        menu.addItem(item)
    }

    private func addPermissions(to menu: NSMenu) {
        let lines = PermissionAudit.take()
        let missing = lines.contains { $0.ok == false }
        let item = NSMenuItem(title: missing ? "Permissions ⚠" : "Permissions", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for line in lines {
            let mark: String
            switch line.ok {
            case .some(true): mark = "✓ "
            case .some(false): mark = "✗ "
            case .none: mark = "   "
            }
            let row = NSMenuItem(title: "\(mark)\(line.label): \(line.value)", action: nil, keyEquivalent: "")
            row.isEnabled = false
            submenu.addItem(row)
        }
        submenu.addItem(NSMenuItem.separator())
        let open = NSMenuItem(title: "Open Privacy & Security…", action: #selector(openPrivacyClicked(_:)), keyEquivalent: "")
        open.target = self
        submenu.addItem(open)
        if awake != nil {
            let loginItems = NSMenuItem(title: "Open Login Items…", action: #selector(openLoginItemsClicked(_:)), keyEquivalent: "")
            loginItems.target = self
            submenu.addItem(loginItems)
        }
        let copy = NSMenuItem(title: "Copy audit", action: #selector(copyAuditClicked(_:)), keyEquivalent: "")
        copy.target = self
        submenu.addItem(copy)
        item.submenu = submenu
        menu.addItem(item)
    }

    private func addWorkspaceItem(
        to menu: NSMenu,
        screenId: Int?,
        frame: CGRect?,
        tag: String,
        windows: [OverlayWindowEntry],
        isHidden: Bool
    ) {
        let title: String
        if isHidden {
            title = "Workspace \"\(tag)\"  (hidden)  · \(windows.count) win"
        } else if let sid = screenId, let f = frame {
            title = String(
                format: "Workspace \"%@\"  Screen %d  [%d×%d @ (%d,%d)]  · %d win",
                tag, sid,
                Int(f.width), Int(f.height),
                Int(f.origin.x), Int(f.origin.y),
                windows.count
            )
        } else {
            title = "Workspace \"\(tag)\"  · \(windows.count) win"
        }
        let item = NSMenuItem(
            title: title,
            action: #selector(viewWorkspaceClicked(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = tag

        let submenu = NSMenu()
        if windows.isEmpty {
            let empty = NSMenuItem(
                title: "(no windows)", action: nil, keyEquivalent: ""
            )
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for w in windows {
                submenu.addItem(makeWindowItem(w))
            }
        }
        item.submenu = submenu

        menu.addItem(item)

        // Also add the indented window rows directly in the parent menu
        // (so users see windows without opening the submenu). This matches
        // the "workspace > window list" shape the user asked for.
        for w in windows {
            menu.addItem(makeIndentedWindowItem(w))
        }
    }

    private func makeWindowItem(_ w: OverlayWindowEntry) -> NSMenuItem {
        let item = NSMenuItem(
            title: titleForWindow(w),
            action: #selector(focusWindowClicked(_:)),
            keyEquivalent: ""
        )
        item.target = self
        // Encode (windowId, pid) in representedObject as an NSArray
        item.representedObject = [NSNumber(value: w.windowId),
                                  NSNumber(value: w.pid)]
        if w.isFocused {
            item.state = .on
        }
        return item
    }

    /// A flatter, indented entry used directly under the workspace row.
    private func makeIndentedWindowItem(_ w: OverlayWindowEntry) -> NSMenuItem {
        let item = makeWindowItem(w)
        item.indentationLevel = 1
        return item
    }

    private func titleForWindow(_ w: OverlayWindowEntry) -> String {
        let app   = w.appName ?? "?"
        let title = w.title.map { String($0.prefix(80)) } ?? ""
        let marker: String
        if w.isFocused && w.isFloating {
            marker = "● ⊕ "
        } else if w.isFocused {
            marker = "● "
        } else if w.isFloating {
            marker = "⊕ "
        } else {
            marker = "  "
        }
        let body = title.isEmpty ? app : "\(app) — \(title)"
        return "\(marker)\(body)  [wid=\(w.windowId) pid=\(w.pid)]"
    }

    private func addDebugToggle(to menu: NSMenu, currentlyOn: Bool) {
        let item = NSMenuItem(
            title: "Debug frame overlays",
            action: #selector(toggleDebugClicked(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.state = currentlyOn ? .on : .off
        menu.addItem(item)
    }

    private func addFooter(to menu: NSMenu) {
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(
            title: "Quit mcmonad-core",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
    }

    // MARK: - Actions

    @objc private func toggleWhatsUpMonitoring(_ sender: Any?) {
        if whatsUpMonitoringEnabled?() == true {
            onSetWhatsUpMonitoring?(false)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Enable background summaries with OpenAI?"
        alert.informativeText = "While you are idle, mcmonad will send workspace names, app names, window titles and excerpts of recognised screen text to OpenAI through your Codex CLI, and, when Codex gives no answer, to Anthropic through your Claude CLI. This includes covered windows and hidden workspaces. This choice is remembered. Turn it off here to stop future calls and clear summaries; data already sent cannot be recalled."
        alert.addButton(withTitle: "Enable monitoring")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { onSetWhatsUpMonitoring?(true) }
    }

    @objc private func toggleDebugClicked(_ sender: Any?) {
        onToggleDebugOverlays?()
    }

    @objc private func openPrivacyClicked(_ sender: Any?) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func startAwakeClicked(_ sender: NSMenuItem) {
        guard let length = sender.representedObject as? String else { return }
        awake?.start(length: length)
    }

    @objc private func stopAwakeClicked(_ sender: Any?) {
        awake?.stop()
    }

    @objc private func openLoginItemsClicked(_ sender: Any?) {
        AwakeController.openLoginItems()
    }

    @objc private func copyAuditClicked(_ sender: Any?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(PermissionAudit.report(), forType: .string)
    }

    @objc private func searchWindowsClicked(_ sender: Any?) {
        onSearchWindows?()
    }

    @objc private func focusWindowClicked(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let arr  = item.representedObject as? [NSNumber],
              arr.count == 2 else { return }
        let wid = arr[0].uint32Value
        let pid = arr[1].int32Value
        onFocusWindow?(wid, pid)
    }

    @objc private func viewWorkspaceClicked(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let tag = item.representedObject as? String else { return }
        onViewWorkspace?(tag)
    }
}
