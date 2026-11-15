import Foundation

// AI-generated text: model claude-opus-5-5; reasoning effort unavailable (not exposed by the harness).

/// How hard the user is working the machine right now, from the HID
/// system's running event counts — how many keys, clicks and scroll steps
/// there have been, never which. Sampled every few seconds; costs nothing.
struct InputPulse: Sendable {
    struct Counts: Equatable, Sendable {
        var keys: UInt32
        var clicks: UInt32
        var scrolls: UInt32
    }

    /// How far back the pulse looks, and the score over it that is intense
    /// input: about a typed sentence, a handful of clicks, or a page or two
    /// of scrolling. A key is one point, a click four, eight scroll events
    /// one (a trackpad flick sends dozens).
    static let window: TimeInterval = 30
    static let intenseScore = 24

    private var last: Counts?
    private var recent: [(at: Date, score: Int)] = []

    /// Folds in the counts at `date`; returns the score over the last
    /// `window`. The counters wrap; a first sample scores nothing.
    mutating func note(_ counts: Counts, at date: Date) -> Int {
        defer { last = counts }
        recent.removeAll { date.timeIntervalSince($0.at) > Self.window }
        if let last {
            let keys = Int(counts.keys &- last.keys), clicks = Int(counts.clicks &- last.clicks)
            let scrolls = Int(counts.scrolls &- last.scrolls)
            let score = keys + 4 * clicks + scrolls / 8
            if score > 0 { recent.append((date, score)) }
        }
        return recent.reduce(0) { $0 + $1.score }
    }

    static func isIntense(_ score: Int) -> Bool { score >= intenseScore }
}

/// When a window is looked at because the user is working in it. A window
/// that got intense input owes a look; a look happens at most once every
/// `every` for any one window — the first as soon as the input is intense,
/// the next when `every` has passed, wherever the window is by then (a
/// window left behind on another workspace is read where it is parked).
/// The idle pass's looks count too.
struct GlancePolicy: Sendable {
    /// The N minutes: no window is read for input more often than this.
    static let every: TimeInterval = 120

    private(set) var lastGlance: [UInt32: Date] = [:]
    /// Windows owed a look, with when they first became owed.
    private(set) var owed: [UInt32: Date] = [:]

    mutating func noteIntense(_ id: UInt32, at date: Date) {
        if owed[id] == nil { owed[id] = date }
    }

    mutating func noteGlanced(_ id: UInt32, at date: Date) {
        lastGlance[id] = date
        owed[id] = nil
    }

    /// The window to look at now, if any: an owed window whose last look is
    /// `every` old — `preferring` first (the focused one), then the one owed
    /// longest. `skip` is a window that may not be read now (secure input).
    func due(at date: Date, preferring: UInt32?, skip: UInt32? = nil) -> UInt32? {
        let ready = owed.filter { id, _ in
            id != skip && lastGlance[id].map { date.timeIntervalSince($0) >= Self.every } ?? true
        }
        if let p = preferring, ready[p] != nil { return p }
        return ready.min { ($0.value, $0.key) < ($1.value, $1.key) }?.key
    }

    /// Forgets windows that no longer exist.
    mutating func keep(only ids: Set<UInt32>) {
        lastGlance = lastGlance.filter { ids.contains($0.key) }
        owed = owed.filter { ids.contains($0.key) }
    }
}
