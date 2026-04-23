import AppKit
@preconcurrency import ApplicationServices
import os

/// C-level callback for AXObserver — receives kAXFocusedWindowChangedNotification.
/// The `refcon` encodes the PID as a raw pointer value.
private func axFocusCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    let pid = pid_t(Int(bitPattern: refcon))

    // Extract CGWindowID from the focused window element
    var windowId: CGWindowID = 0
    // _AXUIElementGetWindow is a private API but available on all supported macOS versions
    guard _AXUIElementGetWindow(element, &windowId) == .success else { return }

    let wid = UInt32(windowId)
    Task { @MainActor in
        AXFocusTracker.shared?.handleFocusChange(windowId: wid, pid: pid)
    }
}

@MainActor
final class AXFocusTracker {
    static var shared: AXFocusTracker?

    private static let logger = Logger(
        subsystem: "com.mcmonad.core",
        category: "AXFocusTracker"
    )

    private var observers: [pid_t: AXObserver] = [:]
    var onFocusedWindowChanged: ((_ windowId: UInt32, _ pid: pid_t) -> Void)?

    func trackApp(pid: pid_t) {
        guard observers[pid] == nil else { return }
        var observer: AXObserver?
        guard AXObserverCreate(pid, axFocusCallback, &observer) == .success,
              let observer else { return }
        let appElement = AXUIElementCreateApplication(pid)
        let refcon = UnsafeMutableRawPointer(bitPattern: Int(pid))
        AXObserverAddNotification(
            observer, appElement,
            kAXFocusedWindowChangedNotification as CFString, refcon
        )
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )
        observers[pid] = observer
        Self.logger.debug("Tracking AX focus for pid \(pid)")
    }

    func untrackApp(pid: pid_t) {
        if let observer = observers.removeValue(forKey: pid) {
            // Remove from run loop before releasing
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
            Self.logger.debug("Stopped tracking AX focus for pid \(pid)")
        }
    }

    nonisolated func handleFocusChange(windowId: UInt32, pid: pid_t) {
        MainActor.assumeIsolated {
            onFocusedWindowChanged?(windowId, pid)
        }
    }
}
