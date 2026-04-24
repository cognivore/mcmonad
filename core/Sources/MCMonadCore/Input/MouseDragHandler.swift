import AppKit
import CoreGraphics
import os

/// Handles Option+LMB drag (move) and Option+RMB drag (resize) for windows.
///
/// Move: Option+LMB down on a window, drag to reposition.
/// Resize: Option+RMB down on a window, drag to resize. The corner closest
///   to the cursor becomes the "grabbed" corner; the opposite corner stays
///   fixed as the anchor.
///
/// All position/size updates happen directly via AX (zero latency — no IPC
/// round-trip during the drag). When the drag ends, a `windowDragCompleted`
/// event is sent to Haskell so it can update floating state.
///
/// The CGEventTap callback runs on the main run loop thread synchronously.
/// We use `nonisolated(unsafe)` for mutable state since CGEventTap callbacks
/// are guaranteed to be serialized on the run loop they're added to.
final class MouseDragHandler: @unchecked Sendable {

    private static let logger = Logger(subsystem: "com.mcmonad.core", category: "MouseDrag")
    private static let minSize: CGFloat = 100

    // MARK: - Drag state

    private enum DragMode {
        case none
        case move(state: DragState)
        case resize(state: DragState, corner: ResizeCorner)
    }

    private struct DragState {
        let windowId: UInt32
        let pid: Int32
        let initialMousePos: CGPoint
        let initialFrame: CGRect
    }

    private enum ResizeCorner {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    nonisolated(unsafe) private var mode: DragMode = .none
    nonisolated(unsafe) var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Called when a drag completes. Swift sends this to Haskell.
    nonisolated(unsafe) var onDragCompleted: ((_ windowId: UInt32, _ pid: Int32, _ frame: CGRect) -> Void)?

    // MARK: - Lifecycle

