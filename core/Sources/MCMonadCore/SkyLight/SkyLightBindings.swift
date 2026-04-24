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
/// Fatal error if symbols cannot be resolved — SkyLight is required on Tahoe+.
/// All function pointers are `@convention(c)`.
final class SkyLight: @unchecked Sendable {
    static let shared = SkyLight()

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

    // Iterator accessors — all required (can't enumerate windows without them)
    private let _windowIteratorGetBounds: WindowIteratorGetBoundsFunc
    private let _windowIteratorGetWindowID: WindowIteratorGetWindowIDFunc
    private let _windowIteratorGetPID: WindowIteratorGetPIDFunc
    private let _windowIteratorGetLevel: WindowIteratorGetLevelFunc
    private let _windowIteratorGetTags: WindowIteratorGetTagsFunc
    private let _windowIteratorGetAttributes: WindowIteratorGetAttributesFunc
    private let _windowIteratorGetParentID: WindowIteratorGetParentIDFunc

    // Movement — required (can't tile without moving windows)
    private let _transactionMoveWindowWithGroup: TransactionMoveWindowWithGroupFunc
    private let _moveWindow: MoveWindowFunc
    private let _getWindowBounds: GetWindowBoundsFunc

    // Notifications — required (can't observe events without them)
    private let _registerConnectionNotifyProc: RegisterConnectionNotifyProcFunc
    private let _unregisterConnectionNotifyProc: UnregisterConnectionNotifyProcFunc
    private let _requestNotificationsForWindows: RequestNotificationsForWindowsFunc
    private let _registerNotifyProc: RegisterNotifyProcFunc
    private let _unregisterNotifyProc: UnregisterNotifyProcFunc

    // CFRelease for SkyLight-returned CFTypeRefs
    private let _cfRelease: (@convention(c) (CFTypeRef) -> Void)

    // MARK: - Init (fatal on failure — SkyLight is required)

    private init() {
        guard let lib = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY
        ) else {
            fatalError("Failed to dlopen SkyLight.framework — macOS Tahoe+ required")
        }

        guard let cfLib = dlopen(
            "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",
            RTLD_LAZY
        ) else {
            fatalError("Failed to dlopen CoreFoundation.framework")
        }

