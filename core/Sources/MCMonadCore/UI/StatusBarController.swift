import AppKit

/// Menu bar status item for mcmonad-core.
/// Shows a template icon and provides a quit menu.
@MainActor
final class StatusBarController {
    private var statusItem: NSStatusItem?

    func setup() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            // Load template image from Resources directory
            let bundle = Bundle.main
            if let iconPath = bundle.path(forResource: "MenuBarIcon", ofType: "png"),
               let icon = NSImage(contentsOfFile: iconPath) {
                icon.isTemplate = true  // macOS handles light/dark mode
                icon.size = NSSize(width: 18, height: 18)
                button.image = icon
            } else {
                // Try loading from the executable's directory (for non-bundle runs)
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

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "mcmonad-core running", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(
            title: "Quit mcmonad-core",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        statusItem.menu = menu
        self.statusItem = statusItem
    }

    func updateWorkspace(_ tag: String) {
        statusItem?.button?.title = tag
    }
}
