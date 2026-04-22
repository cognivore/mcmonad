import CoreGraphics
import Foundation
import os

// MARK: - Window ordering constants

enum SkyLightWindowOrder: Int32, Sendable {
    case above = 0
    case below = -1
}

// MARK: - SkyLight event type enum

enum CGSEventType: UInt32, Sendable {
    case windowClosed = 804
    case windowMoved = 806
    case windowResized = 807
    case windowTitleChanged = 1322
    case spaceWindowCreated = 1325
    case spaceWindowDestroyed = 1326
    case frontmostApplicationChanged = 1508
    case all = 0xFFFF_FFFF
}

// MARK: - Window server snapshot

struct WindowSnapshot: Equatable, Sendable {
    let windowId: UInt32
    let pid: pid_t
    let frame: CGRect
    let level: Int32
    let tags: UInt64
    let attributes: UInt32
    let parentId: UInt32
}

// MARK: - SkyLight private framework bindings

/// Loads SkyLight private framework symbols via dlopen/dlsym.
/// Returns `nil` from `init` if critical symbols cannot be resolved.
/// All function pointers are `@convention(c)`.
final class SkyLight: @unchecked Sendable {
    static let shared: SkyLight? = SkyLight()

    private static let logger = Logger(
        subsystem: "com.mcmonad.core",
        category: "SkyLight"
    )

    // MARK: - Function pointer typedefs

    private typealias MainConnectionIDFunc = @convention(c) () -> Int32
    private typealias WindowQueryWindowsFunc = @convention(c) (Int32, CFArray, UInt32) -> CFTypeRef?
    private typealias WindowQueryResultCopyWindowsFunc = @convention(c) (CFTypeRef) -> CFTypeRef?
    private typealias WindowIteratorGetCountFunc = @convention(c) (CFTypeRef) -> Int32
    private typealias WindowIteratorAdvanceFunc = @convention(c) (CFTypeRef) -> Bool
    private typealias WindowIteratorGetBoundsFunc = @convention(c) (CFTypeRef) -> CGRect
    private typealias WindowIteratorGetWindowIDFunc = @convention(c) (CFTypeRef) -> UInt32
    private typealias WindowIteratorGetPIDFunc = @convention(c) (CFTypeRef) -> Int32
    private typealias WindowIteratorGetLevelFunc = @convention(c) (CFTypeRef) -> Int32
    private typealias WindowIteratorGetTagsFunc = @convention(c) (CFTypeRef) -> UInt64
    private typealias WindowIteratorGetAttributesFunc = @convention(c) (CFTypeRef) -> UInt32
    private typealias WindowIteratorGetParentIDFunc = @convention(c) (CFTypeRef) -> UInt32
    private typealias TransactionCreateFunc = @convention(c) (Int32) -> CFTypeRef?
    private typealias TransactionCommitFunc = @convention(c) (CFTypeRef, Int32) -> CGError
    private typealias TransactionOrderWindowFunc = @convention(c) (CFTypeRef, UInt32, Int32, UInt32) -> Void
    private typealias TransactionMoveWindowWithGroupFunc = @convention(c) (CFTypeRef, UInt32, CGPoint) -> CGError
    private typealias DisableUpdateFunc = @convention(c) (Int32) -> Void
    private typealias ReenableUpdateFunc = @convention(c) (Int32) -> Void
    private typealias MoveWindowFunc = @convention(c) (Int32, UInt32, UnsafePointer<CGPoint>) -> CGError
    private typealias GetWindowBoundsFunc = @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> CGError

    typealias ConnectionNotifyCallback = @convention(c) (
        UInt32,
        UnsafeMutableRawPointer?,
        Int,
        UnsafeMutableRawPointer?,
        Int32
    ) -> Void

    private typealias RegisterConnectionNotifyProcFunc = @convention(c) (
        Int32,
        ConnectionNotifyCallback,
        UInt32,
        UnsafeMutableRawPointer?
    ) -> Int32

