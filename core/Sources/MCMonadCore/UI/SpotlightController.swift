import AppKit
import os

/// A borderless panel that becomes key so its embedded search field can
/// receive keystrokes. mcmonad-core runs as an `.accessory` app, so we
/// also `NSApp.activate` before showing it.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// An `NSTextField` cell that vertically centres its text within tall bounds,
/// both when drawing and while editing. A plain cell top-aligns, which made a
/// large Spotlight font look clipped.
private final class VerticallyCenteredTextFieldCell: NSTextFieldCell {
    private func centered(_ rect: NSRect) -> NSRect {
        let h = cellSize(forBounds: rect).height
        guard h < rect.height else { return rect }
        let dy = (rect.height - h) / 2
        return NSRect(x: rect.minX, y: rect.minY + dy, width: rect.width, height: h)
    }
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        super.drawingRect(forBounds: centered(rect))
    }
    override func edit(withFrame rect: NSRect, in controlView: NSView,
                       editor: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: centered(rect), in: controlView,
                   editor: editor, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in controlView: NSView,
                         editor: NSText, delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: centered(rect), in: controlView,
                     editor: editor, delegate: delegate, start: start, length: length)
    }
}

/// The Spotlight-style launcher.
///
/// One floating key panel with switchable **modes**, cycled with `Tab`:
///
///   * `.command` — a command runner + app launcher. Type "timer" to be asked
///     for minutes, or "timer 15 check on agents" to set it inline; type an
///     app name ("chrome", "librewolf") to launch it.
///   * `.window` — the fuzzy window search across every workspace; selecting a
///     row reports `(windowId, pid)` via `onFocusWindow`, wired to the same
///     `menu-focus-window` IPC path the menubar uses.
///
/// `Opt+P` opens it in `.command`; `Opt+Shift+P` opens it in `.window`. A mic
/// button (or `⌘L`) drives voice input via `VoiceInput`: partial transcripts
/// stream into the field live, and the final transcript is interpreted as a
/// command (set a timer / launch an app / focus a window).
@MainActor
final class SpotlightController: NSObject, NSWindowDelegate,
    NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {

    private static let logger = Logger(
        subsystem: "com.mcmonad.core",
        category: "Spotlight"
    )

    // MARK: - Public wiring (set by Main)

    /// Supplies the freshest workspace/window snapshot at open time.
    var snapshotProvider: (() -> OverlaySnapshot?)?

    /// Fires with (windowId, pid) when the user picks a window.
    var onFocusWindow: ((UInt32, Int32) -> Void)?

    /// Fires when the user starts a timer (seconds, label).
    var onStartTimer: ((TimeInterval, String) -> Void)?

    // MARK: - Modes

    enum Mode: Int, CaseIterable {
        case command
        case window

        var placeholder: String {
            switch self {
            case .command: return "Run command or app…"
            case .window:  return "Search windows…"
            }
        }
        var label: String {
            switch self {
            case .command: return "Run"
            case .window:  return "Windows"
            }
        }
        var glyph: String {
            switch self {
            case .command: return "command"
            case .window:  return "macwindow"
            }
        }
        func next() -> Mode {
            let all = Mode.allCases
            return all[(rawValue + 1) % all.count]
        }
        func prev() -> Mode {
            let all = Mode.allCases
            return all[(rawValue - 1 + all.count) % all.count]
        }
    }

    private enum State {
        case browsing
        case timerPrompt   // command mode, after choosing "Timer": awaiting minutes
    }

    // MARK: - Items

    private enum Kind {
        case launchApp(AppIndex.AppEntry)
        case openTimerPrompt
        case startTimer(seconds: TimeInterval, label: String)
        case focusWindow(windowId: UInt32, pid: Int32)
        case hint
    }

    private struct Item {
        let title: String
        let kind: Kind
        let haystack: String
        var activatable: Bool {
            if case .hint = kind { return false }
            return true
        }
        var isOpenTimerPrompt: Bool {
            if case .openTimerPrompt = kind { return true }
            return false
        }
    }

    // MARK: - State

    private var mode: Mode = .command
    private var state: State = .browsing

    private let appIndex = AppIndex()
    private let voice = VoiceInput()
    private var voiceAuthorized: Bool?      // nil = not yet requested
    /// While true, a resign-key (e.g. the system mic/speech permission prompt
    /// taking focus, or live dictation) must not auto-dismiss the panel.
    private var keepOpenForVoice = false

    /// Base command-mode items (builtin commands + apps), rebuilt on show.
    private var commandBase: [Item] = []
    /// Window-mode items, rebuilt on show.
    private var windowBase: [Item] = []
    private var filtered: [Item] = []

    /// Icon caches.
    private var appIconCache: [String: NSImage] = [:]
    private var pidIconCache: [pid_t: NSImage] = [:]

    /// The window focused before the panel opened, restored on Esc.
    private var restoreTarget: (windowId: UInt32, pid: pid_t)?

    private var keyMonitor: Any?

    // MARK: - Views

    private var panel: KeyablePanel?
    private var searchField: NSTextField!
    private var tableView: NSTableView!
    private var glyphView: NSImageView!
    private var modeLabel: NSTextField!
    private var hintLabel: NSTextField!
    private var micButton: NSButton!

    private static let panelWidth: CGFloat = 660
    private static let panelHeight: CGFloat = 460
    private static let bandHeight: CGFloat = 66
    private static let footHeight: CGFloat = 24
    private static let pad: CGFloat = 10
    private static let rowHeight: CGFloat = 34
    private static let rowInset: CGFloat = 16
    private static let cellId = NSUserInterfaceItemIdentifier("spotlightRow")
    private static let topFraction: CGFloat = 0.20

    // MARK: - Public entry points

    /// Open in `mode`. If already open: switch to `mode` when it differs from
    /// the current one, otherwise close (pressing the same hotkey is a cancel).
    func toggle(mode: Mode) {
        if let panel, panel.isVisible {
            if state == .browsing, mode != self.mode {
                switchTo(mode)
            } else {
                cancel()
            }
        } else {
            show(mode: mode)
        }
    }

    func show(mode: Mode) {
        self.mode = mode
        self.state = .browsing
        let panel = ensurePanel()

        appIndex.refreshIfStale()
        rebuildBases()

        restoreTarget = WindowFocus.frontmostFocusedWindow()

        searchField.stringValue = ""
        applyModeChrome()
        applyFilter("")
        positionPanel(panel)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        installKeyMonitor()
        beginVoice()   // listen by default — speak or type
    }

    func hide() {
        voice.stop()
        removeKeyMonitor()
        panel?.orderOut(nil)
    }

    /// Dismiss having chosen something: don't restore prior focus.
    private func finish() {
        restoreTarget = nil
        hide()
    }

    /// Dismiss without choosing: hand focus back to the previously-focused
    /// window. In timerPrompt, the first Esc just returns to command browsing.
    private func cancel() {
        if state == .timerPrompt {
            state = .browsing
            searchField.stringValue = ""
            applyModeChrome()
            applyFilter("")
            return
        }
        let target = restoreTarget
        restoreTarget = nil
        hide()
        if let target {
            WindowFocus.focus(windowId: target.windowId, pid: target.pid)
        }
    }

    // MARK: - Mode chrome

    private func cycleMode(forward: Bool) {
        // Tab always returns to the top-level browsing state.
        switchTo(forward ? mode.next() : mode.prev())
    }

    /// Switch to a top-level mode, resetting any sub-prompt and the query.
    private func switchTo(_ newMode: Mode) {
        state = .browsing
        mode = newMode
        searchField.stringValue = ""
        applyModeChrome()
        applyFilter("")
        panel?.makeFirstResponder(searchField)
        beginVoice()
    }

    /// Update placeholder / glyph / mode label / hint for the current state.
    private func applyModeChrome() {
        let symbolCfg = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        let glyphName: String
        let placeholder: String
        let modeText: String
        switch state {
        case .timerPrompt:
            glyphName = "timer"
            placeholder = "Minutes — e.g. 15 check on agents"
            modeText = "Timer"
        case .browsing:
            glyphName = mode.glyph
            placeholder = mode.placeholder
            modeText = mode.label
        }
        glyphView.image = NSImage(systemSymbolName: glyphName, accessibilityDescription: modeText)?
            .withSymbolConfiguration(symbolCfg)
        searchField.placeholderString = placeholder
        modeLabel.stringValue = modeText.uppercased()
        updateHint()
    }

    private func updateHint() {
        let voiceHint: String
        if voiceAuthorized == false {
            voiceHint = ""
        } else if voice.isListening {
            voiceHint = " · 🎙 listening (type to switch)"
        } else {
            voiceHint = " · ⌘L voice"
        }
        switch state {
        case .timerPrompt:
            hintLabel.stringValue = "↩ start · ⇥ back\(voiceHint) · esc cancel"
        case .browsing:
            hintLabel.stringValue = "⇥ \(mode.next().label) · ↩ select\(voiceHint) · esc cancel"
        }
    }

    // MARK: - Panel construction

    private func ensurePanel() -> KeyablePanel {
        if let panel { return panel }

        let frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight)
        let panel = KeyablePanel(
            contentRect: frame,
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
        panel.delegate = self
        panel.appearance = NSAppearance(named: .vibrantDark)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSVisualEffectView(frame: frame)
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        panel.contentView = container

        // Leading mode glyph.
        let glyphSize: CGFloat = 26
        let glyph = NSImageView(frame: NSRect(
            x: Self.rowInset + 2,
            y: Self.panelHeight - Self.bandHeight / 2 - glyphSize / 2,
            width: glyphSize, height: glyphSize
        ))
        glyph.contentTintColor = .secondaryLabelColor
        glyph.imageScaling = .scaleProportionallyUpOrDown
        container.addSubview(glyph)
        self.glyphView = glyph

        // Mic button (trailing).
        let micSize: CGFloat = 26
        let mic = NSButton(frame: NSRect(
            x: Self.panelWidth - Self.rowInset - micSize,
            y: Self.panelHeight - Self.bandHeight / 2 - micSize / 2,
            width: micSize, height: micSize
        ))
        mic.bezelStyle = .regularSquare
        mic.isBordered = false
        mic.imagePosition = .imageOnly
        mic.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Voice")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .regular))
        mic.contentTintColor = .secondaryLabelColor
        mic.target = self
        mic.action = #selector(micClicked(_:))
        container.addSubview(mic)
        self.micButton = mic

        // Mode label (between field and mic).
        let modeW: CGFloat = 90
        let modeLbl = NSTextField(labelWithString: "")
        modeLbl.frame = NSRect(
            x: mic.frame.minX - modeW - 8,
            y: Self.panelHeight - Self.bandHeight / 2 - 9,
            width: modeW, height: 18
        )
        modeLbl.font = .systemFont(ofSize: 11, weight: .semibold)
        modeLbl.textColor = .tertiaryLabelColor
        modeLbl.alignment = .right
        container.addSubview(modeLbl)
        self.modeLabel = modeLbl

        // Search field.
        let fieldX = glyph.frame.maxX + 12
        let field = NSTextField(frame: NSRect(
            x: fieldX,
            y: Self.panelHeight - Self.bandHeight,
            width: modeLbl.frame.minX - fieldX - 8,
            height: Self.bandHeight
        ))
        field.cell = VerticallyCenteredTextFieldCell()
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 28, weight: .light)
        field.textColor = .labelColor
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.lineBreakMode = .byTruncatingTail
        field.delegate = self
        container.addSubview(field)
        self.searchField = field

        // Divider under the band.
        let divider = NSBox(frame: NSRect(
            x: 0, y: Self.panelHeight - Self.bandHeight,
            width: Self.panelWidth, height: 1
        ))
        divider.boxType = .separator
        container.addSubview(divider)

        // Footer hint.
        let foot = NSTextField(labelWithString: "")
        foot.frame = NSRect(x: Self.rowInset, y: 4,
                            width: Self.panelWidth - 2 * Self.rowInset, height: Self.footHeight - 6)
        foot.font = .systemFont(ofSize: 11)
        foot.textColor = .tertiaryLabelColor
        foot.alignment = .center
        container.addSubview(foot)
        self.hintLabel = foot

        // Results table.
        let scrollFrame = NSRect(
            x: 0, y: Self.footHeight,
            width: Self.panelWidth,
            height: Self.panelHeight - Self.bandHeight - Self.footHeight
        )
        let scroll = NSScrollView(frame: scrollFrame)
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false

        let table = NSTableView(frame: scrollFrame)
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.selectionHighlightStyle = .regular
        table.style = .plain
        table.allowsEmptySelection = false
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked(_:))

        let col = NSTableColumn(identifier: .init("item"))
        col.width = scrollFrame.width
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)

        scroll.documentView = table
        container.addSubview(scroll)
        self.tableView = table

        wireVoice()

        self.panel = panel
        return panel
    }

    private func positionPanel(_ panel: KeyablePanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let vis = screen?.visibleFrame else { return }
        let x = vis.midX - Self.panelWidth / 2
        let y = vis.maxY - Self.panelHeight - vis.height * Self.topFraction
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Building item bases

    private func rebuildBases() {
        // Command mode: builtin Timer command + every launchable app.
        var cmd: [Item] = [timerCommandItem()]
        for app in appIndex.apps {
            cmd.append(Item(
                title: app.name,
                kind: .launchApp(app),
                haystack: app.haystack
            ))
        }
        commandBase = cmd

        // Window mode: every window across every workspace.
        var wins: [Item] = []
        if let snap = snapshotProvider?() {
            func append(_ w: OverlayWindowEntry, tag: String) {
                let app = w.appName ?? "?"
                let title = w.title ?? ""
                let body = title.isEmpty ? app : "\(app) — \(title)"
                wins.append(Item(
                    title: "\(body)   ·  \(tag)",
                    kind: .focusWindow(windowId: w.windowId, pid: w.pid),
                    haystack: "\(app) \(title) \(tag)".lowercased()
                ))
            }
            for screen in snap.screens {
                for w in screen.windows { append(w, tag: screen.workspaceTag) }
            }
            for ws in snap.hiddenWorkspaces {
                for w in ws.windows { append(w, tag: ws.tag) }
            }
        }
        windowBase = wins
    }

    private func timerCommandItem() -> Item {
        Item(
            title: "Timer — set a countdown",
            kind: .openTimerPrompt,
            haystack: "timer countdown stopwatch alarm"
        )
    }

    private func timerStartItem(minutes: Int, label: String) -> Item {
        let suffix = label.isEmpty ? "" : " — \(label)"
        let unit = minutes == 1 ? "minute" : "minutes"
        return Item(
            title: "Start \(minutes)-\(unit) timer\(suffix)",
            kind: .startTimer(seconds: TimeInterval(minutes) * 60, label: label),
            haystack: "timer"
        )
    }

    private func hintItem(_ text: String) -> Item {
        Item(title: text, kind: .hint, haystack: "")
    }

    // MARK: - Filtering

    private func applyFilter(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)

        switch state {
        case .timerPrompt:
            let (m, label) = Self.extractMinutesAndLabel(Self.tokens(q))
            if let m {
                filtered = [timerStartItem(minutes: m, label: label)]
            } else {
                filtered = [hintItem("Type minutes, e.g. “15 check on agents”")]
            }

        case .browsing:
            // "timer …" is recognised in EVERY mode, so a countdown can be set
            // — typed or dictated — whether you're in command or window mode.
            var items: [Item] = []
            let timerCmd = Self.parseTimerCommand(q)
            if let parsed = timerCmd {
                if let m = parsed.minutes {
                    items.append(timerStartItem(minutes: m, label: parsed.label))
                } else {
                    items.append(timerCommandItem())
                }
            }
            switch mode {
            case .command:
                // Don't show the builtin Timer twice when a timer row is present.
                let base = timerCmd != nil
                    ? commandBase.filter { !$0.isOpenTimerPrompt }
                    : commandBase
                items += rank(q, in: base)
            case .window:
                items += rank(q, in: windowBase)
            }
            filtered = items
        }

        tableView?.reloadData()
        selectFirstActivatable()
    }

    /// Empty query → original order; otherwise fuzzy-rank.
    private func rank(_ query: String, in base: [Item]) -> [Item] {
        let q = query.lowercased()
        if q.isEmpty { return base }
        let scored = base.compactMap { item -> (Item, Int)? in
            FuzzyMatch.score(query: q, in: item.haystack).map { (item, $0) }
        }
        return scored
            .enumerated()
            .sorted { a, b in
                a.element.1 != b.element.1 ? a.element.1 > b.element.1 : a.offset < b.offset
            }
            .map { $0.element.0 }
    }

    private func selectFirstActivatable() {
        guard let row = filtered.firstIndex(where: { $0.activatable }) else { return }
        tableView?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    // MARK: - Activation

    private func activateSelection() {
        let row = tableView.selectedRow
        guard row >= 0, row < filtered.count else {
            // No selection but in timer prompt — try to submit the field directly.
            if state == .timerPrompt { submitTimerField() }
            return
        }
        activate(filtered[row])
    }

    private func activate(_ item: Item) {
        switch item.kind {
        case .launchApp(let app):
            finish()
            appIndex.launch(app)
        case .openTimerPrompt:
            enterTimerPrompt()
        case .startTimer(let secs, let label):
            finish()
            onStartTimer?(secs, label)
        case .focusWindow(let wid, let pid):
            finish()
            onFocusWindow?(wid, pid)
        case .hint:
            if state == .timerPrompt { submitTimerField() }
        }
    }

    private func enterTimerPrompt() {
        state = .timerPrompt
        searchField.stringValue = ""
        applyModeChrome()
        applyFilter("")
        beginVoice()   // speak the minutes too
    }

    /// Parse the timer-prompt field and start a timer if it has minutes.
    private func submitTimerField() {
        let (m, label) = Self.extractMinutesAndLabel(Self.tokens(searchField.stringValue))
        guard let m else { return }
        finish()
        onStartTimer?(TimeInterval(m) * 60, label)
    }

    // MARK: - Voice

    private func wireVoice() {
        voice.onPartial = { [weak self] text in
            guard let self else { return }
            self.searchField.stringValue = text
            self.applyFilter(text)
        }
        voice.onFinal = { [weak self] text in
            guard let self else { return }
            self.searchField.stringValue = text
            self.applyFilter(text)
            self.interpretVoice(text)
        }
        voice.onListeningChanged = { [weak self] listening in
            self?.updateMicButton(listening: listening)
            if !listening { self?.keepOpenForVoice = false }
            self?.updateHint()
        }
        voice.onError = { [weak self] msg in
            self?.hintLabel.stringValue = msg
        }
    }

    @objc private func micClicked(_ sender: Any?) {
        toggleVoice()
    }

    /// Manual mic toggle (button / ⌘L): stop if listening, else start.
    private func toggleVoice() {
        if voice.isListening {
            voice.stop()
        } else {
            beginVoice()
        }
    }

    /// Start listening. The launcher calls this whenever it presents a fresh
    /// input field (open, mode switch, timer prompt), so voice is live by
    /// default — no trigger needed. Safe to call when already listening
    /// (no-op) or when permission is known-denied (no-op).
    private func beginVoice() {
        guard voiceAuthorized != false, !voice.isListening else { return }
        keepOpenForVoice = true
        if voiceAuthorized == true {
            voice.start()
            return
        }
        // First use: request permission, then start if granted.
        hintLabel.stringValue = "Requesting microphone & speech permission…"
        voice.requestAuthorization { granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.voiceAuthorized = granted
                self.updateHint()
                if granted {
                    self.voice.start()
                } else {
                    self.keepOpenForVoice = false
                    self.micButton.isHidden = true
                    self.hintLabel.stringValue =
                        "Voice unavailable — grant Microphone & Speech Recognition in System Settings."
                }
            }
        }
    }

    private func updateMicButton(listening: Bool) {
        let name = listening ? "mic.fill" : "mic"
        micButton.image = NSImage(systemSymbolName: name, accessibilityDescription: "Voice")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .regular))
        micButton.contentTintColor = listening ? .systemRed : .secondaryLabelColor
    }

    /// Act on a final voice transcript according to the current state.
    private func interpretVoice(_ text: String) {
        if state == .timerPrompt {
            submitTimerField()
            return
        }
        // A spoken "timer …" sets a countdown in ANY mode — dictation isn't
        // gated by which mode the launcher happens to be in.
        if let parsed = Self.parseTimerCommand(text) {
            if let m = parsed.minutes {
                finish()
                onStartTimer?(TimeInterval(m) * 60, parsed.label)
            } else {
                enterTimerPrompt()
            }
            return
        }
        // Otherwise act on the top result for the current mode:
        // command → launch the best-matching app; window → focus the window.
        activateSelection()
    }

    // MARK: - Local key monitor (⌘L toggles voice)

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "l" {
                self.toggleVoice()
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    // MARK: - Icons

    private func appIcon(for app: AppIndex.AppEntry) -> NSImage {
        let path = app.url.path
        if let cached = appIconCache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 22, height: 22)
        appIconCache[path] = icon
        return icon
    }

    private func windowIcon(pid: Int32) -> NSImage? {
        if let cached = pidIconCache[pid] { return cached }
        guard let icon = NSRunningApplication(processIdentifier: pid)?.icon else { return nil }
        icon.size = NSSize(width: 22, height: 22)
        pidIconCache[pid] = icon
        return icon
    }

    private func symbolIcon(_ name: String) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .regular))
        img?.size = NSSize(width: 22, height: 22)
        return img
    }

    // MARK: - NSTableView data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row >= 0, row < filtered.count else { return nil }
        let item = filtered[row]
        let cell = (tableView.makeView(withIdentifier: Self.cellId, owner: self)
                    as? NSTableCellView) ?? Self.makeCellView()
        cell.textField?.stringValue = item.title
        cell.imageView?.image = icon(for: item)
        return cell
    }

    /// Icon for a row, resolved lazily so opening the launcher does not eagerly
    /// load an icon for every installed app — only visible rows pay the cost.
    private func icon(for item: Item) -> NSImage? {
        switch item.kind {
        case .launchApp(let app):       return appIcon(for: app)
        case .focusWindow(_, let pid):  return windowIcon(pid: pid)
        case .openTimerPrompt, .startTimer: return symbolIcon("timer")
        case .hint:                     return symbolIcon("info.circle")
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard row >= 0, row < filtered.count else { return false }
        return filtered[row].activatable
    }

    private static func makeCellView() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = cellId

        let iv = NSImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.imageScaling = .scaleProportionallyDown
        cell.addSubview(iv)
        cell.imageView = iv

        let tf = NSTextField(labelWithString: "")
        tf.font = .systemFont(ofSize: 14)
        tf.lineBreakMode = .byTruncatingTail
        tf.cell?.truncatesLastVisibleLine = true
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf)
        cell.textField = tf

        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: rowInset),
            iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: 22),
            iv.heightAnchor.constraint(equalToConstant: 22),
            tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 10),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -rowInset),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    @objc private func rowDoubleClicked(_ sender: Any?) {
        activateSelection()
    }

    // MARK: - Search field keyboard handling

    func controlTextDidChange(_ obj: Notification) {
        // A real keystroke (programmatic transcript updates don't fire this)
        // means the user chose to type — hand off from voice to keyboard so
        // partials stop overwriting what they're typing.
        if voice.isListening { voice.stop() }
        applyFilter(searchField.stringValue)
    }

    func control(_ control: NSControl,
                 textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1); return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1); return true
        case #selector(NSResponder.insertNewline(_:)):
            activateSelection(); return true
        case #selector(NSResponder.insertTab(_:)):
            cycleMode(forward: true); return true
        case #selector(NSResponder.insertBacktab(_:)):
            cycleMode(forward: false); return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel(); return true
        default:
            return false
        }
    }

    private func moveSelection(by delta: Int) {
        guard !filtered.isEmpty else { return }
        let activatableRows = filtered.indices.filter { filtered[$0].activatable }
        guard !activatableRows.isEmpty else { return }
        let current = tableView.selectedRow
        let idxInList = activatableRows.firstIndex(of: current) ?? 0
        let nextIdx = min(max(idxInList + delta, 0), activatableRows.count - 1)
        let next = activatableRows[nextIdx]
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // Don't dismiss while the mic/speech permission prompt is up or live
        // dictation is running — those steal key focus transiently.
        if keepOpenForVoice { return }
        voice.stop()
        removeKeyMonitor()
        // Click-away dismissal: don't yank focus back (user moved it).
        panel?.orderOut(nil)
    }

    // MARK: - Command parsing helpers

    /// Split a string into whitespace-separated tokens (original case).
    static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    /// Parse a command-mode string. Returns nil if it isn't a "timer …"
    /// command. Otherwise the minutes (nil if none yet) and a label.
    static func parseTimerCommand(_ text: String) -> (minutes: Int?, label: String)? {
        let toks = tokens(text)
        guard let first = toks.first?.lowercased(),
              first == "timer" || first == "timer:"
        else { return nil }
        return extractMinutesAndLabel(Array(toks.dropFirst()))
    }

    /// From a token list, pull the first number (digits or number word) as
    /// minutes and join the remaining tokens (original case) as the label.
    static func extractMinutesAndLabel(_ toks: [String]) -> (Int?, String) {
        var minutes: Int?
        var minuteIdx: Int?
        for (i, tok) in toks.enumerated() {
            if let n = numberValue(tok.lowercased()) {
                minutes = n
                minuteIdx = i
                break
            }
        }
        let label = toks.enumerated()
            .filter { $0.offset != minuteIdx }
            .map { $0.element }
            .joined(separator: " ")
        return (minutes, label)
    }

    private static let numberWords: [String: Int] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20,
        "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "ninety": 90,
    ]

    /// Interpret a token as a small positive integer: digits, or an English
    /// number word (so a voice transcript of "fifteen" works as 15). Strips a
    /// trailing "m"/"min"/"mins"/"minute(s)" unit if present.
    static func numberValue(_ token: String) -> Int? {
        var t = token
        for unit in ["minutes", "minute", "mins", "min", "m"] where t.hasSuffix(unit) && t != unit {
            t = String(t.dropLast(unit.count))
            break
        }
        if let n = Int(t), n > 0, n <= 1440 { return n }
        return numberWords[t]
    }
}