    func start() {
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDragged.rawValue)
            | (1 << CGEventType.rightMouseUp.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,       // active: can consume events
            eventsOfInterest: mask,
            callback: mouseDragCallback,
            userInfo: selfPtr
        ) else {
            Self.logger.error("Failed to create CGEventTap for mouse drag")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Self.logger.info("Mouse drag handler started")
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

    // MARK: - Event handling (called from C callback on main run loop thread)

    func handleEvent(
        type: CGEventType, event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        let flags = event.flags

        switch type {
        // --- Mouse down with Option: start drag ---
        case .leftMouseDown where flags.contains(.maskAlternate):
            return startMove(event: event)
        case .rightMouseDown where flags.contains(.maskAlternate):
            return startResize(event: event)

        // --- Dragging ---
        case .leftMouseDragged:
            if case .move = mode { return handleDrag(event: event) }
        case .rightMouseDragged:
            if case .resize = mode { return handleDrag(event: event) }

        // --- Mouse up: end drag ---
        case .leftMouseUp:
            if case .move = mode { return endDrag(event: event) }
        case .rightMouseUp:
            if case .resize = mode { return endDrag(event: event) }

        default:
            break
        }

        // Not our event — pass through
        return Unmanaged.passUnretained(event)
    }

    // MARK: - Start move

    private func startMove(event: CGEvent) -> Unmanaged<CGEvent>? {
        let mousePos = event.location

        guard let (windowId, pid, frame) = findWindowAndFrame(at: mousePos) else {
            return Unmanaged.passUnretained(event)
        }

        Self.logger.debug("Start move: wid=\(windowId) at \(mousePos.x),\(mousePos.y)")
        mode = .move(state: DragState(
            windowId: windowId, pid: pid,
            initialMousePos: mousePos, initialFrame: frame
        ))
        return nil  // consume event
    }

    // MARK: - Start resize (with corner detection)

    private func startResize(event: CGEvent) -> Unmanaged<CGEvent>? {
        let mousePos = event.location

        guard let (windowId, pid, frame) = findWindowAndFrame(at: mousePos) else {
            return Unmanaged.passUnretained(event)
        }

        // Determine which corner is closest to the mouse cursor.
        // The opposite corner becomes the fixed anchor.
        let centerX = frame.origin.x + frame.size.width / 2
        let centerY = frame.origin.y + frame.size.height / 2
        let corner: ResizeCorner
        if mousePos.x < centerX {
            corner = mousePos.y < centerY ? .topLeft : .bottomLeft
        } else {
            corner = mousePos.y < centerY ? .topRight : .bottomRight
        }

        Self.logger.debug(
            "Start resize: wid=\(windowId) corner=\(String(describing: corner)) at \(mousePos.x),\(mousePos.y)"
        )
        mode = .resize(
            state: DragState(
                windowId: windowId, pid: pid,
                initialMousePos: mousePos, initialFrame: frame
            ),
            corner: corner
        )
        return nil  // consume event
    }

    // MARK: - Handle drag

    private func handleDrag(event: CGEvent) -> Unmanaged<CGEvent>? {
        let mousePos = event.location

        switch mode {
        case .move(let state):
            let dx = mousePos.x - state.initialMousePos.x
            let dy = mousePos.y - state.initialMousePos.y
            let newFrame = CGRect(
                x: state.initialFrame.origin.x + dx,
                y: state.initialFrame.origin.y + dy,
                width: state.initialFrame.width,
                height: state.initialFrame.height
            )
            AXWindowService.setFrame(newFrame, windowId: state.windowId, pid: state.pid,
                                     currentHint: state.initialFrame)

        case .resize(let state, let corner):
            let dx = mousePos.x - state.initialMousePos.x
            let dy = mousePos.y - state.initialMousePos.y
            let f = state.initialFrame
            let newFrame: CGRect

            switch corner {
            // Grabbing top-left: anchor is bottom-right
            case .topLeft:
                newFrame = CGRect(
                    x: f.origin.x + dx,
                    y: f.origin.y + dy,
                    width: max(Self.minSize, f.width - dx),
                    height: max(Self.minSize, f.height - dy)
                )
            // Grabbing top-right: anchor is bottom-left
            case .topRight:
                newFrame = CGRect(
                    x: f.origin.x,
                    y: f.origin.y + dy,
                    width: max(Self.minSize, f.width + dx),
                    height: max(Self.minSize, f.height - dy)
                )
            // Grabbing bottom-left: anchor is top-right
            case .bottomLeft:
                newFrame = CGRect(
                    x: f.origin.x + dx,
                    y: f.origin.y,
                    width: max(Self.minSize, f.width - dx),
                    height: max(Self.minSize, f.height + dy)
                )
            // Grabbing bottom-right: anchor is top-left
            case .bottomRight:
                newFrame = CGRect(
                    x: f.origin.x,
                    y: f.origin.y,
                    width: max(Self.minSize, f.width + dx),
                    height: max(Self.minSize, f.height + dy)
                )
            }

            AXWindowService.setFrame(newFrame, windowId: state.windowId, pid: state.pid,
                                     currentHint: state.initialFrame)

        case .none:
            break
        }

        return nil  // consume drag events during our drag
    }

    // MARK: - End drag

    private func endDrag(event: CGEvent) -> Unmanaged<CGEvent>? {
        switch mode {
        case .move(let state), .resize(let state, _):
            // Read the final frame from AX (may differ from what we set due to
            // window constraints, min size, screen edges, etc.)
            if let finalFrame = AXWindowService.readFrame(windowId: state.windowId, pid: state.pid) {
                Self.logger.debug(
                    "Drag completed: wid=\(state.windowId) final=\(finalFrame.origin.x),\(finalFrame.origin.y) \(finalFrame.width)x\(finalFrame.height)"
                )
                onDragCompleted?(state.windowId, state.pid, finalFrame)
            }
        case .none:
            break
        }

        mode = .none
        return nil  // consume the mouse-up too
    }

    // MARK: - Window lookup

    /// Find the window at a screen point and read its current frame via AX.
    private func findWindowAndFrame(at point: CGPoint) -> (UInt32, Int32, CGRect)? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        let myPid = ProcessInfo.processInfo.processIdentifier

        for windowInfo in windowList {
            guard let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
                  let windowId = windowInfo[kCGWindowNumber as String] as? UInt32,
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
                // Read actual frame from AX for accuracy
                if let frame = AXWindowService.readFrame(windowId: windowId, pid: ownerPID) {
                    return (windowId, ownerPID, frame)
                }
                // Fallback to CG bounds if AX fails
                return (windowId, ownerPID, bounds)
            }
        }
        return nil
    }
}

// MARK: - C callback

private func mouseDragCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }

    // CGEventTap disabled by system? Re-enable it.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        let handler = Unmanaged<MouseDragHandler>.fromOpaque(userInfo).takeUnretainedValue()
        if let tap = handler.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    let handler = Unmanaged<MouseDragHandler>.fromOpaque(userInfo).takeUnretainedValue()
    return handler.handleEvent(type: type, event: event)
}
