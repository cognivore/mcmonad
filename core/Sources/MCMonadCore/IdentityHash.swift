import CryptoKit
import Foundation
import Security
import os

/// Stable salted SHA-256 of a window title, used as one component of a
/// privacy-preserving cross-restart window identity.
///
/// Unlike `TitleHash` — which uses a per-process random salt so the same
/// title yields different hashes across runs (anti-rainbow-table for
/// log leaks) — `IdentityHash` uses a *persistent* per-user salt stored
/// at `~/.config/mcmonad/.identity-salt` (mode 0600). That gives:
///
/// - **Cross-restart stability.** A window whose title doesn't change
///   produces the same hash next time mcmonad restarts. This is the
///   property we need to match a saved StableWindowId against a live
///   window on the next mcmonad launch.
/// - **Anti-correlation across users.** Hashes from a leaked
///   persistence file cannot be correlated against another user's logs,
///   because the salt is per-user and never leaves the disk.
/// - **Defense in depth, not full-system encryption.** Anyone with
///   filesystem access to the salt file can rainbow-table common
///   titles, just like they can read other config files. The salt
///   protects against *accidental* leakage (e.g. a debug dump of the
///   persistence file pasted into a bug report), not against an
///   attacker on the user's machine.
///
/// Output is 16 hex chars (8 bytes) — longer than `TitleHash` (4 bytes)
/// because collisions in the identity layer cause workspace
/// misassignment, while collisions in the log layer only cause
/// confusing log lines.
enum IdentityHash {
    /// Sentinel returned for windows that lack a title or whose title
    /// is unreadable. Length-distinct from a real hex hash (16 chars)
    /// so they don't visually collide when scanning.
    static let none = "none"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var saltCache: [UInt8]?

    private static let logger = Logger(
        subsystem: "com.mcmonad.core",
        category: "IdentityHash"
    )

    /// Hash a window title. Returns nil for nil input (so callers can
    /// distinguish "no title" from "title was hashed"), and the
    /// sentinel `none` for an empty title.
    static func hash(title: String?) -> String? {
        guard let title = title else { return nil }
        if title.isEmpty { return Self.none }

        var hasher = SHA256()
        ensureSalt().withUnsafeBufferPointer { buf in
            hasher.update(bufferPointer: UnsafeRawBufferPointer(buf))
        }
        hasher.update(data: Data(title.utf8))
        let digest = hasher.finalize()
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func ensureSalt() -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = saltCache { return cached }

        let salt = loadOrCreateSalt()
        saltCache = salt
        return salt
    }

    private static func saltPath() -> String {
        let home = NSHomeDirectory()
        return home + "/.config/mcmonad/.identity-salt"
    }

    /// Read 32 bytes of salt from disk, or create the file with fresh
    /// random bytes if it doesn't exist. Always returns 32 bytes —
    /// regenerates on any read error.
    private static func loadOrCreateSalt() -> [UInt8] {
        let path = saltPath()
        let fm = FileManager.default

        if fm.fileExists(atPath: path),
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           data.count == 32 {
            return Array(data)
        }

        // Either the file is missing, the read failed, or the length
        // is wrong. Generate a fresh salt and write it with 0600.
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBufferPointer { buf in
            SecRandomCopyBytes(kSecRandomDefault, buf.count, buf.baseAddress!)
        }
        guard status == errSecSuccess else {
            // Cryptographic RNG failure — extremely rare. Log loudly
            // and return zeros; the salt is still a salt, just a weak
            // one. We don't want to crash mcmonad-core over this.
            logger.error("SecRandomCopyBytes failed; using zero salt — identity hashes are weak this run")
            return bytes
        }

        let dir = (path as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = Data(bytes)
        try? data.write(to: URL(fileURLWithPath: path), options: [.atomic])
        // Tighten permissions to user-only read/write.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return bytes
    }
}
