import CoreGraphics
import Foundation
import os

// MARK: - Decoded event types

enum CGSWindowEvent: Equatable, Sendable {
    case created(windowId: UInt32, spaceId: UInt64)
    case destroyed(windowId: UInt32, spaceId: UInt64)
    case frameChanged(windowId: UInt32)
    case closed(windowId: UInt32)
    case frontAppChanged(pid: pid_t)
    case titleChanged(windowId: UInt32)
}

// MARK: - Delegate protocol

@MainActor
protocol SkyLightEventDelegate: AnyObject {
    func skyLightEventObserver(
        _ observer: SkyLightEventObserver,
        didReceive event: CGSWindowEvent
    )
}

// MARK: - Observer

@MainActor
final class SkyLightEventObserver {
    static let shared = SkyLightEventObserver()

    private static let logger = Logger(
        subsystem: "com.mcmonad.core",
        category: "SkyLightEventObserver"
    )

    weak var delegate: SkyLightEventDelegate?

    private var isRegistered = false
    private var isWindowClosedNotifyRegistered = false

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !isRegistered else { return }
        guard let skyLight = SkyLight.shared else {
            Self.logger.error("Cannot start event observer: SkyLight not available")
            return
        }

        let eventsViaConnectionNotify: [CGSEventType] = [
            .spaceWindowCreated,
            .spaceWindowDestroyed,
            .windowMoved,
            .windowResized,
            .windowTitleChanged,
            .frontmostApplicationChanged,
        ]

        var successCount = 0
        for event in eventsViaConnectionNotify {
            if skyLight.registerForNotification(
                event: event,
                callback: skyLightConnectionCallback,
                context: nil
            ) {
                successCount += 1
            }
        }

        // windowClosed uses the per-window RegisterNotifyProc path
        if isWindowClosedNotifyRegistered {
            successCount += 1
        } else {
            let cid = skyLight.getMainConnectionID()
            let cidContext = UnsafeMutableRawPointer(bitPattern: Int(cid))
            if skyLight.registerNotifyProc(
                event: .windowClosed,
                callback: skyLightNotifyCallback,
                context: cidContext
            ) {
                successCount += 1
                isWindowClosedNotifyRegistered = true
            }
        }

        isRegistered = successCount > 0
        updateCallbackRegistrationState(isRegistered)

        if isRegistered {
            Self.logger.info("Event observer started with \(successCount) registrations")
        } else {
            Self.logger.error("Event observer failed to register any callbacks")
        }
    }

    func stop() {
        guard let skyLight = SkyLight.shared else { return }

        if isRegistered {
            let eventsToUnregister: [CGSEventType] = [
                .spaceWindowCreated,
                .spaceWindowDestroyed,
                .windowMoved,
                .windowResized,
                .windowTitleChanged,
                .frontmostApplicationChanged,
            ]

            for event in eventsToUnregister {
                _ = skyLight.unregisterForNotification(
                    event: event,
                    callback: skyLightConnectionCallback
                )
            }

            isRegistered = false
        }

        if isWindowClosedNotifyRegistered {
            let cid = skyLight.getMainConnectionID()
            let cidContext = UnsafeMutableRawPointer(bitPattern: Int(cid))
            if skyLight.unregisterNotifyProc(
                event: .windowClosed,
                callback: skyLightNotifyCallback,
                context: cidContext
            ) {
                isWindowClosedNotifyRegistered = false
            }
        }

        updateCallbackRegistrationState(false)
        Self.logger.info("Event observer stopped")
    }

    // MARK: - Per-window subscription

    @discardableResult
    func subscribeToWindows(_ windowIds: [UInt32]) -> Bool {
        guard let skyLight = SkyLight.shared else { return false }
        return skyLight.subscribeToWindowNotifications(windowIds)
    }

    // MARK: - Drain

    fileprivate func drainPendingEventsOnMainRunLoop() {
        let pendingDrain = skyLightPendingEvents.withLock { state -> [CGSWindowEvent] in
            let events = state.orderedEvents
            state.orderedEvents.removeAll(keepingCapacity: true)
            state.pendingFrameWindowIds.removeAll(keepingCapacity: true)
            state.drainScheduled = false
            return events
        }

        guard isRegistered else { return }

        for event in pendingDrain {
            delegate?.skyLightEventObserver(self, didReceive: event)
        }
    }

    private func updateCallbackRegistrationState(_ registered: Bool) {
        if registered {
            skyLightPendingEvents.withLock { $0.isRegistered = true }
        } else {
            skyLightPendingEvents.withLock { state in
                state.isRegistered = false
                state.drainScheduled = false
                state.orderedEvents.removeAll(keepingCapacity: false)
                state.pendingFrameWindowIds.removeAll(keepingCapacity: false)
            }
        }
    }
}

// MARK: - Lock-protected pending event state

private struct PendingEventState: Sendable {
    var isRegistered = false
    var drainScheduled = false
    var orderedEvents: [CGSWindowEvent] = []
    var pendingFrameWindowIds: Set<UInt32> = []
}

private let skyLightPendingEvents = OSAllocatedUnfairLock(
    initialState: PendingEventState()
)

// MARK: - Event scheduling (called from arbitrary threads)

private func scheduleDrain() {
    let mainRunLoop = CFRunLoopGetMain()
    CFRunLoopPerformBlock(mainRunLoop, CFRunLoopMode.commonModes.rawValue) {
        MainActor.assumeIsolated {
            SkyLightEventObserver.shared.drainPendingEventsOnMainRunLoop()
        }
    }
    CFRunLoopWakeUp(mainRunLoop)
}

