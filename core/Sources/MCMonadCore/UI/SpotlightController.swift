import AppKit
import os

/// A borderless panel that becomes key so its embedded search field can
/// receive keystrokes. mcmonad-core runs as an `.accessory` app, so we
/// also `NSApp.activate` before showing it.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
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

    /// Fires with a workspace tag when the user picks a "what's up" row.
    var onViewWorkspace: ((String) -> Void)?

    /// The attached displays with their current roles, for the "screen"
    /// rows (wired by Main).
    var displays: (() -> [(AttachedDisplay, ScreenRole)])?
    /// Fires when the user gives a display a role.
    var onSetScreenRole: ((String, ScreenRole) -> Void)?

    /// The in-memory OCR index of displayed windows (wired by Main). Read
    /// on every filter pass so a window can be found by what is written in
    /// it; its text is never copied anywhere else.
    var screenIndex: ScreenIndex?

    /// Recency for every list the launcher shows. Focus events touch
    /// windows (Main); picks here touch whatever was picked.
    let recentUse = RecentUse()

    /// Cached per-workspace summaries, refreshed by the window manager's own
    /// reports (wired by Main). "What's up" reads it; it never waits on a call.
    var whatsUpCache: WhatsUpCache?

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
        case asking        // "where is …" sent to the model; transcript on screen
        case answered      // the model's list (or its failure) on screen
    }

    // MARK: - Items

    private enum Kind {
        case launchApp(AppIndex.AppEntry)
        case openTimerPrompt
        case startTimer(seconds: TimeInterval, label: String)
        case screenshot(ScreenshotCommand)
        case focusWindow(windowId: UInt32, pid: Int32)
        case whereIs(WhereIsQuery)
        case whatsUp
        case viewWorkspace(tag: String)
        case setScreenRole(uuid: String, role: ScreenRole)
        case hint
    }

    private struct Item {
        let title: String
        let kind: Kind
        let haystack: String
        /// Key into `recentUse`; nil for rows that have no recency (hints).
        var recentKey: String? = nil
        /// Second line: a highlighted text excerpt or the model's reason.
        var subtitle: NSAttributedString? = nil
        /// For window rows: the id to look up in the screen index.
        var windowId: UInt32? {
            if case .focusWindow(let id, _) = kind { return id }
            return nil
        }
        var activatable: Bool {
            if case .hint = kind { return false }
            return true
        }
        var isOpenTimerPrompt: Bool {
            if case .openTimerPrompt = kind { return true }
            return false
        }
        var isScreenshot: Bool {
            if case .screenshot = kind { return true }
            return false
        }
        var isWhatsUp: Bool {
            if case .whatsUp = kind { return true }
            return false
        }
    }

    // MARK: - State

    private var mode: Mode = .command
    private var state: State = .browsing

    private let appIndex = AppIndex()
    private let screenshotPicker = ScreenshotRegionPicker()
    private let askRunner = AskRunner()
    /// The question being asked / just answered: its words (for
    /// highlighting) and the manifold it was asked about (for row order).
    private var askTerms: [String] = []
    private var askQuestion = ""
    /// The answered rows are the "what's up" cache; re-render on its updates.
    private var showingWhatsUp = false
    /// While asking: when the call started, and a 1 s tick for the hint and
    /// the deadline.
    private var askStarted = Date()
    private var askTicker: Timer?
    private static let askDeadline: TimeInterval = 120
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

    /// Mirror of "the search field's editor currently holds first
    /// responder", maintained on the main thread by the
    /// `controlTextDidBeginEditing`/`controlTextDidEndEditing` delegate
    /// callbacks. Read by the local key monitor's closure.
    ///
    /// `nonisolated(unsafe)` on purpose: the local monitor is always
    /// delivered on the main thread and so is every writer, so there is no
    /// real data race — but the monitor's closure must stay *non*-isolated
    /// (see `installKeyMonitor`), which means it cannot touch `@MainActor`
    /// state. A plain stored flag it can read is the whole point.
    private nonisolated(unsafe) var editorHasFocus = false

    // MARK: - Views

    private var panel: KeyablePanel?
    private var searchField: NSTextField!
    private var tableView: NSTableView!
    private var glyphView: NSImageView!
    private var modeLabel: NSTextField!
    private var hintLabel: NSTextField!
    private var micButton: NSButton!
    private var resultsScroll: NSScrollView!
    private var transcriptScroll: NSScrollView!
    private var transcriptView: NSTextView!
    private var spinner: SpinnerView!

    private static let panelWidth: CGFloat = 660
    private static let panelHeight: CGFloat = 460
    private static let bandHeight: CGFloat = 66
    private static let footHeight: CGFloat = 24
    private static let pad: CGFloat = 10
    private static let rowHeight: CGFloat = 34
    /// Width the row text wraps in: panel minus insets, icon, gap, scroller.
    private static let rowTextWidth: CGFloat = panelWidth - 2 * rowInset - 22 - 10 - 14
    private static let rowPadding: CGFloat = 14
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
        // "At a given moment": re-read the displayed windows as the launcher opens.
        screenIndex?.requestSoon(after: 0)

        restoreTarget = WindowFocus.frontmostFocusedWindow()

        searchField.stringValue = ""
        applyModeChrome()
        applyFilter("")
        positionPanel(panel)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        installKeyMonitor()
        // Voice is ON BY DEFAULT: start listening the moment the launcher opens
        // so a command can be spoken immediately. Typing hands off to the
        // keyboard (controlTextDidChange stops voice), and dismissing stops it.
        // This holds the mic — and shows the orange mic indicator — for as long
        // as the launcher is open, which is the intended behaviour.
        beginVoice()
    }

    func hide() {
        voice.stop()
        leaveWhereIs()
        removeKeyMonitor()
        panel?.orderOut(nil)
    }

    /// The screen index changed while the launcher may be open: re-rank a
    /// live window search, unless the user has moved the selection.
    func screenIndexUpdated() {
        guard let panel, panel.isVisible, state == .browsing, mode == .window,
              !searchField.stringValue.isEmpty,
              tableView.selectedRow <= (filtered.firstIndex { $0.activatable } ?? 0)
        else { return }
        applyFilter(searchField.stringValue)
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
        if state == .asking || state == .answered {
            // First Esc leaves the question, keeping its text to edit.
            leaveWhereIs()
            state = .browsing
            applyModeChrome()
            applyFilter(searchField.stringValue)
            panel?.makeFirstResponder(searchField)
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
        leaveWhereIs()
        state = .browsing
        mode = newMode
        searchField.stringValue = ""
        applyModeChrome()
        applyFilter("")
        panel?.makeFirstResponder(searchField)
        // Keep voice live across mode switches (no-op if already listening).
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
        case .asking:
            glyphName = "sparkles"
            placeholder = "where is …"
            modeText = "Asking"
        case .answered:
            glyphName = "sparkles"
            placeholder = "where is …"
            modeText = "Where is"
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
        case .asking:
            let secs = Int(Date().timeIntervalSince(askStarted))
            hintLabel.stringValue = "asking \(Ask.model) at \(Ask.effort) effort · \(secs) s · esc cancel"
        case .answered:
            hintLabel.stringValue = "↩ select · esc back"
        case .browsing:
            var ocr = ""
            if mode == .window, screenIndex?.availability == .denied {
                ocr = " · ⚠ screen index: grant Screen Recording to MCMonadCore.app"
            }
            hintLabel.stringValue = "⇥ \(mode.next().label) · ↩ select\(voiceHint) · esc cancel\(ocr)"
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
        //
        // Sized to its natural single-line height and centred in the band
        // with the same arithmetic as the glyph and the mic, rather than
        // stretched to the full band height with a cell subclass doing the
        // centring. That subclass overrode NSTextFieldCell.drawingRect(
        // forBounds:) — an @objc override on a @MainActor-isolated type,
        // which AppKit calls from inside a CATransaction commit. The @objc
        // thunk runs a dynamic actor-isolation check on that path and the
        // check intermittently segfaulted inside
        // swift_task_isCurrentExecutorWithFlags, taking the whole daemon
        // down. Opening this panel was a coin flip. No override, no thunk,
        // no check.
        let fieldX = glyph.frame.maxX + 12
        let fieldW = modeLbl.frame.minX - fieldX - 8
        let field = NSTextField(frame: NSRect(
            x: fieldX,
            y: Self.panelHeight - Self.bandHeight,
            width: fieldW,
            height: Self.bandHeight
        ))
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

        // Measure the natural line height off a sample with both an
        // ascender and a descender, so the result doesn't depend on what
        // the user has typed (an empty field measures short), then centre
        // that height in the band.
        field.stringValue = "Ag"
        field.sizeToFit()
        let fieldH = ceil(field.frame.height)
        field.stringValue = ""
        field.frame = NSRect(
            x: fieldX,
            y: Self.panelHeight - Self.bandHeight / 2 - fieldH / 2,
            width: fieldW,
            height: fieldH
        )

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
        self.resultsScroll = scroll

        // "Where is": a muted spinner behind the live transcript of what we
        // send the model and what it streams back. Both hidden until asked.
        let spinnerSide: CGFloat = 220
        let spin = SpinnerView(frame: NSRect(
            x: scrollFrame.midX - spinnerSide / 2,
            y: scrollFrame.midY - spinnerSide / 2,
            width: spinnerSide, height: spinnerSide
        ))
        spin.isHidden = true
        container.addSubview(spin)
        self.spinner = spin

        let tScroll = NSScrollView(frame: scrollFrame)
        tScroll.hasVerticalScroller = true
        tScroll.drawsBackground = false
        tScroll.borderType = .noBorder
        tScroll.automaticallyAdjustsContentInsets = false
        let tv = NSTextView(frame: NSRect(origin: .zero, size: scrollFrame.size))
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textColor = .secondaryLabelColor
        tv.textContainerInset = NSSize(width: Self.rowInset - 4, height: 8)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: scrollFrame.width, height: .greatestFiniteMagnitude)
        tScroll.documentView = tv
        tScroll.isHidden = true
        container.addSubview(tScroll)
        self.transcriptScroll = tScroll
        self.transcriptView = tv

        askRunner.onTranscript = { [weak self] text in self?.appendTranscript(text) }
        askRunner.onNote = { [weak self] text in self?.appendTranscript("\n· \(text)\n") }
        askRunner.onFinished = { [weak self] outcome in self?.finishAsk(outcome) }

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
        // The builtin Screenshot replaces the system app's duplicate row.
        var cmd: [Item] = [timerCommandItem(), screenshotItem(.interactive), whatsUpItem()]
        // One row per display per other role: "screen" lists them all,
        // typing a display or role name narrows them.
        for (d, current) in displays?() ?? [] {
            for role in ScreenRole.allCases where role != current {
                let size = "\(Int(d.frame.width))×\(Int(d.frame.height))"
                cmd.append(Item(
                    title: "Screen \(d.name) (\(size), now \(current.label)) → make \(role.label)",
                    kind: .setScreenRole(uuid: d.uuid, role: role),
                    haystack: "screen display monitor \(d.name) \(current.label) \(role.label)".lowercased()
                ))
            }
        }
        for app in appIndex.apps where app.bundleId != "com.apple.screenshot.launcher" {
            cmd.append(Item(
                title: app.name,
                kind: .launchApp(app),
                haystack: app.haystack,
                recentKey: RecentUse.app(bundleId: app.bundleId, path: app.url.path)
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
                    haystack: "\(app) \(title) \(tag)".lowercased(),
                    recentKey: RecentUse.window(w.windowId)
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
            haystack: "timer countdown stopwatch alarm",
            recentKey: RecentUse.timer
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

    private func screenshotItem(_ command: ScreenshotCommand) -> Item {
        Item(title: command.title, kind: .screenshot(command), haystack: "screenshot",
             recentKey: RecentUse.screenshot)
    }

    private func whereIsItem(_ query: WhereIsQuery) -> Item {
        Item(title: "Ask \(Ask.model) where “\(query.question)” is",
             kind: .whereIs(query), haystack: "")
    }

    private func whatsUpItem() -> Item {
        Item(title: "What's up — one line per workspace, from \(Ask.model)",
             kind: .whatsUp, haystack: "what's up whats up sup summary workspaces overview",
             recentKey: RecentUse.whatsUp)
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

        case .asking:
            filtered = []

        case .answered:
            // `filtered` is the model's answer; typing leaves this state
            // (see controlTextDidChange) rather than re-ranking it.
            break

        case .browsing:
            // Builtin commands work in both command and window-search mode.
            var items: [Item] = []
            if let ask = WhereIsQuery(q) {
                items.append(whereIsItem(ask))
            }
            let whatsUp = WhatsUp.matches(q)
            if whatsUp {
                items.append(whatsUpItem())
            }
            let screenshotCmd = ScreenshotCommand(q)
            if let screenshotCmd {
                items.append(screenshotItem(screenshotCmd))
            }
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
                // Don't show builtin commands twice when a parsed row is present.
                let base = commandBase.filter {
                    !(timerCmd != nil && $0.isOpenTimerPrompt)
                        && !(screenshotCmd != nil && $0.isScreenshot)
                        && !(whatsUp && $0.isWhatsUp)
                }
                items += rank(q, in: base)
            case .window:
                items += rankWindows(q)
            }
            filtered = items
        }

        tableView?.reloadData()
        selectFirstActivatable()
    }

    /// Empty query → most recently used first; otherwise fuzzy-rank, with
    /// recency breaking ties.
    private func rank(_ query: String, in base: [Item]) -> [Item] {
        let q = query.lowercased()
        if q.isEmpty { return RecentUse.order(base) { recentUse.stamp($0.recentKey) } }
        let scored = base.compactMap { item -> (Item, Int)? in
            FuzzyMatch.score(query: q, in: item.haystack).map { (item, $0) }
        }
        return sortScored(scored)
    }

    /// Window search: a title/app/tag fuzzy match ranks as before; failing
    /// that, a window whose recognised text contains every query word is
    /// listed below the title matches with the matching line as its second
    /// row, the words highlighted.
    private func rankWindows(_ query: String) -> [Item] {
        let q = query.lowercased()
        if q.isEmpty { return RecentUse.order(windowBase) { recentUse.stamp($0.recentKey) } }
        let terms = TextSearch.terms(query)
        var scored: [(Item, Int)] = []
        for item in windowBase {
            if let score = FuzzyMatch.score(query: q, in: item.haystack) {
                scored.append((item, score))
                continue
            }
            guard let wid = item.windowId, let entry = screenIndex?.entry(for: wid),
                  let hit = TextSearch.hit(terms: terms, in: entry.text, lower: entry.lower)
            else { continue }
            var row = item
            row.subtitle = Self.highlighted(hit.snippet, ranges: hit.ranges)
            scored.append((row, 1))   // any title match outranks a text match
        }
        return sortScored(scored)
    }

    private func sortScored(_ scored: [(Item, Int)]) -> [Item] {
        scored.enumerated()
            .sorted { a, b in
                if a.element.1 != b.element.1 { return a.element.1 > b.element.1 }
                let ra = recentUse.stamp(a.element.0.recentKey)
                let rb = recentUse.stamp(b.element.0.recentKey)
                if ra != rb { return ra > rb }
                return a.offset < b.offset
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
        if let key = item.recentKey { recentUse.touch(key) }
        switch item.kind {
        case .whereIs(let query):
            beginWhereIs(query)
        case .whatsUp:
            beginWhatsUp()
        case .viewWorkspace(let tag):
            finish()
            onViewWorkspace?(tag)
        case .setScreenRole(let uuid, let role):
            finish()
            onSetScreenRole?(uuid, role)
        case .launchApp(let app):
            finish()
            appIndex.launch(app)
        case .openTimerPrompt:
            enterTimerPrompt()
        case .startTimer(let secs, let label):
            finish()
            onStartTimer?(secs, label)
        case .screenshot(let command):
            // Restore the previous window before capturing, as on Escape.
            let target = restoreTarget
            cancel()
            if case .delayed = command {
                screenshotPicker.select(restoring: target) { command.run(region: $0) }
            } else {
                command.run()
            }
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
        // Voice stays live for the timer prompt too (no-op if already listening).
        beginVoice()
    }

    /// Parse the timer-prompt field and start a timer if it has minutes.
    private func submitTimerField() {
        let (m, label) = Self.extractMinutesAndLabel(Self.tokens(searchField.stringValue))
        guard let m else { return }
        finish()
        onStartTimer?(TimeInterval(m) * 60, label)
    }

    // MARK: - Questions to the model ("where is …", "what's up")

    private func beginWhereIs(_ query: WhereIsQuery) {
        beginAsk(question: query.question, terms: query.terms, arguments: WhereIs.arguments) { manifold in
            let known = manifold.windowIds
            return { WhereIs.parseLine($0, known: known) }
        }
    }

    /// Cached rows at once; stale workspaces refresh behind them and the
    /// rows update in place when the call lands.
    private func beginWhatsUp() {
        guard let cache = whatsUpCache else { return }
        leaveWhereIs()
        askTerms = []
        askQuestion = WhatsUp.question
        showingWhatsUp = true
        state = .answered
        applyModeChrome()
        cache.refreshNow()
        renderWhatsUp()
    }

    private func renderWhatsUp() {
        guard let cache = whatsUpCache else { return }
        filtered = cache.rows.map { r in
            let head: String
            if let s = r.summary {
                head = s.summary + (r.refreshing ? "   (refreshing…)" : "")
            } else {
                head = r.refreshing ? "summarising…" : "no summary given"
            }
            return Item(
                title: "\(r.tag)   ·  \(head)",
                kind: .viewWorkspace(tag: r.tag),
                haystack: "",
                subtitle: Self.highlighted("why: " + (r.summary?.reason ?? "…"), ranges: [])
            )
        }
        if filtered.isEmpty {
            filtered = [hintItem("No workspace has any window.")]
        }
        if cache.isRefreshing { spinner.start() } else { spinner.stop() }
        let keep = tableView.selectedRow
        showResults()
        if keep >= 0, keep < filtered.count, filtered[keep].activatable {
            tableView.selectRowIndexes(IndexSet(integer: keep), byExtendingSelection: false)
        }
    }

    /// The cache changed (a call started or landed) while its rows may be up.
    func whatsUpUpdated() {
        guard let panel, panel.isVisible, state == .answered, showingWhatsUp else { return }
        renderWhatsUp()
    }

    /// Send the question and the manifold of every window to the model, and
    /// show the exchange while it thinks. `parse` is built once the manifold
    /// exists, so the answer can be checked against what was asked about.
    private func beginAsk(
        question: String, terms: [String], arguments: [String],
        parse: (Ask.Manifold) -> @Sendable (String) -> Ask.StreamItem
    ) {
        leaveWhereIs()
        askTerms = terms
        askQuestion = question
        showingWhatsUp = false
        state = .asking
        askStarted = Date()
        askTicker?.invalidate()
        askTicker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.askTick() }
        }
        filtered = []
        tableView.reloadData()
        applyModeChrome()
        transcriptView.string = ""
        showTranscript(true)
        spinner.start()

        guard let snap = snapshotProvider?() else {
            finishAsk(.unavailable("The brain has not sent a window snapshot yet."))
            return
        }
        let manifold = Ask.manifold(
            question: question,
            snapshot: snap,
            text: { [weak self] wid in self?.screenIndex?.entry(for: wid)?.text }
        )
        let prompt = Ask.prompt(for: manifold)
        let cli = AskRunner.locateCLI() ?? "claude"
        let windows = manifold.workspaces.reduce(0) { $0 + $1.windows.count }
        appendTranscript("→ \(cli) " + arguments.map(Self.shellQuoted).joined(separator: " ") + "\n\n")
        appendTranscript("→ stdin (\(prompt.count) chars, \(windows) windows on \(manifold.workspaces.count) workspaces):\n\(prompt)\n\n← ")
        askRunner.start(prompt: prompt, arguments: arguments, parse: parse(manifold))
    }

    /// Once a second while asking: the hint counts up; past the deadline the
    /// call is given up as failed rather than left looking stuck.
    private func askTick() {
        guard state == .asking else { askTicker?.invalidate(); askTicker = nil; return }
        if Date().timeIntervalSince(askStarted) >= Self.askDeadline {
            askRunner.cancel()
            finishAsk(.failed("no answer within \(Int(Self.askDeadline)) s; the call was stopped"))
            return
        }
        updateHint()
    }

    private func finishAsk(_ outcome: Ask.Outcome) {
        spinner.stop()
        askTicker?.invalidate()
        askTicker = nil
        guard state == .asking else { return }
        appendTranscript("\n· done in \(Int(Date().timeIntervalSince(askStarted))) s\n")
        state = .answered
        switch outcome {
        case .answered(.windows(let matches, let dropped)):
            appendTranscript("\n\n✓ \(matches.count) match(es)"
                + (dropped > 0 ? ", \(dropped) id(s) not in the manifold ignored" : "") + "\n")
            var byId: [UInt32: (OverlayWindowEntry, String)] = [:]
            if let snap = snapshotProvider?() {
                for s in snap.screens { for w in s.windows { byId[w.windowId] = (w, s.workspaceTag) } }
                for ws in snap.hiddenWorkspaces { for w in ws.windows { byId[w.windowId] = (w, ws.tag) } }
            }
            filtered = matches.compactMap { m -> Item? in
                guard let (w, tag) = byId[m.windowId] else { return nil }
                let app = w.appName ?? "?"
                let title = w.title ?? ""
                let body = title.isEmpty ? app : "\(app) — \(title)"
                return Item(
                    title: "\(body)   ·  \(tag)",
                    kind: .focusWindow(windowId: w.windowId, pid: w.pid),
                    haystack: "",
                    recentKey: RecentUse.window(w.windowId),
                    subtitle: Self.highlighted(m.reason, ranges: TextSearch.ranges(of: askTerms, in: m.reason))
                )
            }
            if filtered.isEmpty {
                filtered = [hintItem("Nothing on any workspace looks like “\(askQuestion)”.")]
            }
            showResults()
        case .answered(.workspaces):
            // Workspace summaries come through WhatsUpCache, never this runner.
            break
        case .unavailable(let why):
            appendTranscript("\n\n✗ unavailable: \(why)\n")
        case .failed(let why):
            appendTranscript("\n\n✗ failed: \(why)\n")
        case .malformed(let why):
            appendTranscript("\n\n✗ not the expected answer: \(why)\n")
        }
        applyModeChrome()
    }

    private func showResults() {
        showTranscript(false)
        tableView.reloadData()
        selectFirstActivatable()
    }

    /// Stop any question in flight and put the results table back.
    private func leaveWhereIs() {
        askRunner.cancel()
        askTicker?.invalidate()
        askTicker = nil
        spinner.stop()
        showTranscript(false)
        showingWhatsUp = false
    }

    private func showTranscript(_ on: Bool) {
        transcriptScroll?.isHidden = !on
        resultsScroll?.isHidden = on
    }

    private func appendTranscript(_ text: String) {
        guard let storage = transcriptView.textStorage else { return }
        storage.append(NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        transcriptView.scrollToEndOfDocument(nil)
    }

    private nonisolated static func shellQuoted(_ arg: String) -> String {
        if arg.isEmpty { return "''" }
        if arg.rangeOfCharacter(from: .whitespacesAndNewlines) == nil, !arg.contains("'") { return arg }
        return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Kagi-style: the matched words bold and orange inside a dimmer line.
    private static func highlighted(_ text: String, ranges: [NSRange]) -> NSAttributedString {
        let s = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        for r in ranges where r.location >= 0 && NSMaxRange(r) <= s.length {
            s.addAttributes([
                .font: NSFont.systemFont(ofSize: 11.5, weight: .bold),
                .foregroundColor: NSColor.systemOrange,
            ], range: r)
        }
        return s
    }

    private static let rowParagraph: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        p.lineSpacing = 1
        return p
    }()

    private static func rowText(_ item: Item) -> NSAttributedString {
        let s = NSMutableAttributedString(string: item.title, attributes: [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.labelColor,
        ])
        if let sub = item.subtitle {
            s.append(NSAttributedString(string: "\n"))
            s.append(sub)
        }
        s.addAttribute(.paragraphStyle, value: rowParagraph, range: NSRange(location: 0, length: s.length))
        return s
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

    /// Request mic/speech authorization once, at daemon startup, BEFORE any
    /// panel exists. The Spotlight panel sits at `.popUpMenu` level, so a TCC
    /// prompt requested while it's open appears *behind* it and silently
    /// resolves to notDetermined — which is why speech permission never stuck.
    /// Priming at startup surfaces the prompt cleanly (bringing the daemon
    /// forward only when a prompt will actually show).
    func primeVoiceAuthorization() {
        guard voiceAuthorized == nil else { return }
        if voice.needsAuthorizationPrompt {
            NSApp.activate(ignoringOtherApps: true)
        }
        voice.requestAuthorization { granted in
            Task { @MainActor [weak self] in
                self?.voiceAuthorized = granted
            }
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
        if state == .asking || state == .answered { return }
        // A spoken "where is …" or "what's up" asks the model, in any mode.
        if let ask = WhereIsQuery(text) {
            beginWhereIs(ask)
            return
        }
        if WhatsUp.matches(text) {
            beginWhatsUp()
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
        // The closure is intentionally *non*-isolated. AppKit invokes a
        // local monitor synchronously from -[NSApplication sendEvent:] via
        // its non-isolated handler type, so a `@MainActor` closure here
        // forces the compiler to insert a dynamic actor-isolation
        // precondition (swift_task_isCurrentExecutorWithFlags) on that
        // call path — and that check crashes the daemon in this runtime
        // (Bus error inside swift_getObjectType). It is the same landmine
        // that took down the VerticallyCenteredTextFieldCell override; the
        // cure is the same — don't cross the ObjC→Swift boundary into
        // `@MainActor` synchronously.
        //
        // So the closure decides *only* from non-isolated inputs (the
        // NSEvent's own fields and the `editorHasFocus` mirror) whether to
        // swallow the event, and defers every main-actor action through
        // `onMain`, the async hop this codebase already uses for its
        // Carbon-hotkey and CGEvent-tap callbacks. A one-runloop delay on
        // Enter/Esc/arrows/Tab is imperceptible.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // ⌘L toggles voice from anywhere in the panel.
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "l" {
                self.onMain { $0.toggleVoice() }
                return nil
            }
            // While the search field's editor holds first responder, its
            // control(_:textView:doCommandBy:) drives navigation — leave it
            // be so typing and the existing key handling are unchanged.
            if self.editorHasFocus {
                return event
            }
            // Focus is elsewhere — typically the results table grabbed first
            // responder on a mouse click. Route navigation keys here so Enter
            // activates the (blue) selection, Esc cancels, and arrows/Tab keep
            // working, instead of the table NSBeep'ing on an unhandled
            // Return/Escape. This is what made mouse-then-keyboard feel "stuck".
            switch event.keyCode {
            case 36, 76:   // Return, keypad Enter
                self.onMain { $0.activateSelection() }; return nil
            case 53:       // Escape
                self.onMain { $0.cancel() }; return nil
            case 125:      // Down arrow
                self.onMain { $0.moveSelection(by: 1) }; return nil
            case 126:      // Up arrow
                self.onMain { $0.moveSelection(by: -1) }; return nil
            case 48:       // Tab (Shift-Tab cycles back)
                let forward = !event.modifierFlags.contains(.shift)
                self.onMain { $0.cycleMode(forward: forward) }; return nil
            default:
                return event
            }
        }
    }

    /// Run `body` on the main actor on the next runloop tick. Nonisolated
    /// so the non-isolated key monitor can call it; the async hop is the
    /// same one HotkeyManager / MouseDownMonitor use, and it never inserts
    /// the synchronous isolation check that crashes.
    private nonisolated func onMain(
        _ body: @escaping @MainActor (SpotlightController) -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            body(self)
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
        cell.textField?.attributedStringValue = Self.rowText(item)
        cell.imageView?.image = icon(for: item)
        return cell
    }

    /// Rows take the space their text needs: a long summary and its reason
    /// wrap rather than get cut, a plain window row stays one line tall.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row >= 0, row < filtered.count else { return Self.rowHeight }
        let needed = Self.rowText(filtered[row]).boundingRect(
            with: NSSize(width: Self.rowTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
        return max(Self.rowHeight, ceil(needed) + Self.rowPadding)
    }

    /// Icon for a row, resolved lazily so opening the launcher does not eagerly
    /// load an icon for every installed app — only visible rows pay the cost.
    private func icon(for item: Item) -> NSImage? {
        switch item.kind {
        case .launchApp(let app):       return appIcon(for: app)
        case .focusWindow(_, let pid):  return windowIcon(pid: pid)
        case .openTimerPrompt, .startTimer: return symbolIcon("timer")
        case .screenshot:               return symbolIcon("camera")
        case .whereIs, .whatsUp:        return symbolIcon("sparkles")
        case .viewWorkspace:            return symbolIcon("rectangle.3.group")
        case .setScreenRole:            return symbolIcon("display.2")
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
        tf.lineBreakMode = .byWordWrapping
        tf.maximumNumberOfLines = 0
        tf.preferredMaxLayoutWidth = rowTextWidth
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
        if state == .asking || state == .answered {
            leaveWhereIs()
            state = .browsing
            applyModeChrome()
        }
        applyFilter(searchField.stringValue)
    }

    // Keep `editorHasFocus` in step with the field editor's lifecycle so
    // the non-isolated key monitor can tell "typing in the field" from
    // "the results table has first responder" without touching @MainActor
    // state (see installKeyMonitor). These fire on the main thread.
    func controlTextDidBeginEditing(_ obj: Notification) {
        editorHasFocus = true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        editorHasFocus = false
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
