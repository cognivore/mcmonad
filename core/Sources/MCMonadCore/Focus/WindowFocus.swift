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

    /// The window macOS currently considers focused: the frontmost
    /// application's AX focused window, mapped back to a CGWindowID via
    /// _AXUIElementGetWindow. Returns nil when it can't be resolved (no
    /// frontmost app, no focused window, or the element has no window id).
    /// Shared by the "jump to active window" query and the window-search
    /// panel's Esc-restores-focus path.
    static func frontmostFocusedWindow() -> (windowId: UInt32, pid: pid_t)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                appElement,
                kAXFocusedWindowAttribute as CFString,
                &focusedRef
              ) == .success,
              let focused = focusedRef,
              CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = unsafeDowncast(focused as AnyObject, to: AXUIElement.self)
        var wid: CGWindowID = 0
        guard _AXUIElementGetWindow(element, &wid) == .success else { return nil }
        return (UInt32(wid), pid)
    }

    static func focusWindow(pid: pid_t, windowId: UInt32) {
        let tHash = TitleHash.hash(windowId: windowId, pid: pid)

        // Step 1: Activate the application via NSRunningApplication
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
            FocusLog.emit(source: .cmdFocusActivate, windowId: windowId, pid: pid,
                          tHash: tHash, result: "ok")
        } else {
            FocusLog.emit(source: .cmdFocusActivate, windowId: windowId, pid: pid,
                          tHash: tHash, result: "no-running-app")
        }

        // Step 2: Set front process with private API
        var psn = ProcessSerialNumber()
        let psnStatus = getProcessForPID(pid, &psn)
        guard psnStatus == noErr else {
            FocusLog.emit(source: .cmdFocusSLPS, windowId: windowId, pid: pid,
                          tHash: tHash,
                          result: "getProcessForPID-failed", extra: "osStatus=\(psnStatus)")
            return
        }
        let slpsStatus = _SLPSSetFrontProcessWithOptions(&psn, windowId, kCPSUserGenerated)
        FocusLog.emit(source: .cmdFocusSLPS, windowId: windowId, pid: pid,
                      tHash: tHash,
                      result: slpsStatus == noErr ? "ok" : "err",
                      extra: "osStatus=\(slpsStatus)")

        // Step 3: Post synthetic key-window events
        makeKeyWindow(psn: &psn, windowId: windowId)
        FocusLog.emit(source: .cmdFocusKey, windowId: windowId, pid: pid,
                      tHash: tHash, result: "ok")

        // Step 4: Raise the window via Accessibility
        let raiseResult = raiseWindow(pid: pid, windowId: windowId)
        FocusLog.emit(source: .cmdFocusRaise, windowId: windowId, pid: pid,
                      tHash: tHash, result: raiseResult)
    }

    // MARK: - AXRaise

    /// Returns a short result tag for FocusLog: "ok", "ax-windows-failed",
    /// "wid-not-found-among-N", etc. Caller logs.
    private static func raiseWindow(pid: pid_t, windowId: UInt32) -> String {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsRef
        ) == .success,
        let windows = windowsRef as? [AXUIElement] else {
            return "ax-windows-failed"
        }

        for window in windows {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(window, &wid) == .success,
               wid == CGWindowID(windowId) {
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                return "ok"
            }
        }
        return "wid-not-found-among-\(windows.count)"
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
