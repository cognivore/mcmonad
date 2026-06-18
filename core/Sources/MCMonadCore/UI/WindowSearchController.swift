import AppKit
import os

/// A borderless panel that becomes key so its embedded search field can
/// receive keystrokes. mcmonad-core runs as an `.accessory` app, so we
/// also `NSApp.activate` before showing it.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The fuzzy window-search dropdown.
///
/// Drops down from the menubar icon (or screen-centre as a fallback when
/// there is no anchor) as a small panel: a search field on top and a live
/// fuzzy-filtered list of every window across every workspace below.
///
/// Why a panel instead of a field *inside* the NSMenu: an `NSMenu` runs its
/// own modal event-tracking loop that swallows key events before they reach
/// an embedded text field, and it will not re-lay-out its item list while
/// open — so neither text entry nor live filtering work reliably in a menu.
/// A key panel anchored under the icon reads as the dropdown while giving us
/// full control of keyboard and drawing.
///
/// Selecting a row (Return or double-click) reports `(windowId, pid)` via
/// `onFocusWindow`, which Main wires to the same `menu-focus-window` IPC
/// event the menubar dropdown's window rows use — so the focus-and-jump
/// path is shared.
@MainActor
final class WindowSearchController: NSObject, NSWindowDelegate,
    NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {

    private static let logger = Logger(
        subsystem: "com.mcmonad.core",
        category: "WindowSearch"
    )

    /// Supplies the freshest workspace/window snapshot at open time.
    var snapshotProvider: (() -> OverlaySnapshot?)?

    /// Fires with (windowId, pid) when the user picks a window.
    var onFocusWindow: ((UInt32, Int32) -> Void)?

    /// The menubar status button to anchor the dropdown beneath.
    var anchorButton: NSStatusBarButton?

    private var panel: KeyablePanel?
    private var searchField: NSSearchField!
    private var tableView: NSTableView!

    private static let panelWidth: CGFloat = 380
    private static let panelHeight: CGFloat = 420
    private static let fieldHeight: CGFloat = 28
    private static let pad: CGFloat = 8

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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Rounded visual-effect container.
        let container = NSVisualEffectView(frame: frame)
        container.material = .menu
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        panel.contentView = container

        // Search field.
        let field = NSSearchField(frame: NSRect(
            x: Self.pad,
            y: Self.panelHeight - Self.fieldHeight - Self.pad,
            width: Self.panelWidth - 2 * Self.pad,
            height: Self.fieldHeight
        ))
        field.placeholderString = "Search windows…"
        field.delegate = self
        field.focusRingType = .none
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        container.addSubview(field)
        self.searchField = field

        // Results table inside a scroll view.
        let scrollFrame = NSRect(
            x: Self.pad,
            y: Self.pad,
            width: Self.panelWidth - 2 * Self.pad,
            height: Self.panelHeight - Self.fieldHeight - 3 * Self.pad
        )
        let scroll = NSScrollView(frame: scrollFrame)
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let table = NSTableView(frame: scrollFrame)
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 22
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
        // Anchor under the menubar icon when we have one; otherwise centre
        // on the screen with the mouse / main screen.
        if let statusWindow = anchorButton?.window {
            let f = statusWindow.frame
            var x = f.midX - Self.panelWidth / 2
            let y = f.minY - Self.panelHeight - 2
            if let screen = statusWindow.screen ?? NSScreen.main {
                let vis = screen.visibleFrame
                x = min(max(x, vis.minX + 4), vis.maxX - Self.panelWidth - 4)
            }
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else if let screen = NSScreen.main {
            let vis = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: vis.midX - Self.panelWidth / 2,
                y: vis.midY - Self.panelHeight / 2
            ))
        }
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
                   objectValueFor tableColumn: NSTableColumn?,
                   row: Int) -> Any? {
        guard row >= 0, row < filtered.count else { return nil }
        return filtered[row].display
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
