import ApplicationServices
import Foundation
import os

// MARK: - WindowFocus

/// Focuses a window using private process APIs.
/// Loads functions via dlopen on ApplicationServices.framework.
/// All errors are logged, never crashes.
enum WindowFocus {
    private static let logger = Logger(
        subsystem: "com.mcmonad.core",
        category: "WindowFocus"
    )

    // MARK: - Private API function types

    private typealias GetProcessForPIDFunc = @convention(c) (
        pid_t,
        UnsafeMutablePointer<ProcessSerialNumber>
    ) -> OSStatus

    private typealias SetFrontProcessWithOptionsFunc = @convention(c) (
        UnsafeMutablePointer<ProcessSerialNumber>,
        UInt32,
        UInt32
    ) -> OSStatus

    private typealias PostEventRecordToFunc = @convention(c) (
        UnsafeMutablePointer<ProcessSerialNumber>,
        UnsafeMutablePointer<UInt8>
    ) -> OSStatus

    // MARK: - Resolved function pointers (loaded once)

    private static let resolvedAPIs: ResolvedAPIs? = {
        guard let lib = dlopen(
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
            RTLD_LAZY
        ) else {
            logger.error("Failed to dlopen ApplicationServices.framework")
            return nil
        }

        func resolve<T>(_ symbol: String, as _: T.Type) -> T? {
            guard let ptr = dlsym(lib, symbol) else {
                logger.warning("Missing symbol: \(symbol, privacy: .public)")
                return nil
            }
            return unsafeBitCast(ptr, to: T.self)
        }

        guard let getProcess = resolve(
            "GetProcessForPID",
            as: GetProcessForPIDFunc.self
        ) else {
            logger.error("Critical symbol GetProcessForPID not found")
            return nil
        }

        guard let setFront = resolve(
            "_SLPSSetFrontProcessWithOptions",
            as: SetFrontProcessWithOptionsFunc.self
        ) else {
            logger.error("Critical symbol _SLPSSetFrontProcessWithOptions not found")
            return nil
        }

        guard let postEvent = resolve(
            "SLPSPostEventRecordTo",
            as: PostEventRecordToFunc.self
        ) else {
            logger.error("Critical symbol SLPSPostEventRecordTo not found")
            return nil
        }

        return ResolvedAPIs(
            getProcessForPID: getProcess,
            setFrontProcessWithOptions: setFront,
            postEventRecordTo: postEvent
        )
    }()

    private struct ResolvedAPIs: Sendable {
        let getProcessForPID: GetProcessForPIDFunc
        let setFrontProcessWithOptions: SetFrontProcessWithOptionsFunc
        let postEventRecordTo: PostEventRecordToFunc
    }

    /// kCPSUserGenerated mode flag
    private static let kCPSUserGenerated: UInt32 = 0x200

    // MARK: - Public API

    /// Focus a window by pid and windowId.
    ///
    /// 1. Resolves ProcessSerialNumber from pid
    /// 2. Calls _SLPSSetFrontProcessWithOptions to bring the app forward
    /// 3. Posts two synthetic key-window events (variants 0x01 and 0x02)
    ///
    /// All errors are logged; this function never throws or crashes.
    /// Convenience alias matching the call-site convention in CommandExecutor.
    static func focus(windowId: UInt32, pid: pid_t) {
        focusWindow(pid: pid, windowId: windowId)
    }

    static func focusWindow(pid: pid_t, windowId: UInt32) {
        guard let apis = resolvedAPIs else {
            logger.error("Cannot focus window: private APIs not available")
            return
        }

        var psn = ProcessSerialNumber()
        let psnResult = apis.getProcessForPID(pid, &psn)
        guard psnResult == noErr else {
            logger.warning(
                "GetProcessForPID failed for pid=\(pid): OSStatus \(psnResult)"
            )
            return
        }

        let setFrontResult = apis.setFrontProcessWithOptions(
            &psn,
            windowId,
            kCPSUserGenerated
        )
        if setFrontResult != noErr {
            logger.warning(
                "SetFrontProcessWithOptions failed for wid=\(windowId): OSStatus \(setFrontResult)"
            )
            // Continue anyway -- the key-window events may still work
        }

        makeKeyWindow(apis: apis, psn: &psn, windowId: windowId)
    }

    // MARK: - Synthetic event construction

    /// Builds and posts the 248-byte (0xF8) synthetic event records
    /// that make the window server treat a window as the key window.
    ///
    /// Two variants are sent (byte [0x08] = 0x01, then 0x02).
    ///
    /// Layout (from OmniWM PrivateAPIs.swift):
    /// - [0x04]       = 0xF8 (event record size)
    /// - [0x08]       = variant (0x01 or 0x02)
    /// - [0x20..0x2F] = 0xFF (16 bytes)
    /// - [0x3A]       = 0x10 (flags)
    /// - [0x3C..0x3F] = windowId (little-endian UInt32)
    private static func makeKeyWindow(
        apis: ResolvedAPIs,
        psn: inout ProcessSerialNumber,
        windowId: UInt32
    ) {
        var eventBytes = [UInt8](repeating: 0, count: 0xF8)

        // Size marker
        eventBytes[0x04] = 0xF8

        // Fill [0x20..0x2F] with 0xFF
        for i in 0x20 ..< 0x30 {
            eventBytes[i] = 0xFF
        }

        // Flags
        eventBytes[0x3A] = 0x10

        // Window ID (little-endian)
        withUnsafeBytes(of: windowId) { ptr in
            eventBytes[0x3C] = ptr[0]
            eventBytes[0x3D] = ptr[1]
            eventBytes[0x3E] = ptr[2]
            eventBytes[0x3F] = ptr[3]
        }

        // Variant 1
        eventBytes[0x08] = 0x01
        let result1 = apis.postEventRecordTo(&psn, &eventBytes)
        if result1 != noErr {
            logger.debug(
                "PostEventRecordTo variant 1 failed for wid=\(windowId): \(result1)"
            )
        }

        // Variant 2
        eventBytes[0x08] = 0x02
        let result2 = apis.postEventRecordTo(&psn, &eventBytes)
        if result2 != noErr {
            logger.debug(
                "PostEventRecordTo variant 2 failed for wid=\(windowId): \(result2)"
            )
        }
    }
}
