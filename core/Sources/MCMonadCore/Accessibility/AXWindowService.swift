import AppKit
import ApplicationServices
import Foundation
import os

// MARK: - Private AX bridge

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(
    _ element: AXUIElement,
    _ windowId: inout CGWindowID
) -> AXError

// MARK: - AXWindowService

/// AXUIElement wrapper for window metadata reads and frame writes.
/// All operations are static, safe: errors are logged, never crash.
enum AXWindowService {
    private static let logger = Logger(
        subsystem: "com.mcmonad.core",
        category: "AXWindowService"
    )

    // MARK: - Window info

    /// Read metadata for a window identified by windowId + pid.
    /// Returns nil if the window or app is not accessible.
    static func info(windowId: UInt32, pid: pid_t) -> WindowInfo? {
        guard let axWindow = findAXWindow(windowId: windowId, pid: pid) else {
            logger.debug("AX window not found: wid=\(windowId) pid=\(pid)")
            return nil
        }

        let appElement = AXUIElementCreateApplication(pid)

        // Batch-fetch window attributes
        let attributeNames: [CFString] = [
            kAXRoleAttribute as CFString,
            kAXSubroleAttribute as CFString,
            kAXTitleAttribute as CFString,
            kAXCloseButtonAttribute as CFString,
            kAXFullScreenButtonAttribute as CFString,
            kAXPositionAttribute as CFString,
            kAXSizeAttribute as CFString,
            kAXZoomButtonAttribute as CFString,
        ]

        var valuesRef: CFArray?
        let batchResult = AXUIElementCopyMultipleAttributeValues(
            axWindow,
            attributeNames as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &valuesRef
        )

        guard batchResult == .success,
              let values = valuesRef as? [Any?],
              values.count >= 8
        else {
            logger.debug("Failed to batch-fetch AX attributes for wid=\(windowId)")
            return nil
        }

        func attr(_ index: Int) -> Any? {
            guard values.indices.contains(index) else { return nil }
            let v = values[index]
            if v is NSError { return nil }
            return v
        }

        func hasResolved(_ index: Int) -> Bool {
            attr(index) != nil
        }

        let role = attr(0) as? String
        let subrole = attr(1) as? String
        let title = attr(2) as? String

        let hasCloseButton = hasResolved(3)
        let hasFullscreenButton = hasResolved(4)

        // Read frame
        let frame: CGRect
        if let posRaw = attr(5), let sizeRaw = attr(6),
           CFGetTypeID(posRaw as CFTypeRef) == AXValueGetTypeID(),
           CFGetTypeID(sizeRaw as CFTypeRef) == AXValueGetTypeID()
        {
            let posValue = unsafeDowncast(posRaw as AnyObject, to: AXValue.self)
            let sizeValue = unsafeDowncast(sizeRaw as AnyObject, to: AXValue.self)
            var pos = CGPoint.zero
            var size = CGSize.zero
            if AXValueGetValue(posValue, .cgPoint, &pos),
               AXValueGetValue(sizeValue, .cgSize, &size)
            {
                frame = CGRect(origin: pos, size: size)
            } else {
                frame = .zero
            }
        } else {
            frame = .zero
        }

        // Determine if dialog
        let isDialog = subrole == "AXDialog"
            || (role == kAXWindowRole as String
                && subrole != kAXStandardWindowSubrole as String
                && !hasCloseButton)

        // Determine if fixed-size (no zoom button and not a standard window)
        let hasZoomButton = hasResolved(7)
        let isFixedSize = !hasZoomButton
            && subrole != (kAXStandardWindowSubrole as String)

        // App name and bundle ID
        var appName: String?
        var bundleId: String?

        var appTitleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            appElement,
            kAXTitleAttribute as CFString,
            &appTitleRef
        ) == .success {
            appName = appTitleRef as? String
        }

        if let runningApp = NSRunningApplication(processIdentifier: pid) {
            bundleId = runningApp.bundleIdentifier
            if appName == nil {
                appName = runningApp.localizedName
            }
        }