    private typealias UnregisterConnectionNotifyProcFunc = @convention(c) (
        Int32,
        ConnectionNotifyCallback,
        UInt32
    ) -> Int32

    private typealias RequestNotificationsForWindowsFunc = @convention(c) (
        Int32,
        UnsafePointer<UInt32>,
        Int32
    ) -> Int32

    typealias NotifyCallback = @convention(c) (
        UInt32,
        UnsafeMutableRawPointer?,
        Int,
        Int32
    ) -> Void

    private typealias RegisterNotifyProcFunc = @convention(c) (
        NotifyCallback,
        UInt32,
        UnsafeMutableRawPointer?
    ) -> Int32

    private typealias UnregisterNotifyProcFunc = @convention(c) (
        NotifyCallback,
        UInt32,
        UnsafeMutableRawPointer?
    ) -> Int32

    // MARK: - Stored function pointers

    // Required
    private let _mainConnectionID: MainConnectionIDFunc
    private let _windowQueryWindows: WindowQueryWindowsFunc
    private let _windowQueryResultCopyWindows: WindowQueryResultCopyWindowsFunc
    private let _windowIteratorGetCount: WindowIteratorGetCountFunc
    private let _windowIteratorAdvance: WindowIteratorAdvanceFunc
    private let _transactionCreate: TransactionCreateFunc
    private let _transactionCommit: TransactionCommitFunc
    private let _transactionOrderWindow: TransactionOrderWindowFunc
    private let _disableUpdate: DisableUpdateFunc
    private let _reenableUpdate: ReenableUpdateFunc

    // Optional iterator symbols
    private let _windowIteratorGetBounds: WindowIteratorGetBoundsFunc?
    private let _windowIteratorGetWindowID: WindowIteratorGetWindowIDFunc?
    private let _windowIteratorGetPID: WindowIteratorGetPIDFunc?
    private let _windowIteratorGetLevel: WindowIteratorGetLevelFunc?
    private let _windowIteratorGetTags: WindowIteratorGetTagsFunc?
    private let _windowIteratorGetAttributes: WindowIteratorGetAttributesFunc?
    private let _windowIteratorGetParentID: WindowIteratorGetParentIDFunc?

    // Optional transaction/movement
    private let _transactionMoveWindowWithGroup: TransactionMoveWindowWithGroupFunc?
    private let _moveWindow: MoveWindowFunc?
    private let _getWindowBounds: GetWindowBoundsFunc?

    // Optional notification symbols
    private let _registerConnectionNotifyProc: RegisterConnectionNotifyProcFunc?
    private let _unregisterConnectionNotifyProc: UnregisterConnectionNotifyProcFunc?
    private let _requestNotificationsForWindows: RequestNotificationsForWindowsFunc?
    private let _registerNotifyProc: RegisterNotifyProcFunc?
    private let _unregisterNotifyProc: UnregisterNotifyProcFunc?

    // CFRelease for SkyLight-returned CFTypeRefs
    private let _cfRelease: (@convention(c) (CFTypeRef) -> Void)

    // MARK: - Init (returns nil on failure)

    private init?() {
        guard let lib = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY
        ) else {
            Self.logger.error("Failed to dlopen SkyLight.framework")
            return nil
        }

        guard let cfLib = dlopen(
            "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",
            RTLD_LAZY
        ) else {
            Self.logger.error("Failed to dlopen CoreFoundation.framework")
            return nil
        }

        guard let cfReleasePtr = dlsym(cfLib, "CFRelease") else {
            Self.logger.error("Failed to resolve CFRelease")
            return nil
        }
        _cfRelease = unsafeBitCast(cfReleasePtr, to: (@convention(c) (CFTypeRef) -> Void).self)

        func resolve<T>(_ symbol: String, as _: T.Type) -> T? {
            guard let ptr = dlsym(lib, symbol) else { return nil }
            return unsafeBitCast(ptr, to: T.self)
        }

        // Resolve required symbols
        var missing: [String] = []

        func required<T>(_ symbol: String, as type: T.Type) -> T? {
            let result: T? = resolve(symbol, as: type)
            if result == nil { missing.append(symbol) }
            return result
        }

