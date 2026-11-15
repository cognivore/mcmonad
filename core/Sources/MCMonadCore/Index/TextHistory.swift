import Foundation

// AI-generated text: model claude-opus-5-5; reasoning effort unavailable (not exposed by the harness).

/// What every window said over the last day: each distinct line of text read
/// off it and each title it had, with when it was first and last seen, and
/// the minutes the user worked in it. Kept in this process's memory only,
/// like everything read off the framebuffer: never written, logged or sent
/// to the brain. Turning the index off empties it; a restart forgets it.
///
/// The screen is read rarely, so this is a set of snippets, not a record:
/// "where is" is told so, and reconstructs from them.
struct TextHistory: Sendable {
    /// How long a line is remembered after it was last seen.
    static let keep: TimeInterval = 24 * 3600
    static let maxLinesPerWindow = 3_000
    static let maxLines = 50_000
    /// Rows with fewer letters or digits than this are noise to a search
    /// (a prompt sign, a line number, a lone icon read as a glyph).
    static let minAlphanumerics = 3

    enum Kind: Equatable, Sendable {
        case screen
        case title
    }

    struct Sighting: Equatable, Sendable {
        let kind: Kind
        var text: String
        /// `TextHistory.key(text)`: what two readings of one line share.
        var key: String
        let firstSeen: Date
        var lastSeen: Date
        /// When it was first recorded among all sightings; neighbours in
        /// this order were read together.
        let order: Int
    }

    struct Window: Sendable {
        var app: String
        var title: String
        var tag: String?
        var closedAt: Date?
        var sightings: [Sighting] = []
        /// Minutes (since the epoch) in which the user gave intense input
        /// while this window was focused.
        var activeMinutes: Set<Int> = []
        var lastInput: Date?
        fileprivate var index: [String: Int] = [:]
    }

    private(set) var windows: [UInt32: Window] = [:]
    private var order = 0

    var lineCount: Int { windows.values.reduce(0) { $0 + $1.sightings.count } }

    // MARK: - Keys

    /// Case, spacing and the glyphs OCR confuses (I i l 1 |, O 0) aside, so a
    /// line read twice is one line. ("mail" and "mall" are one key: rare
    /// for whole lines, and a search finds both.)
    static func key(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var space = false
        for ch in text {
            if ch.isWhitespace { space = !out.isEmpty; continue }
            if space { out.append(" "); space = false }
            for c in ch.lowercased() {
                switch c {
                case "i", "1", "|": out.append("l")
                case "0": out.append("o")
                default: out.append(c)
                }
            }
        }
        return out
    }

    static func meaningful(_ text: String) -> Bool {
        var n = 0
        for ch in text where ch.isLetter || ch.isNumber {
            n += 1
            if n >= minAlphanumerics { return true }
        }
        return false
    }

    // MARK: - Told by the index

    /// The windows the window manager has now, from its latest snapshot.
    /// Titles go into the history as they change; a window missing from
    /// the snapshot is closed (and opens again if it comes back).
    mutating func noteWindows(_ present: [(id: UInt32, app: String, title: String, tag: String?)], at date: Date) {
        var seen = Set<UInt32>()
        for w in present {
            seen.insert(w.id)
            var window = windows[w.id] ?? Window(app: w.app, title: w.title, tag: w.tag)
            window.app = w.app
            window.title = w.title
            window.tag = w.tag
            window.closedAt = nil
            windows[w.id] = window
            if Self.meaningful(w.title) { see(w.id, kind: .title, text: w.title, at: date) }
        }
        for (id, window) in windows where window.closedAt == nil && !seen.contains(id) {
            windows[id]?.closedAt = date
        }
    }

    /// Rows just read off a window. A new row that the row it replaced
    /// begins is that row, longer (text typed at the end of a line): it is
    /// one sighting, first seen when the shorter one was.
    mutating func record(_ id: UInt32, rows: [String], replaced: [String], at date: Date) {
        guard windows[id] != nil else { return }
        let shorter = replaced.filter(Self.meaningful).map(Self.key)
        for row in rows where Self.meaningful(row) {
            let key = Self.key(row)
            if let old = shorter.first(where: { $0 != key && key.hasPrefix($0) }),
               let i = windows[id]?.index[Self.slot(.screen, old)],
               windows[id]?.index[Self.slot(.screen, key)] == nil {
                windows[id]?.sightings[i].text = row
                windows[id]?.sightings[i].key = key
                windows[id]?.sightings[i].lastSeen = date
                windows[id]?.index[Self.slot(.screen, old)] = nil
                windows[id]?.index[Self.slot(.screen, key)] = i
                continue
            }
            see(id, kind: .screen, text: row, at: date)
        }
    }

