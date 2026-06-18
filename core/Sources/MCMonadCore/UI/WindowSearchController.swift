import AppKit
import os

/// A borderless panel that becomes key so its embedded search field can
/// receive keystrokes. mcmonad-core runs as an `.accessory` app, so we
/// also `NSApp.activate` before showing it.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// An `NSTextField` cell that vertically centres its text within tall
/// bounds — both when drawing (placeholder/value) and while editing. A
/// plain `NSTextField`/`NSSearchField` top-aligns its text, which is why a
/// large font in a tall Spotlight-style field looked clipped/squished.
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

/// The Spotlight-style fuzzy window search.
///
/// A floating key panel centred in the upper third of the active screen: a
/// large search field on top and a live fuzzy-filtered list of every window
/// across every workspace below. Looks and behaves like macOS Spotlight.
///
/// Why a panel and not a field *inside* the NSMenu: an `NSMenu` runs its own
/// modal event-tracking loop that swallows key events before they reach an
/// embedded text field, and it will not re-lay-out its item list while open
/// — so neither text entry nor live filtering work reliably in a menu.
///
/// Selecting a row (Return or double-click) reports `(windowId, pid)` via
/// `onFocusWindow`, which Main wires to the same `menu-focus-window` IPC
/// event the menubar dropdown's window rows use — so the focus-and-jump
/// path is shared.
@MainActor
final class WindowSearchController: NSObject, NSWindowDelegate,
    NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {

    private static let logger = Logger(
        subsystem: "com.mcmonad.core",
        category: "WindowSearch"
    )

    /// Supplies the freshest workspace/window snapshot at open time.
    var snapshotProvider: (() -> OverlaySnapshot?)?

    /// Fires with (windowId, pid) when the user picks a window.
    var onFocusWindow: ((UInt32, Int32) -> Void)?

    /// Unused for positioning (the panel centres Spotlight-style); kept so
    /// existing wiring in Main compiles without change.
    var anchorButton: NSStatusBarButton?

    private var panel: KeyablePanel?
    private var searchField: NSTextField!
    private var tableView: NSTableView!

    private static let panelWidth: CGFloat = 660
    private static let panelHeight: CGFloat = 460
    private static let bandHeight: CGFloat = 66   // search-field area
    private static let pad: CGFloat = 10
    private static let rowHeight: CGFloat = 32
    private static let rowInset: CGFloat = 16
    private static let cellId = NSUserInterfaceItemIdentifier("windowRow")
    /// Fraction of the screen height to leave above the panel (Spotlight
    /// sits a bit above centre).
    private static let topFraction: CGFloat = 0.20

    /// One searchable window row.
    private struct Entry {
        let windowId: UInt32
        let pid: Int32
        let display: String
        let haystack: String
    }

    private var entries: [Entry] = []
    private var filtered: [Entry] = []

    // MARK: - Public entry points

    /// Toggle the dropdown: open it (or close it if already showing).
    func toggle() {
        if let panel, panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        loadEntries()
        let panel = ensurePanel()

        searchField.stringValue = ""
        applyFilter("")
        positionPanel(panel)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    // MARK: - Panel construction

    private func ensurePanel() -> KeyablePanel {
        if let panel { return panel }

        let frame = NSRect(x: 0, y: 0,
                           width: Self.panelWidth, height: Self.panelHeight)
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

        // Rounded, dark, translucent container — the Spotlight box.
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

        // Magnifier glyph.
        let glyphSize: CGFloat = 26
        let glyph = NSImageView(frame: NSRect(
            x: Self.rowInset + 2,
            y: Self.panelHeight - Self.bandHeight / 2 - glyphSize / 2,
            width: glyphSize, height: glyphSize
        ))
        let symbolCfg = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        glyph.image = NSImage(systemSymbolName: "magnifyingglass",
                              accessibilityDescription: "Search")?
            .withSymbolConfiguration(symbolCfg)
        glyph.contentTintColor = .secondaryLabelColor
        glyph.imageScaling = .scaleProportionallyUpOrDown
        container.addSubview(glyph)

        // Search field — large, borderless, vertically centred.
        let fieldX = glyph.frame.maxX + 12
        let field = NSTextField(frame: NSRect(
            x: fieldX,
            y: Self.panelHeight - Self.bandHeight,
            width: Self.panelWidth - fieldX - Self.rowInset,
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
        field.placeholderString = "Search windows…"
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.lineBreakMode = .byTruncatingTail
        field.delegate = self
        container.addSubview(field)
        self.searchField = field

        // Hairline divider under the search band.
        let divider = NSBox(frame: NSRect(
            x: 0,
            y: Self.panelHeight - Self.bandHeight,
            width: Self.panelWidth,
            height: 1
        ))
        divider.boxType = .separator
        container.addSubview(divider)

        // Results table inside a scroll view.
        let scrollFrame = NSRect(
            x: 0,
            y: Self.pad,
            width: Self.panelWidth,
            height: Self.panelHeight - Self.bandHeight - Self.pad
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

        let col = NSTableColumn(identifier: .init("window"))
        col.width = scrollFrame.width
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)

        scroll.documentView = table
        container.addSubview(scroll)
        self.tableView = table

        self.panel = panel
        return panel
    }

    private func positionPanel(_ panel: KeyablePanel) {
        // Spotlight-style: centred horizontally and a bit above centre on
        // the screen that currently has the mouse (falling back to main).
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let vis = screen?.visibleFrame else { return }
        let x = vis.midX - Self.panelWidth / 2
        let y = vis.maxY - Self.panelHeight - vis.height * Self.topFraction
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Data

    private func loadEntries() {
        entries.removeAll(keepingCapacity: true)
        guard let snap = snapshotProvider?() else { return }

        func append(_ w: OverlayWindowEntry, tag: String) {
            let app = w.appName ?? "?"
            let title = w.title ?? ""
            let body = title.isEmpty ? app : "\(app) — \(title)"
            let display = "\(body)   ·  \(tag)"
            let haystack = "\(app) \(title) \(tag)".lowercased()
            entries.append(Entry(
                windowId: w.windowId, pid: w.pid,
                display: display, haystack: haystack
            ))
        }

        for screen in snap.screens {
            for w in screen.windows { append(w, tag: screen.workspaceTag) }
        }
        for ws in snap.hiddenWorkspaces {
            for w in ws.windows { append(w, tag: ws.tag) }
        }
    }

    /// Filter + rank entries by a fuzzy subsequence match. Empty query
    /// shows everything in snapshot order.
    private func applyFilter(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty {
            filtered = entries
        } else {
            let scored = entries.compactMap { e -> (Entry, Int)? in
                guard let s = Self.fuzzyScore(query: q, in: e.haystack) else {
                    return nil
                }
                return (e, s)
            }
            // Higher score first; stable for equal scores.
            filtered = scored
                .enumerated()
                .sorted { a, b in
                    a.element.1 != b.element.1
                        ? a.element.1 > b.element.1
                        : a.offset < b.offset
                }
                .map { $0.element.0 }
        }
        tableView?.reloadData()
        if !filtered.isEmpty {
            tableView?.selectRowIndexes(IndexSet(integer: 0),
                                        byExtendingSelection: false)
        }
    }

    /// Order-preserving subsequence match. Returns nil when `query` is not
    /// a subsequence of `haystack`; otherwise a score rewarding contiguous
    /// runs and earlier matches.
    private static func fuzzyScore(query: String, in haystack: String) -> Int? {
        let hs = Array(haystack)
        let qs = Array(query)
        var hi = 0
        var score = 0
        var streak = 0
        for qc in qs {
            var matched = false
            while hi < hs.count {
                let hc = hs[hi]
                hi += 1
                if hc == qc {
                    streak += 1
                    // Contiguous matches and matches near the start score higher.
                    score += 10 + streak * 5 + max(0, 20 - hi)
                    matched = true
                    break
                } else {
                    streak = 0
                }
            }
            if !matched { return nil }
        }
        return score
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        filtered.count
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row >= 0, row < filtered.count else { return nil }
        let cell = (tableView.makeView(withIdentifier: Self.cellId, owner: self)
                    as? NSTableCellView) ?? Self.makeCellView()
        cell.textField?.stringValue = filtered[row].display
        return cell
    }

    private static func makeCellView() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = cellId
        let tf = NSTextField(labelWithString: "")
        tf.font = .systemFont(ofSize: 14)
        tf.lineBreakMode = .byTruncatingTail
        tf.cell?.truncatesLastVisibleLine = true
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf)
        cell.textField = tf
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: rowInset),
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
        case #selector(NSResponder.cancelOperation(_:)):
            hide(); return true
        default:
            return false
        }
    }

    private func moveSelection(by delta: Int) {
        guard !filtered.isEmpty else { return }
        let current = tableView.selectedRow
        let next = min(max(current + delta, 0), filtered.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next),
                                   byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    private func activateSelection() {
        let row = tableView.selectedRow
        guard row >= 0, row < filtered.count else { return }
        let e = filtered[row]
        hide()
        onFocusWindow?(e.windowId, e.pid)
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // Dismiss when focus leaves the dropdown (click elsewhere, etc.).
        hide()
    }
}