        let mainConnectionID = required("SLSMainConnectionID", as: MainConnectionIDFunc.self)
        let windowQueryWindows = required("SLSWindowQueryWindows", as: WindowQueryWindowsFunc.self)
        let windowQueryResultCopyWindows = required("SLSWindowQueryResultCopyWindows", as: WindowQueryResultCopyWindowsFunc.self)
        let windowIteratorGetCount = required("SLSWindowIteratorGetCount", as: WindowIteratorGetCountFunc.self)
        let windowIteratorAdvance = required("SLSWindowIteratorAdvance", as: WindowIteratorAdvanceFunc.self)
        let transactionCreate = required("SLSTransactionCreate", as: TransactionCreateFunc.self)
        let transactionCommit = required("SLSTransactionCommit", as: TransactionCommitFunc.self)
        let transactionOrderWindow = required("SLSTransactionOrderWindow", as: TransactionOrderWindowFunc.self)
        let disableUpdate = required("SLSDisableUpdate", as: DisableUpdateFunc.self)
        let reenableUpdate = required("SLSReenableUpdate", as: ReenableUpdateFunc.self)

        if !missing.isEmpty {
            Self.logger.error("SkyLight missing required symbols: \(missing.joined(separator: ", "), privacy: .public)")
            return nil
        }

        guard let mainConnectionID,
              let windowQueryWindows,
              let windowQueryResultCopyWindows,
              let windowIteratorGetCount,
              let windowIteratorAdvance,
              let transactionCreate,
              let transactionCommit,
              let transactionOrderWindow,
              let disableUpdate,
              let reenableUpdate
        else {
            return nil
        }

        self._mainConnectionID = mainConnectionID
        self._windowQueryWindows = windowQueryWindows
        self._windowQueryResultCopyWindows = windowQueryResultCopyWindows
        self._windowIteratorGetCount = windowIteratorGetCount
        self._windowIteratorAdvance = windowIteratorAdvance
        self._transactionCreate = transactionCreate
        self._transactionCommit = transactionCommit
        self._transactionOrderWindow = transactionOrderWindow
        self._disableUpdate = disableUpdate
        self._reenableUpdate = reenableUpdate

        // Optional iterator symbols
        _windowIteratorGetBounds = resolve("SLSWindowIteratorGetBounds", as: WindowIteratorGetBoundsFunc.self)
        _windowIteratorGetWindowID = resolve("SLSWindowIteratorGetWindowID", as: WindowIteratorGetWindowIDFunc.self)
        _windowIteratorGetPID = resolve("SLSWindowIteratorGetPID", as: WindowIteratorGetPIDFunc.self)
        _windowIteratorGetLevel = resolve("SLSWindowIteratorGetLevel", as: WindowIteratorGetLevelFunc.self)
        _windowIteratorGetTags = resolve("SLSWindowIteratorGetTags", as: WindowIteratorGetTagsFunc.self)
        _windowIteratorGetAttributes = resolve("SLSWindowIteratorGetAttributes", as: WindowIteratorGetAttributesFunc.self)
        _windowIteratorGetParentID = resolve("SLSWindowIteratorGetParentID", as: WindowIteratorGetParentIDFunc.self)

        // Optional transaction/movement
        _transactionMoveWindowWithGroup = resolve("SLSTransactionMoveWindowWithGroup", as: TransactionMoveWindowWithGroupFunc.self)
        _moveWindow = resolve("SLSMoveWindow", as: MoveWindowFunc.self)
        _getWindowBounds = resolve("SLSGetWindowBounds", as: GetWindowBoundsFunc.self)