    /// Rows still on a window: seen again now.
    mutating func touch(_ id: UInt32, rows: [String], at date: Date) {
        guard windows[id] != nil else { return }
        for row in rows where Self.meaningful(row) { see(id, kind: .screen, text: row, at: date) }
    }

    mutating func noteInput(_ id: UInt32, at date: Date) {
        guard windows[id] != nil else { return }
        windows[id]?.activeMinutes.insert(Int(date.timeIntervalSince1970 / 60))
        windows[id]?.lastInput = date
    }

    private static func slot(_ kind: Kind, _ key: String) -> String {
        (kind == .title ? "t\u{1}" : "s\u{1}") + key
    }

    private mutating func see(_ id: UInt32, kind: Kind, text: String, at date: Date) {
        guard var w = windows[id] else { return }
        let key = Self.key(text)
        let slot = Self.slot(kind, key)
        if let i = w.index[slot] {
            w.sightings[i].lastSeen = max(date, w.sightings[i].lastSeen)
        } else {
            order += 1
            w.index[slot] = w.sightings.count
            w.sightings.append(Sighting(kind: kind, text: text, key: key, firstSeen: date, lastSeen: date, order: order))
        }
        windows[id] = w
    }

    // MARK: - Forgetting

    /// Drops what was last seen more than `keep` ago, closed windows with
    /// nothing left, and the least recently seen lines beyond the caps.
    mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.keep)
        let minuteCutoff = Int(cutoff.timeIntervalSince1970 / 60)
        for id in Array(windows.keys) {
            guard var w = windows[id] else { continue }
            if let closed = w.closedAt, closed < cutoff {
                windows[id] = nil
                continue
            }
            var lines = w.sightings.filter { $0.lastSeen >= cutoff }
            if lines.count > Self.maxLinesPerWindow {
                let newest = lines.sorted { $0.lastSeen > $1.lastSeen }.prefix(Self.maxLinesPerWindow)
                let keep = Set(newest.map(\.order))
                lines = lines.filter { keep.contains($0.order) }
            }
            if lines.count != w.sightings.count { w.sightings = lines; w.reindex() }
            w.activeMinutes = w.activeMinutes.filter { $0 >= minuteCutoff }
            windows[id] = w
        }
        let total = lineCount
        guard total > Self.maxLines else { return }
        var all: [(Date, UInt32, Int)] = []
        all.reserveCapacity(total)
        for (id, w) in windows { for s in w.sightings { all.append((s.lastSeen, id, s.order)) } }
        all.sort { $0.0 < $1.0 }
        var drop: [UInt32: Set<Int>] = [:]
        for (_, id, order) in all.prefix(total - Self.maxLines) { drop[id, default: []].insert(order) }
        for (id, orders) in drop {
            windows[id]?.sightings.removeAll { orders.contains($0.order) }
            windows[id]?.reindex()
        }
    }

    mutating func removeAll() {
        windows = [:]
    }
}

private extension TextHistory.Window {
    mutating func reindex() {
        index = [:]
        for (i, s) in sightings.enumerated() {
            index[(s.kind == .title ? "t\u{1}" : "s\u{1}") + s.key] = i
        }
    }
}

// MARK: - Evidence for a question

/// What the history says about each window for one question: the lines
/// that were on it earlier and are gone now (those matching the question
/// first, with the lines read beside them, then the most recent), its
/// earlier titles, and when the user last worked in it. Formatted for the
/// model, each line prefixed with when it was seen.
enum HistoryEvidence {
    struct ForWindow: Equatable, Sendable {
        let earlier: [String]
        let lastActive: Date?
        let activeMinutes: Int
    }

    struct Closed: Equatable, Sendable {
        let id: UInt32
        let app: String
        let title: String
        let tag: String?
        let closedAt: Date
        let earlier: [String]
    }

    /// Lines kept for every window whatever the question; the rest of
    /// `budget` goes to the windows whose history matches it, best first.
    static let recentPerWindow = 400
    static let hitsPerWindow = 6_000
    static let closedShown = 12

