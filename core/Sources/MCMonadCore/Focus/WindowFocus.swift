import AppKit
import ApplicationServices
import Foundation
import os

// Private API declarations via @_silgen_name (same approach as OmniWM)
@_silgen_name("GetProcessForPID")
private func getProcessForPID(_ pid: pid_t, _ psn: inout ProcessSerialNumber) -> OSStatus

@_silgen_name("_SLPSSetFrontProcessWithOptions")
private func _SLPSSetFrontProcessWithOptions(
    _ psn: inout ProcessSerialNumber,
    _ wid: UInt32,
    _ mode: UInt32
) -> OSStatus

@_silgen_name("SLPSPostEventRecordTo")
private func SLPSPostEventRecordTo(
    _ psn: inout ProcessSerialNumber,
    _ bytes: UnsafeMutablePointer<UInt8>
) -> OSStatus

// _AXUIElementGetWindow is declared in AXWindowService.swift

/// kCPSUserGenerated mode flag
private let kCPSUserGenerated: UInt32 = 0x200

// MARK: - WindowFocus

enum WindowFocus {
    static func focus(windowId: UInt32, pid: pid_t) {
        focusWindow(pid: pid, windowId: windowId)
    }

    static func focusWindow(pid: pid_t, windowId: UInt32) {
        // Step 1: Activate the application via NSRunningApplication
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        }

        // Step 2: Set front process with private API
        var psn = ProcessSerialNumber()
        guard getProcessForPID(pid, &psn) == noErr else { return }
        _ = _SLPSSetFrontProcessWithOptions(&psn, windowId, kCPSUserGenerated)

        // Step 3: Post synthetic key-window events
        makeKeyWindow(psn: &psn, windowId: windowId)

        // Step 4: Raise the window via Accessibility
        raiseWindow(pid: pid, windowId: windowId)
    }

    // MARK: - AXRaise

    private static func raiseWindow(pid: pid_t, windowId: UInt32) {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsRef
        ) == .success,
        let windows = windowsRef as? [AXUIElement] else {
            return
        }

        for window in windows {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(window, &wid) == .success,
               wid == CGWindowID(windowId) {
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                return
            }
        }
    }

    // MARK: - Synthetic key-window events

    private static func makeKeyWindow(
        psn: inout ProcessSerialNumber,
        windowId: UInt32
    ) {
        var eventBytes = [UInt8](repeating: 0, count: 0xF8)

        eventBytes[0x04] = 0xF8

        for i in 0x20 ..< 0x30 {
            eventBytes[i] = 0xFF
        }

        eventBytes[0x3A] = 0x10

        withUnsafeBytes(of: windowId) { ptr in
            eventBytes[0x3C] = ptr[0]
            eventBytes[0x3D] = ptr[1]
            eventBytes[0x3E] = ptr[2]
            eventBytes[0x3F] = ptr[3]
        }

        eventBytes[0x08] = 0x01
        _ = SLPSPostEventRecordTo(&psn, &eventBytes)

        eventBytes[0x08] = 0x02
        _ = SLPSPostEventRecordTo(&psn, &eventBytes)
    }
}
