import AppKit
import os

/// The mcmonad-core menubar item.
///
/// Displays:
///   - A template icon (or workspace tag, set via setWorkspaceIndicator)
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

    /// Fires when the user clicks the "Debug frame overlays" item.
    /// The main module wires this to send `menuToggleDebug` to Haskell.
    var onToggleDebugOverlays: (() -> Void)?

    /// Fires when the user clicks a window entry inside a workspace
    /// submenu. The main module wires this to send `menuFocusWindow`.
    var onFocusWindow: ((UInt32, Int32) -> Void)?

    /// Fires when the user clicks a workspace row. The main module
    /// wires this to send `menuViewWorkspace`.
    var onViewWorkspace: ((String) -> Void)?

    func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let bundle = Bundle.main
            if let iconPath = bundle.path(forResource: "MenuBarIcon", ofType: "png"),
               let icon = NSImage(contentsOfFile: iconPath) {
                icon.isTemplate = true
                icon.size = NSSize(width: 18, height: 18)
                button.image = icon
            } else {
                let execDir = ProcessInfo.processInfo.arguments[0]
                let resourceDir = (execDir as NSString)
                    .deletingLastPathComponent + "/../Resources"
                if let icon = NSImage(contentsOfFile: resourceDir + "/MenuBarIcon.png") {
                    icon.isTemplate = true
                    icon.size = NSSize(width: 18, height: 18)
                    button.image = icon
                } else {
                    button.title = "MC"
                }
            }
        }
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        self.statusItem = item
    }

    /// Set the leading workspace indicator next to the icon.
    /// Mirrors the prior contract used by Haskell's
    /// `SetWorkspaceIndicator` command.
    func updateWorkspace(_ tag: String) {
        statusItem?.button?.title = tag
    }

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
        addDebugToggle(to: menu, currentlyOn: snap.debugOverlays)
        addFooter(to: menu)
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

    @objc private func toggleDebugClicked(_ sender: Any?) {
        onToggleDebugOverlays?()
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
