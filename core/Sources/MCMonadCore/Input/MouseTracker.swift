import CoreGraphics
import Foundation

/// Tracks mouse position and detects when the cursor enters a different window.
/// Uses a CGEventTap on mouse-moved events.
@MainActor
final class MouseTracker {
    var onWindowEntered: (@MainActor (_ windowId: UInt32, _ pid: Int32) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastWindowId: UInt32 = 0

    func start() {
        let eventMask: CGEventMask = (1 << CGEventType.mouseMoved.rawValue)

        // Store self in a pointer for the C callback
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,  // passive — don't block or modify events
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

    /// Called from the C callback on the main thread.
    fileprivate func handleMouseMoved() {
        let mouseLocation = NSEvent.mouseLocation
        // NSEvent.mouseLocation is in screen coords (origin bottom-left),
        // but CGWindowListCopyWindowInfo uses top-left origin.
        // Convert: flip Y using main screen height.
        guard let mainScreen = NSScreen.main else { return }
        let flippedY = mainScreen.frame.height - mouseLocation.y
        let point = CGPoint(x: mouseLocation.x, y: flippedY)

        // Find which window is under the cursor
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return }

        for windowInfo in windowList {
            guard let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
                  let windowNumber = windowInfo[kCGWindowNumber as String] as? UInt32,
                  let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? Int32,
                  let layer = windowInfo[kCGWindowLayer as String] as? Int,
                  layer == 0  // normal windows only
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
                    onWindowEntered?(windowNumber, ownerPID)
                }
                return
            }
        }
    }
}

// Needs to be outside the class for @convention(c)
import AppKit

private nonisolated(unsafe) var mouseMovedCounter: UInt64 = 0

private func mouseMovedCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passRetained(event) }

    // Debounce: only process every Nth event to avoid flooding
    mouseMovedCounter &+= 1
    guard mouseMovedCounter % 3 == 0 else { return Unmanaged.passRetained(event) }

    let tracker = Unmanaged<MouseTracker>.fromOpaque(userInfo).takeUnretainedValue()
    DispatchQueue.main.async { @MainActor in
        tracker.handleMouseMoved()
    }

    return Unmanaged.passRetained(event)
}
