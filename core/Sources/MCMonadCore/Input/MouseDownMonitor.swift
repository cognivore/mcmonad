import AppKit
import CoreGraphics
import Foundation
import os

/// Detects every global mouse-down (left, right, other) and surfaces it
/// to mcmonad's IPC layer so the Haskell side has a first-class
/// "user-initiated input" signal.
///
/// Why this exists: 'FocusIntent' in 'MCMonad.Core' treats macOS' AX +
/// NSWorkspace events as untrustworthy while mcmonad has a pending focus
/// command — the same bounce echo that fires after our own
/// 'FocusWindow' command is indistinguishable at the AX layer from a
/// user-initiated focus change (e.g. clicking a window in another app).
/// One layer up, however, the difference is obvious: a physical mouse
/// click happened, or it didn't. We tap mouse-down events globally and
/// forward an event to Haskell; the handler clears 'focusIntent' on
/// receipt so the very next AX/NSWorkspace event flows through to
/// 'resolveFocusedWindow' / 'resolveFrontApp' instead of being treated
/// as a bounce.
///
/// We use 'listenOnly' so clicks pass through to applications unmodified.
/// CGEventTap requires accessibility permission, which mcmonad-core
/// already requires at boot.
@MainActor
final class MouseDownMonitor {
    private static let logger = Logger(
        subsystem: "com.mcmonad.core",
        category: "MouseDownMonitor"
    )

    /// Fired on every global mouse-down. Called on the main run loop.
    var onUserMouseDown: (@MainActor () -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func start() {
        let eventMask: CGEventMask =
              (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: mouseDownCallback,
            userInfo: selfPtr
        ) else {
            Self.logger.error("Failed to create CGEventTap for mouse-down monitor")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Self.logger.info("Mouse-down monitor started")
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

    fileprivate func handleMouseDown() {
        onUserMouseDown?()
    }
}

// C callback — must be outside the class
private func mouseDownCallback(
    proxy _: CGEventTapProxy,
    type _: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passRetained(event) }
    let monitor = Unmanaged<MouseDownMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    DispatchQueue.main.async { @MainActor in
        monitor.handleMouseDown()
    }
    return Unmanaged.passRetained(event)
}