        guard let cfReleasePtr = dlsym(cfLib, "CFRelease") else {
            fatalError("Failed to resolve CFRelease")
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

        // Core required symbols
        let r01 = required("SLSMainConnectionID", as: MainConnectionIDFunc.self)
        let r02 = required("SLSWindowQueryWindows", as: WindowQueryWindowsFunc.self)
        let r03 = required("SLSWindowQueryResultCopyWindows", as: WindowQueryResultCopyWindowsFunc.self)
        let r04 = required("SLSWindowIteratorGetCount", as: WindowIteratorGetCountFunc.self)
        let r05 = required("SLSWindowIteratorAdvance", as: WindowIteratorAdvanceFunc.self)
        let r06 = required("SLSTransactionCreate", as: TransactionCreateFunc.self)
        let r07 = required("SLSTransactionCommit", as: TransactionCommitFunc.self)
        let r08 = required("SLSTransactionOrderWindow", as: TransactionOrderWindowFunc.self)
        let r09 = required("SLSDisableUpdate", as: DisableUpdateFunc.self)
        let r10 = required("SLSReenableUpdate", as: ReenableUpdateFunc.self)

        // Iterator — all required
        let r11 = required("SLSWindowIteratorGetBounds", as: WindowIteratorGetBoundsFunc.self)
        let r12 = required("SLSWindowIteratorGetWindowID", as: WindowIteratorGetWindowIDFunc.self)
        let r13 = required("SLSWindowIteratorGetPID", as: WindowIteratorGetPIDFunc.self)
        let r14 = required("SLSWindowIteratorGetLevel", as: WindowIteratorGetLevelFunc.self)
        let r15 = required("SLSWindowIteratorGetTags", as: WindowIteratorGetTagsFunc.self)
        let r16 = required("SLSWindowIteratorGetAttributes", as: WindowIteratorGetAttributesFunc.self)
        let r17 = required("SLSWindowIteratorGetParentID", as: WindowIteratorGetParentIDFunc.self)

        // Movement — all required
        let r18 = required("SLSTransactionMoveWindowWithGroup", as: TransactionMoveWindowWithGroupFunc.self)
        let r19 = required("SLSMoveWindow", as: MoveWindowFunc.self)
        let r20 = required("SLSGetWindowBounds", as: GetWindowBoundsFunc.self)

        // Notifications — all required (unregister has alternate names on some macOS versions)
        let r21 = required("SLSRegisterConnectionNotifyProc", as: RegisterConnectionNotifyProcFunc.self)
        let r22: UnregisterConnectionNotifyProcFunc? =
            resolve("SLSUnregisterConnectionNotifyProc", as: UnregisterConnectionNotifyProcFunc.self)
            ?? resolve("SLSRemoveConnectionNotifyProc", as: UnregisterConnectionNotifyProcFunc.self)
        if r22 == nil { missing.append("SLS{Unregister,Remove}ConnectionNotifyProc") }
        let r23 = required("SLSRequestNotificationsForWindows", as: RequestNotificationsForWindowsFunc.self)
        let r24 = required("SLSRegisterNotifyProc", as: RegisterNotifyProcFunc.self)
        let r25: UnregisterNotifyProcFunc? =
            resolve("SLSUnregisterNotifyProc", as: UnregisterNotifyProcFunc.self)
            ?? resolve("SLSRemoveNotifyProc", as: UnregisterNotifyProcFunc.self)
        if r25 == nil { missing.append("SLS{Unregister,Remove}NotifyProc") }

        if !missing.isEmpty {
            fatalError("SkyLight missing required symbols: \(missing.joined(separator: ", "))")
        }

        guard let r01, let r02, let r03, let r04, let r05,
              let r06, let r07, let r08, let r09, let r10,
              let r11, let r12, let r13, let r14, let r15, let r16, let r17,
              let r18, let r19, let r20,
              let r21, let r22, let r23, let r24, let r25
        else { fatalError("SkyLight symbol resolution failed") }

        _mainConnectionID = r01;  _windowQueryWindows = r02
        _windowQueryResultCopyWindows = r03
        _windowIteratorGetCount = r04;  _windowIteratorAdvance = r05
        _transactionCreate = r06;  _transactionCommit = r07
        _transactionOrderWindow = r08
        _disableUpdate = r09;  _reenableUpdate = r10
        _windowIteratorGetBounds = r11;  _windowIteratorGetWindowID = r12
        _windowIteratorGetPID = r13;  _windowIteratorGetLevel = r14
        _windowIteratorGetTags = r15;  _windowIteratorGetAttributes = r16
        _windowIteratorGetParentID = r17
        _transactionMoveWindowWithGroup = r18;  _moveWindow = r19
        _getWindowBounds = r20
        _registerConnectionNotifyProc = r21
        _unregisterConnectionNotifyProc = r22
        _requestNotificationsForWindows = r23
        _registerNotifyProc = r24;  _unregisterNotifyProc = r25
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

    func iteratorGetWindowID(_ iterator: CFTypeRef) -> UInt32 {
        _windowIteratorGetWindowID(iterator)
    }

    func iteratorGetPID(_ iterator: CFTypeRef) -> Int32 {
        _windowIteratorGetPID(iterator)
    }

    func iteratorGetBounds(_ iterator: CFTypeRef) -> CGRect {
        _windowIteratorGetBounds(iterator)
    }

    func iteratorGetLevel(_ iterator: CFTypeRef) -> Int32 {
        _windowIteratorGetLevel(iterator)
    }

    func iteratorGetTags(_ iterator: CFTypeRef) -> UInt64 {
        _windowIteratorGetTags(iterator)
    }

    func iteratorGetAttributes(_ iterator: CFTypeRef) -> UInt32 {
        _windowIteratorGetAttributes(iterator)
    }

    func iteratorGetParentID(_ iterator: CFTypeRef) -> UInt32 {
        _windowIteratorGetParentID(iterator)
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
    ) -> CGError {
        _transactionMoveWindowWithGroup(transaction, windowId, point)
    }

    // MARK: Direct window operations

    func moveWindow(_ wid: UInt32, to point: CGPoint) -> Bool {
        let cid = getMainConnectionID()
        guard cid != 0 else { return false }
        var pt = point
        return _moveWindow(cid, wid, &pt) == .success
    }

    func getWindowBounds(_ wid: UInt32) -> CGRect? {
        let cid = getMainConnectionID()
        guard cid != 0 else { return nil }
        var rect = CGRect.zero
        guard _getWindowBounds(cid, wid, &rect) == .success else { return nil }
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
        let cid = getMainConnectionID()
        guard let transaction = _transactionCreate(cid) else {
            Self.logger.error("Failed to create SkyLight transaction for batchMoveWindows")
            return
        }
        defer { releaseCF(transaction) }

        for (wid, origin) in positions {
            let err = _transactionMoveWindowWithGroup(transaction, wid, origin)
            fputs("SKYLIGHT: batchMove wid=\(wid) to=(\(origin.x),\(origin.y)) err=\(err.rawValue)\n", stderr)
        }
        let commitErr = _transactionCommit(transaction, 0)
        fputs("SKYLIGHT: batchCommit err=\(commitErr.rawValue)\n", stderr)
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
        let cid = getMainConnectionID()
        guard cid != 0 else { return false }
        return _registerConnectionNotifyProc(cid, callback, event.rawValue, context) == 0
    }

    func unregisterForNotification(
        event: CGSEventType,
        callback: @escaping ConnectionNotifyCallback
    ) -> Bool {
        let cid = getMainConnectionID()
        guard cid != 0 else { return false }
        return _unregisterConnectionNotifyProc(cid, callback, event.rawValue) == 0
    }

    func registerNotifyProc(
        event: CGSEventType,
        callback: @escaping NotifyCallback,
        context: UnsafeMutableRawPointer? = nil
    ) -> Bool {
        return _registerNotifyProc(callback, event.rawValue, context) == 0
    }

    func unregisterNotifyProc(
        event: CGSEventType,
        callback: @escaping NotifyCallback,
        context: UnsafeMutableRawPointer? = nil
    ) -> Bool {
        return _unregisterNotifyProc(callback, event.rawValue, context) == 0
    }

    func subscribeToWindowNotifications(_ windowIds: [UInt32]) -> Bool {
        guard !windowIds.isEmpty else { return true }
        let cid = getMainConnectionID()
        guard cid != 0 else { return false }
        return windowIds.withUnsafeBufferPointer { buffer in
            _requestNotificationsForWindows(cid, buffer.baseAddress!, Int32(windowIds.count))
        } == 0
    }

    // MARK: - Internal helpers

    func releaseCF(_ ref: CFTypeRef) {
        _cfRelease(ref)
    }
}