        return WindowInfo(
            windowId: windowId,
            pid: pid,
            title: title,
            appName: appName,
            bundleId: bundleId,
            subrole: subrole,
            isDialog: isDialog,
            isFixedSize: isFixedSize,
            hasCloseButton: hasCloseButton,
            hasFullscreenButton: hasFullscreenButton,
            frame: frame
        )
    }

    // MARK: - Set frame

    /// Write position and size to a window via AX.
    ///
    /// Write order follows OmniWM's heuristic:
    /// - If the window is **growing**, write position first then size
    ///   (avoids clipping against screen edge before the move).
    /// - If the window is **shrinking** (or unknown), write size first then position
    ///   (avoids temporary overlap before the shrink).
    ///
    /// The `currentHint` parameter is optional. When provided, it determines
    /// grow vs. shrink ordering. When nil, defaults to size-first (shrink order).
    @discardableResult
    static func setFrame(
        _ targetFrame: CGRect,
        windowId: UInt32,
        pid: pid_t,
        currentHint: CGRect? = nil
    ) -> Bool {
        guard targetFrame.width > 0,
              targetFrame.height > 0,
              targetFrame.origin.x.isFinite,
              targetFrame.origin.y.isFinite,
              targetFrame.width.isFinite,
              targetFrame.height.isFinite
        else {
            logger.warning(
                "Invalid target frame for wid=\(windowId): \(String(describing: targetFrame))"
            )
            return false
        }

        guard let axWindow = findAXWindow(windowId: windowId, pid: pid) else {
            logger.debug("AX window not found for setFrame: wid=\(windowId) pid=\(pid)")
            return false
        }

        var position = CGPoint(x: targetFrame.origin.x, y: targetFrame.origin.y)
        var size = CGSize(width: targetFrame.width, height: targetFrame.height)

        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size)
        else {
            logger.error("AXValueCreate failed for wid=\(windowId)")
            return false
        }

        let isGrowing: Bool
        if let hint = currentHint {
            isGrowing = targetFrame.width > hint.width + 0.5
                || targetFrame.height > hint.height + 0.5
        } else {
            isGrowing = false
        }

        let positionError: AXError
        let sizeError: AXError

        if isGrowing {
            positionError = AXUIElementSetAttributeValue(
                axWindow, kAXPositionAttribute as CFString, positionValue
            )
            sizeError = AXUIElementSetAttributeValue(
                axWindow, kAXSizeAttribute as CFString, sizeValue
            )
        } else {
            sizeError = AXUIElementSetAttributeValue(
                axWindow, kAXSizeAttribute as CFString, sizeValue
            )
            positionError = AXUIElementSetAttributeValue(
                axWindow, kAXPositionAttribute as CFString, positionValue
            )
        }

        if sizeError != .success {
            logger.debug("AX size write failed for wid=\(windowId): \(sizeError.rawValue)")
        }
        if positionError != .success {
            logger.debug("AX position write failed for wid=\(windowId): \(positionError.rawValue)")
        }

        return sizeError == .success && positionError == .success
    }

    // MARK: - Close window

    /// Press the close button on a window via AX.
    @discardableResult
    static func closeWindow(windowId: UInt32, pid: pid_t) -> Bool {
        guard let axWindow = findAXWindow(windowId: windowId, pid: pid) else {
            logger.debug("AX window not found for close: wid=\(windowId) pid=\(pid)")
            return false
        }

        var closeButtonRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            axWindow,
            kAXCloseButtonAttribute as CFString,
            &closeButtonRef
        )

        guard result == .success, let closeButtonRef else {
            logger.debug("No close button for wid=\(windowId)")
            return false
        }

        guard CFGetTypeID(closeButtonRef) == AXUIElementGetTypeID() else {
            logger.debug("Close button is not an AXUIElement for wid=\(windowId)")
            return false
        }

        let buttonElement = unsafeDowncast(
            closeButtonRef as AnyObject,
            to: AXUIElement.self
        )
        let pressResult = AXUIElementPerformAction(
            buttonElement,
            kAXPressAction as CFString
        )

        if pressResult != .success {
            logger.debug(
                "AXPress on close button failed for wid=\(windowId): \(pressResult.rawValue)"
            )
            return false
        }

        return true
    }

    // MARK: - Minimize / Show

    /// Set the minimized state of a window via AX.
    @discardableResult
    static func setMinimized(windowId: UInt32, minimized: Bool) -> Bool {
        // We need the PID to find the window. Look it up via SkyLight.
        guard let snapshot = SkyLightQuery.queryWindow(windowId) else {
            logger.debug("Cannot find window \(windowId) for minimize toggle")
            return false
        }

        guard let axWindow = Self.findAXWindow(windowId: windowId, pid: snapshot.pid) else {
            logger.debug("AX window not found for minimize: wid=\(windowId)")
            return false
        }

        let result = AXUIElementSetAttributeValue(
            axWindow,
            kAXMinimizedAttribute as CFString,
            minimized as CFBoolean
        )

        if result != .success {
            logger.debug("AX minimize write failed for wid=\(windowId): \(result.rawValue)")
            return false
        }

        return true
    }

    // MARK: - Read frame only

    /// Read frame from AX for a given window.
    static func readFrame(windowId: UInt32, pid: pid_t) -> CGRect? {
        guard let axWindow = findAXWindow(windowId: windowId, pid: pid) else {
            return nil
        }

        let attributes = [
            kAXPositionAttribute as CFString,
            kAXSizeAttribute as CFString,
        ] as CFArray

        var valuesPtr: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(
            axWindow,
            attributes,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &valuesPtr
        )

        guard result == .success,
              let values = valuesPtr as? [Any],
              values.count == 2
        else { return nil }

        let posRaw = values[0] as CFTypeRef
        let sizeRaw = values[1] as CFTypeRef

        guard CFGetTypeID(posRaw) == AXValueGetTypeID(),
              CFGetTypeID(sizeRaw) == AXValueGetTypeID()
        else { return nil }

        let posValue = unsafeDowncast(posRaw, to: AXValue.self)
        let sizeValue = unsafeDowncast(sizeRaw, to: AXValue.self)

        var pos = CGPoint.zero
        var size = CGSize.zero

        guard AXValueGetValue(posValue, .cgPoint, &pos),
              AXValueGetValue(sizeValue, .cgSize, &size)
        else { return nil }

        return CGRect(origin: pos, size: size)
    }

    // MARK: - Internal: find AX element for window

    private static func findAXWindow(
        windowId: UInt32,
        pid: pid_t
    ) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)

        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsRef
        )

        guard result == .success,
              let windows = windowsRef as? [AXUIElement]
        else {
            return nil
        }

        for window in windows {
            var winId: CGWindowID = 0
            if _AXUIElementGetWindow(window, &winId) == .success,
               winId == windowId
            {
                return window
            }
        }

        return nil
    }
}