    /// `onScreen(id)` is the keys of the rows the index sees on that window
    /// now (they are in its `text` already). `clock` formats a time of day.
    static func select(
        _ history: TextHistory,
        windows ids: [UInt32],
        onScreen: (UInt32) -> Set<String>,
        terms: [String],
        budget: Int,
        clock: (Date) -> String
    ) -> (windows: [UInt32: ForWindow], closed: [Closed]) {
        let needles = terms.flatMap(variants)
        let open = ids.filter { history.windows[$0] != nil }
        let closedIds = history.windows
            .filter { $0.value.closedAt != nil && !ids.contains($0.key) }
            .sorted { $0.value.closedAt! > $1.value.closedAt! }
            .map(\.key)
        var candidates: [(id: UInt32, earlier: [TextHistory.Sighting], hits: [Int: Int], score: Int)] = []
        for id in open + closedIds {
            guard let w = history.windows[id] else { continue }
            let visible = w.closedAt == nil ? onScreen(id) : []
            let earlier = w.sightings.filter { s in
                s.kind == .title ? s.text != w.title || w.closedAt != nil : !visible.contains(s.key)
            }
            var hits: [Int: Int] = [:]
            for s in earlier {
                let n = Set(needles.filter { s.key.contains($0.needle) }.map(\.term)).count
                if n > 0 { hits[s.order] = n }
            }
            candidates.append((id, earlier, hits, hits.values.max() ?? 0))
        }
        // Closed windows are shown when they match, or are the most recent.
        let shownClosed = Set(candidates.filter { history.windows[$0.id]?.closedAt != nil }
            .enumerated().filter { $0.element.score > 0 || $0.offset < 4 }.prefix(closedShown).map(\.element.id))
        candidates.removeAll { history.windows[$0.id]?.closedAt != nil && !shownClosed.contains($0.id) }

        let count = max(1, candidates.count)
        let recent = min(recentPerWindow, budget / (2 * count))
        var hitBudget = max(0, budget - recent * candidates.count)
        var quota: [UInt32: Int] = [:]
        for c in candidates.sorted(by: { $0.score > $1.score }) where c.score > 0 {
            let q = min(hitsPerWindow, hitBudget)
            quota[c.id] = q
            hitBudget -= q
        }

        var forWindows: [UInt32: ForWindow] = [:]
        var closed: [Closed] = []
        for c in candidates {
            guard let w = history.windows[c.id] else { continue }
            let lines = pick(c.earlier, hits: c.hits, hitChars: quota[c.id] ?? 0, recentChars: recent, clock: clock)
            if w.closedAt == nil {
                forWindows[c.id] = ForWindow(earlier: lines, lastActive: w.lastInput, activeMinutes: w.activeMinutes.count)
            } else {
                closed.append(Closed(id: c.id, app: w.app, title: w.title, tag: w.tag, closedAt: w.closedAt!, earlier: lines))
            }
        }
        return (forWindows, closed)
    }

    /// The matching sightings (most terms first, then most recent) with the
    /// ones read just before and after each, up to `hitChars`; then the most
    /// recently seen, up to `recentChars`. Returned in the order first seen,
    /// so they read as a story.
    static func pick(_ earlier: [TextHistory.Sighting], hits: [Int: Int], hitChars: Int, recentChars: Int,
                     clock: (Date) -> String) -> [String] {
        var chosen = Set<Int>()
        var spent = 0
        let byOrder = earlier.sorted { $0.order < $1.order }
        let position = Dictionary(uniqueKeysWithValues: byOrder.enumerated().map { ($0.element.order, $0.offset) })
        func take(_ s: TextHistory.Sighting, limit: Int) -> Bool {
            guard !chosen.contains(s.order) else { return true }
            let cost = format(s, clock: clock).count + 1
            guard spent + cost <= limit else { return false }
            chosen.insert(s.order)
            spent += cost
            return true
        }
        let matching = earlier.filter { hits[$0.order] != nil }
            .sorted { (hits[$0.order]!, $0.lastSeen) > (hits[$1.order]!, $1.lastSeen) }
        for s in matching {
            guard take(s, limit: hitChars) else { break }
            guard let p = position[s.order] else { continue }
            for q in [p - 1, p + 1] where byOrder.indices.contains(q) && byOrder[q].kind == .screen {
                _ = take(byOrder[q], limit: hitChars)
            }
        }
        let base = spent
        for s in earlier.sorted(by: { $0.lastSeen > $1.lastSeen }) {
            guard take(s, limit: base + recentChars) else { break }
        }
        return byOrder.filter { chosen.contains($0.order) }.map { format($0, clock: clock) }
    }

    /// "13:02 text", or "13:02–13:40 text" when it stayed on screen a while;
    /// titles say so.
    static func format(_ s: TextHistory.Sighting, clock: (Date) -> String) -> String {
        let from = clock(s.firstSeen), to = clock(s.lastSeen)
        let when = from == to ? from : "\(from)–\(to)"
        return s.kind == .title ? "\(when) title: \(s.text)" : "\(when) \(s.text)"
    }

    /// A term and the forms of it worth looking for (plural, -ing, -ed
    /// dropped), keyed like history lines so OCR's look-alikes match.
    static func variants(_ term: String) -> [(term: String, needle: String)] {
        let key = TextHistory.key(term)
        var forms = [key]
        for suffix in ["ing", "ed", "es", "s"] where key.count - suffix.count >= 4 && key.hasSuffix(suffix) {
            forms.append(String(key.dropLast(suffix.count)))
        }
        return forms.map { (term, $0) }
    }
}