private func enqueueEvent(_ event: CGSWindowEvent) {
    let shouldSchedule = skyLightPendingEvents.withLock { state -> Bool in
        guard state.isRegistered else { return false }

        switch event {
        case let .frameChanged(windowId):
            // Coalesce: only keep one frameChanged per windowId in the buffer
            if state.pendingFrameWindowIds.insert(windowId).inserted {
                state.orderedEvents.append(event)
            }

        case let .destroyed(windowId, _):
            clearPendingFrame(windowId: windowId, state: &state)
            state.orderedEvents.append(event)

        case let .closed(windowId):
            clearPendingFrame(windowId: windowId, state: &state)
            state.orderedEvents.append(event)

        case .created, .frontAppChanged, .titleChanged:
            state.orderedEvents.append(event)
        }

        guard !state.drainScheduled else { return false }
        state.drainScheduled = true
        return true
    }

    if shouldSchedule {
        scheduleDrain()
    }
}

private func clearPendingFrame(
    windowId: UInt32,
    state: inout PendingEventState
) {
    guard state.pendingFrameWindowIds.remove(windowId) != nil else { return }
    state.orderedEvents.removeAll { event in
        if case let .frameChanged(pendingId) = event {
            return pendingId == windowId
        }
        return false
    }
}

// MARK: - Raw event decoding

private enum DecodedEvent {
    case ignored
    case malformed
    case event(CGSWindowEvent)
}

private func decodeRawEvent(
    eventType: UInt32,
    data: UnsafeMutableRawPointer?,
    length: Int
) -> DecodedEvent {
    guard let cgsEvent = CGSEventType(rawValue: eventType) else {
        return .ignored
    }

    switch cgsEvent {
    case .spaceWindowCreated:
        guard let spaceId = readUInt64(from: data, length: length, offset: 0),
              let windowId = readUInt32(from: data, length: length, offset: 8)
        else { return .malformed }
        return .event(.created(windowId: windowId, spaceId: spaceId))

    case .spaceWindowDestroyed:
        guard let spaceId = readUInt64(from: data, length: length, offset: 0),
              let windowId = readUInt32(from: data, length: length, offset: 8)
        else { return .malformed }
        return .event(.destroyed(windowId: windowId, spaceId: spaceId))

    case .windowClosed:
        guard let windowId = readUInt32(from: data, length: length, offset: 0)
        else { return .malformed }
        return .event(.closed(windowId: windowId))

    case .windowMoved, .windowResized:
        guard let windowId = readUInt32(from: data, length: length, offset: 0)
        else { return .malformed }
        return .event(.frameChanged(windowId: windowId))

    case .frontmostApplicationChanged:
        guard let pid = readInt32(from: data, length: length, offset: 0)
        else { return .malformed }
        return .event(.frontAppChanged(pid: pid))

    case .windowTitleChanged:
        guard let windowId = readUInt32(from: data, length: length, offset: 0)
        else { return .malformed }
        return .event(.titleChanged(windowId: windowId))

    default:
        return .ignored
    }
}

private func handleRawEvent(
    eventType: UInt32,
    data: UnsafeMutableRawPointer?,
    length: Int
) {
    switch decodeRawEvent(eventType: eventType, data: data, length: length) {
    case .ignored:
        return
    case .malformed:
        return
    case let .event(event):
        enqueueEvent(event)
    }
}

// MARK: - Safe memory reads

private func readUInt32(
    from data: UnsafeMutableRawPointer?,
    length: Int,
    offset: Int
) -> UInt32? {
    guard let data else { return nil }
    let size = MemoryLayout<UInt32>.size
    guard length >= offset + size else { return nil }
    var value: UInt32 = 0
    withUnsafeMutableBytes(of: &value) { dest in
        dest.copyBytes(
            from: UnsafeRawBufferPointer(
                start: UnsafeRawPointer(data).advanced(by: offset),
                count: size
            )
        )
    }
    return value
}

private func readUInt64(
    from data: UnsafeMutableRawPointer?,
    length: Int,
    offset: Int
) -> UInt64? {
    guard let data else { return nil }
    let size = MemoryLayout<UInt64>.size
    guard length >= offset + size else { return nil }
    var value: UInt64 = 0
    withUnsafeMutableBytes(of: &value) { dest in
        dest.copyBytes(
            from: UnsafeRawBufferPointer(
                start: UnsafeRawPointer(data).advanced(by: offset),
                count: size
            )
        )
    }
    return value
}

private func readInt32(
    from data: UnsafeMutableRawPointer?,
    length: Int,
    offset: Int
) -> Int32? {
    guard let data else { return nil }
    let size = MemoryLayout<Int32>.size
    guard length >= offset + size else { return nil }
    var value: Int32 = 0
    withUnsafeMutableBytes(of: &value) { dest in
        dest.copyBytes(
            from: UnsafeRawBufferPointer(
                start: UnsafeRawPointer(data).advanced(by: offset),
                count: size
            )
        )
    }
    return value
}

// MARK: - C callbacks (free functions, called on arbitrary threads)

private func skyLightConnectionCallback(
    event: UInt32,
    data: UnsafeMutableRawPointer?,
    length: Int,
    context _: UnsafeMutableRawPointer?,
    cid _: Int32
) {
    handleRawEvent(eventType: event, data: data, length: length)
}

private func skyLightNotifyCallback(
    event: UInt32,
    data: UnsafeMutableRawPointer?,
    length: Int,
    cid _: Int32
) {
    handleRawEvent(eventType: event, data: data, length: length)
}