        // Optional notification symbols
        _registerConnectionNotifyProc = resolve("SLSRegisterConnectionNotifyProc", as: RegisterConnectionNotifyProcFunc.self)
        _unregisterConnectionNotifyProc = resolve("SLSUnregisterConnectionNotifyProc", as: UnregisterConnectionNotifyProcFunc.self)
            ?? resolve("SLSRemoveConnectionNotifyProc", as: UnregisterConnectionNotifyProcFunc.self)
        _requestNotificationsForWindows = resolve("SLSRequestNotificationsForWindows", as: RequestNotificationsForWindowsFunc.self)
        _registerNotifyProc = resolve("SLSRegisterNotifyProc", as: RegisterNotifyProcFunc.self)
        _unregisterNotifyProc = resolve("SLSUnregisterNotifyProc", as: UnregisterNotifyProcFunc.self)
            ?? resolve("SLSRemoveNotifyProc", as: UnregisterNotifyProcFunc.self)
    }

    // MARK: - Public API

    func getMainConnectionID() -> Int32 {
        _mainConnectionID()
    }

    // MARK: Query

    func queryWindows(
        connectionId cid: Int32,
        windowArray: CFArray,
        flags: UInt32
    ) -> CFTypeRef? {
        _windowQueryWindows(cid, windowArray, flags)
    }

    func queryResultCopyWindows(_ query: CFTypeRef) -> CFTypeRef? {
        _windowQueryResultCopyWindows(query)
    }

    // MARK: Iterator

    func iteratorGetCount(_ iterator: CFTypeRef) -> Int32 {
        _windowIteratorGetCount(iterator)
    }

    func iteratorAdvance(_ iterator: CFTypeRef) -> Bool {
        _windowIteratorAdvance(iterator)
    }

    func iteratorGetWindowID(_ iterator: CFTypeRef) -> UInt32? {
        _windowIteratorGetWindowID?(iterator)
    }

    func iteratorGetPID(_ iterator: CFTypeRef) -> Int32? {
        _windowIteratorGetPID?(iterator)
    }

    func iteratorGetBounds(_ iterator: CFTypeRef) -> CGRect? {
        _windowIteratorGetBounds?(iterator)
    }

    func iteratorGetLevel(_ iterator: CFTypeRef) -> Int32? {
        _windowIteratorGetLevel?(iterator)
    }

    func iteratorGetTags(_ iterator: CFTypeRef) -> UInt64? {
        _windowIteratorGetTags?(iterator)
    }

    func iteratorGetAttributes(_ iterator: CFTypeRef) -> UInt32? {
        _windowIteratorGetAttributes?(iterator)
    }

    func iteratorGetParentID(_ iterator: CFTypeRef) -> UInt32? {
        _windowIteratorGetParentID?(iterator)
    }

    /// Whether all iterator accessors are available.
    var hasIteratorSupport: Bool {
        _windowIteratorGetBounds != nil
            && _windowIteratorGetWindowID != nil
            && _windowIteratorGetPID != nil
            && _windowIteratorGetLevel != nil
            && _windowIteratorGetTags != nil
            && _windowIteratorGetAttributes != nil
            && _windowIteratorGetParentID != nil
    }

    // MARK: Transactions

    func transactionCreate(_ cid: Int32) -> CFTypeRef? {
        _transactionCreate(cid)
    }

    func transactionCommit(_ transaction: CFTypeRef, flags: Int32 = 0) -> CGError {
        _transactionCommit(transaction, flags)
    }

    func transactionOrderWindow(
        _ transaction: CFTypeRef,
        windowId: UInt32,
        order: Int32,
        relativeTo: UInt32
    ) {
        _transactionOrderWindow(transaction, windowId, order, relativeTo)
    }

    func transactionMoveWindowWithGroup(
        _ transaction: CFTypeRef,
        windowId: UInt32,
        point: CGPoint
    ) -> CGError? {
        _transactionMoveWindowWithGroup?(transaction, windowId, point)
    }

    // MARK: Direct window operations

    func moveWindow(_ wid: UInt32, to point: CGPoint) -> Bool {
        guard let move = _moveWindow else { return false }
        let cid = getMainConnectionID()
        guard cid != 0 else { return false }
        var pt = point
        return move(cid, wid, &pt) == .success
    }

    func getWindowBounds(_ wid: UInt32) -> CGRect? {
        guard let getBounds = _getWindowBounds else { return nil }
        let cid = getMainConnectionID()
        guard cid != 0 else { return nil }
        var rect = CGRect.zero
        guard getBounds(cid, wid, &rect) == .success else { return nil }
        return rect
    }

    // MARK: Display updates

    func disableUpdate() {
        _disableUpdate(getMainConnectionID())
    }

    func reenableUpdate() {
        _reenableUpdate(getMainConnectionID())
    }

    // MARK: Window ordering

    func orderWindow(
        _ wid: UInt32,
        relativeTo targetWid: UInt32,
        order: SkyLightWindowOrder = .above
    ) {
        let cid = getMainConnectionID()
        guard let transaction = _transactionCreate(cid) else {
            Self.logger.error("Failed to create SkyLight transaction for orderWindow")
            return
        }
        defer { releaseCF(transaction) }
        _transactionOrderWindow(transaction, wid, order.rawValue, targetWid)
        _ = _transactionCommit(transaction, 0)
    }

    // MARK: Batch operations

    func batchMoveWindows(_ positions: [(windowId: UInt32, origin: CGPoint)]) {
        guard let transactionMove = _transactionMoveWindowWithGroup else {
            for (wid, origin) in positions {
                _ = moveWindow(wid, to: origin)
            }
            return
        }

        let cid = getMainConnectionID()
        guard let transaction = _transactionCreate(cid) else {
            for (wid, origin) in positions {
                _ = moveWindow(wid, to: origin)
            }
            return
        }
        defer { releaseCF(transaction) }

        for (wid, origin) in positions {
            _ = transactionMove(transaction, wid, origin)
        }
        _ = _transactionCommit(transaction, 0)
    }

    // MARK: Window title (via CGWindowListCopyWindowInfo)

    func getWindowTitle(_ windowId: UInt32) -> String? {
        let options: CGWindowListOption = [.optionIncludingWindow]
        guard let windowList = CGWindowListCopyWindowInfo(options, CGWindowID(windowId)) as? [[String: Any]],
              let windowInfo = windowList.first,
              let title = windowInfo[kCGWindowName as String] as? String
        else { return nil }
        return title
    }

    // MARK: Notifications

    func registerForNotification(
        event: CGSEventType,
        callback: @escaping ConnectionNotifyCallback,
        context: UnsafeMutableRawPointer? = nil
    ) -> Bool {
        guard let register = _registerConnectionNotifyProc else { return false }
        let cid = getMainConnectionID()
        guard cid != 0 else { return false }
        return register(cid, callback, event.rawValue, context) == 0
    }

    func unregisterForNotification(
        event: CGSEventType,
        callback: @escaping ConnectionNotifyCallback
    ) -> Bool {
        guard let unregister = _unregisterConnectionNotifyProc else { return false }
        let cid = getMainConnectionID()
        guard cid != 0 else { return false }
        return unregister(cid, callback, event.rawValue) == 0
    }

    func registerNotifyProc(
        event: CGSEventType,
        callback: @escaping NotifyCallback,
        context: UnsafeMutableRawPointer? = nil
    ) -> Bool {
        guard let register = _registerNotifyProc else { return false }
        return register(callback, event.rawValue, context) == 0
    }

    func unregisterNotifyProc(
        event: CGSEventType,
        callback: @escaping NotifyCallback,
        context: UnsafeMutableRawPointer? = nil
    ) -> Bool {
        guard let unregister = _unregisterNotifyProc else { return false }
        return unregister(callback, event.rawValue, context) == 0
    }

    func subscribeToWindowNotifications(_ windowIds: [UInt32]) -> Bool {
        guard let request = _requestNotificationsForWindows else { return false }
        guard !windowIds.isEmpty else { return true }
        let cid = getMainConnectionID()
        guard cid != 0 else { return false }
        return windowIds.withUnsafeBufferPointer { buffer in
            request(cid, buffer.baseAddress!, Int32(windowIds.count))
        } == 0
    }

    // MARK: - Internal helpers

    func releaseCF(_ ref: CFTypeRef) {
        _cfRelease(ref)
    }
}
