import Foundation

/// Most-recently-used ordering for everything the launcher lists: windows
/// (touched on every focus change and on every pick), apps and builtin
/// commands (touched when run from the launcher). A monotonic tick, not a
/// clock, so two touches in the same millisecond still order. Memory only;
/// nothing here is persisted.
@MainActor
final class RecentUse {
    private var stamps: [String: UInt64] = [:]
    private var tick: UInt64 = 0

    nonisolated static func window(_ id: UInt32) -> String { "w:\(id)" }
    nonisolated static func app(bundleId: String?, path: String) -> String { "a:" + (bundleId ?? path) }
    static let timer = "c:timer"
    static let screenshot = "c:screenshot"

    func touch(_ key: String) {
        tick &+= 1
        stamps[key] = tick
    }

    /// Zero for something never used; higher is more recent.
    func stamp(_ key: String?) -> UInt64 {
        guard let key else { return 0 }
        return stamps[key] ?? 0
    }

    /// Stable order by recency: used items first, most recent at the top,
    /// never-used items after them in their original order.
    nonisolated static func order<T>(_ items: [T], stamp: (T) -> UInt64) -> [T] {
        items.enumerated()
            .sorted { a, b in
                let sa = stamp(a.element), sb = stamp(b.element)
                return sa != sb ? sa > sb : a.offset < b.offset
            }
            .map { $0.element }
    }
}
