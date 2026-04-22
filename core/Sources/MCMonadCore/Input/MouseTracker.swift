import AppKit
import CoreGraphics
import Foundation

/// Tracks mouse position and detects when the cursor enters a different window.
/// Uses a CGEventTap on mouse-moved events with debouncing and menu suppression.
@MainActor
final class MouseTracker {
    var onWindowEntered: (@MainActor (_ windowId: UInt32, _ pid: Int32) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastWindowId: UInt32 = 0
    private var lastFocusTime: CFAbsoluteTime = 0
    private let debounceInterval: CFAbsoluteTime = 0.1  // 100ms, same as OmniWM

    func start() {
        let eventMask: CGEventMask = (1 << CGEventType.mouseMoved.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: mouseMovedCallback,
            userInfo: selfPtr
        ) else {
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    fileprivate func handleMouseMoved() {
        // Debounce: 100ms minimum between focus changes
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastFocusTime >= debounceInterval else { return }

        // Don't change focus while any mouse button is held (menus, dragging)
        guard NSEvent.pressedMouseButtons == 0 else { return }

        // Don't change focus while a menu is open
        // NSApp.mainMenu?.highlightedItem != nil catches menu bar menus
        // But context menus are trickier. Check if any menu-level window exists
        // by looking for windows at non-zero layers that appeared recently.
        if isMenuVisible() { return }

        let mouseLocation = NSEvent.mouseLocation
        guard let mainScreen = NSScreen.main else { return }
        let flippedY = mainScreen.frame.height - mouseLocation.y
        let point = CGPoint(x: mouseLocation.x, y: flippedY)

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return }

        let myPid = ProcessInfo.processInfo.processIdentifier

        for windowInfo in windowList {
            guard let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
                  let windowNumber = windowInfo[kCGWindowNumber as String] as? UInt32,
                  let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? Int32,
                  let layer = windowInfo[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  ownerPID != myPid
            else { continue }

            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )

            if bounds.contains(point) {
                if windowNumber != lastWindowId {
                    lastWindowId = windowNumber
                    lastFocusTime = now
                    onWindowEntered?(windowNumber, ownerPID)
                }
                return
            }
        }
    }

    /// Check if any popup menu or context menu is visible.
    /// Menu windows live at layer 101 (NSPopUpMenuWindowLevel).
    private func isMenuVisible() -> Bool {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        for windowInfo in windowList {
            guard let layer = windowInfo[kCGWindowLayer as String] as? Int else { continue }
            // Menu windows: layer 101 (popups), 24 (main menu bar items)
            if layer == 101 || layer == 24 {
                return true
            }
        }
        return false
    }
}

// C callback — must be outside the class
private func mouseMovedCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passRetained(event) }
    let tracker = Unmanaged<MouseTracker>.fromOpaque(userInfo).takeUnretainedValue()
    DispatchQueue.main.async { @MainActor in
        tracker.handleMouseMoved()
    }
    return Unmanaged.passRetained(event)
}
