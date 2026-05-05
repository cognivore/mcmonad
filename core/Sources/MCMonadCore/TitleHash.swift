import ApplicationServices
import CoreGraphics
import CryptoKit
import Foundation
import Security

/// Stable, salted, truncated hash of a window's title for log
/// disambiguation. The only sanctioned channel for distinguishing
/// windows in user-facing logs beyond (windowId, pid).
///
/// Reads `kAXTitleAttribute` via AX, then emits SHA-256 of
/// `salt || title`, first 4 bytes (8 hex chars). The salt is a
/// per-process random `UInt64` generated at first use and kept only
/// in memory — it is never logged, never persisted, never sent over
/// IPC. That gives:
///
/// - Within a single mcmonad-core run, two windows with the same
///   title produce the same hash (so the same `tHash` appearing
///   on multiple log lines means they really are the same window).
/// - Across runs, hashes for the same title differ (so a leaked log
///   can't be brute-forced against a dictionary of common titles
///   to recover what the user was working on).
///
/// **Do not log the raw title via any other channel.** Window titles
/// commonly contain sensitive identifiers (contract names, document
/// content, internal project names). This module exists so that
/// debugging can still distinguish "Ghostty: work" from
/// "Ghostty: secrets" without writing either string to disk.
enum TitleHash {
    /// Sentinels are 5 chars so they don't visually collide with
    /// real 8-hex hashes when scanning logs.
    static let empty = "empty"
    static let axerr = "axerr"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var saltInitialized = false
    nonisolated(unsafe) private static var saltBytes: [UInt8] = Array(repeating: 0, count: 16)
    nonisolated(unsafe) private static var cache: [UInt32: String] = [:]

    /// Returns the 8-hex-char hash of the window's title, or one of
    /// the sentinels (`empty`, `axerr`).
    ///
    /// `pid` is optional — when nil, it's resolved via SkyLight.
    /// Pass it explicitly when the caller already has it, to skip
    /// the lookup.
    static func hash(windowId: UInt32, pid: pid_t? = nil) -> String {
        lock.lock()
        if let cached = cache[windowId] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolvedPid: pid_t
        if let p = pid {
            resolvedPid = p
        } else if let snap = SkyLightQuery.queryWindow(windowId) {
            resolvedPid = snap.pid
        } else {
            return axerr
        }

        let result = compute(windowId: windowId, pid: resolvedPid)
        lock.lock()
        cache[windowId] = result
        lock.unlock()
        return result
    }

    /// Drop the cached hash for a window. Call on title-changed
    /// (so the next `hash()` re-reads AX) and on window destroyed
    /// (so the cache doesn't grow unbounded).
    static func invalidate(windowId: UInt32) {
        lock.lock()
        cache.removeValue(forKey: windowId)
        lock.unlock()
    }

    private static func compute(windowId: UInt32, pid: pid_t) -> String {
        guard let ax = AXWindowService.findAXWindow(windowId: windowId, pid: pid) else {
            return axerr
        }
        var ref: CFTypeRef?
        let res = AXUIElementCopyAttributeValue(
            ax,
            kAXTitleAttribute as CFString,
            &ref
        )
        guard res == .success else { return axerr }
        guard let title = ref as? String else { return axerr }
        if title.isEmpty { return empty }

        var hasher = SHA256()
        ensureSalt().withUnsafeBufferPointer { buf in
            hasher.update(bufferPointer: UnsafeRawBufferPointer(buf))
        }
        hasher.update(data: Data(title.utf8))
        let digest = hasher.finalize()
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private static func ensureSalt() -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        if !saltInitialized {
            _ = saltBytes.withUnsafeMutableBufferPointer { buf in
                SecRandomCopyBytes(kSecRandomDefault, buf.count, buf.baseAddress!)
            }
            saltInitialized = true
        }
        return saltBytes
    }
}
