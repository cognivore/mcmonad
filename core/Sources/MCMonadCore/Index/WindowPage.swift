import Foundation

// AI-generated text: model claude-opus-5-5; reasoning effort unavailable (not exposed by the harness).

/// A line the engine found, with its box in the read part's own pixels
/// (top-left origin) and a score from 0 to 1.
struct FoundLine: Equatable, Sendable {
    let rect: PixelRect
    let text: String
    let confidence: Float
}

/// A line of text believed to be on a window, with when the pixels it was
/// read from were captured.
struct PageLine: Equatable, Sendable {
    var rect: PixelRect
    let text: String
    let confidence: Float
    let readAt: Date
}

/// Why the engine gave nothing for a part. The part stays unread.
struct ReadFault: Error, Equatable, Sendable {
    let reason: String
}

/// What one look at a window cost.
struct GlanceWork: Equatable, Sendable {
    var readPixels = 0
    var reads = 0
    /// Lines that are new or replaced, as rows of text, top to bottom.
    var newRows: [String] = []
    /// The rows those replaced.
    var replacedRows: [String] = []
    /// Why the engine stopped, when it did.
    var fault: ReadFault?
}

/// What a window says, as far as it has been read, and the strips of its
/// last capture to tell the next one by. The rules are ocr-predictor's,
/// learned on ZoeVM's screens: text is believed for as long as its pixels
/// stay the same; when they change only what changed is read, with the
/// whole lines it touches and a little screen around it; a read never takes
/// more pixels than it was allowed, and what it did not get to is unread and
/// read next time. Two things are this page's own: a scroll moves the lines
/// it carried instead of making them unread, and a window's lines go on to
/// its history as they are read.
///
/// Pure: the engine is a closure, and no pixel is kept.
struct WindowPage: Sendable {
    /// Pixels read around what changed: an engine reads a glyph badly when
    /// the image ends at its edge. Sized for a 2× capture; a 1× one simply
    /// gets twice the margin.
    static let pad = 12
    /// A line this near the edge of what was read may have been cut by it,
    /// unless that edge is the window's own.
    static let edge = 3
    /// The fewest rows of a large part read at once: taller than any line.
    static let band = 192
    /// Unread parts kept apart; more are read as one.
    static let maxParts = 16

    private(set) var tiles: PixelTiles?
    private(set) var lines: [PageLine] = []
    private(set) var unread: [PixelRect] = []
    /// When the capture in which its pixels last changed was taken.
    private(set) var changedAt: Date?

    var bounds: PixelRect? { tiles?.bounds }
    var isFullyRead: Bool { tiles != nil && unread.isEmpty }

    // MARK: - Folding in a capture

    /// Folds a new capture in: lines that kept their pixels stay, lines that
    /// scrolled intact move with them, and everything else that changed is
    /// unread. Returns what changed; nil for a first capture or one of
    /// another size (a resized window is another picture: all of it is
    /// unread and its old lines go).
    @discardableResult
    mutating func observe(_ new: PixelTiles, at date: Date) -> PixelChange? {
        guard let old = tiles, let change = PixelChange.between(old, new) else {
            tiles = new
            lines = []
            unread = [new.bounds]
            changedAt = date
            return nil
        }
        tiles = new
        if change.isNone { return change }
        changedAt = date
        let shift = change.shift
        var moved: [PageLine] = [], stayed: [PageLine] = [], stale: [PageLine] = []
        for var line in lines {
            // A line can be in both places: text repeated a scroll apart (a
            // log printing the same word in every row) stayed where it was
            // and scrolled up as well.
            let still = PixelChange.stayed(line.rect, old, new)
            let scrolled = PixelChange.scrolledIn(line.rect.shifted(dy: -shift), old, new, shift: shift)
            if still { stayed.append(line) }
            if scrolled {
                var copy = line
                copy.rect = line.rect.shifted(dy: -shift)
                moved.append(copy)
            }
            if still || scrolled { continue }
            if shift == 0
                || (new.bounds.holds(line.rect.shifted(dy: -shift))
                    && !PixelChange.stayed(line.rect.shifted(dy: -shift), old, new)) {
                // Changed under it: kept where its pixels most likely are
                // now and read again there, so it is replaced as a whole.
                // (After a scroll, a place whose pixels did not change holds
                // what it held, a fixed header say: the line is not there.)
                line.rect = line.rect.shifted(dy: -shift)
                stale.append(line)
            }
            // Otherwise it scrolled out of the window: whatever took its
            // place scrolled in intact (and moved with its own lines) or
            // is damage. Its words are in the history already.
        }
        // Lines in one place are one line. What scrolled wins over what
        // merely looks as it did: a word repeated in every row ("Compiling")
        // stays put pixel for pixel, yet the line that scrolled over it is
        // the whole of what is there now.
        var placed: [PageLine] = []
        for line in moved + stayed + stale
        where !placed.contains(where: { $0.rect.centres(line.rect) || line.rect.centres($0.rect) }) {
            placed.append(line)
        }
        lines = placed.sorted { ($0.rect.y, $0.rect.x) < ($1.rect.y, $1.rect.x) }
        var parts = change.damage + stale.map(\.rect)
        for part in unread {
            // An unread part may have scrolled, or may be in a part that
            // did not: it stays unread in both places.
            parts.append(part)
            if shift != 0, let moved = part.shifted(dy: -shift).clipped(to: new.bounds) { parts.append(moved) }
        }
        unread = Self.apart(parts.compactMap { $0.clipped(to: new.bounds) })
        if unread.count > Self.maxParts, let all = unread.reduce(nil, { ($0 ?? $1).with($1) }) as PixelRect? {
            unread = [all]
        }
        return change
    }

    // MARK: - Reading

    /// Reads the unread parts, the smallest first, until `budget` pixels
    /// have been handed to `engine` or it fails. `engine` is given a box of
    /// the latest capture and answers in that box's own pixels.
    ///
    /// A change is not always as wide or as tall as the line it is in: a
    /// line that scrolled in under one of the same length differs only where
    /// their words differ. When a read cuts a line the change reaches into,
    /// the part grows on that side (to the window's width along a row, by
    /// the line's height up or down) and is read again, twice at most.
    mutating func read(budget: Int, at date: Date,
                       engine: (PixelRect) -> Result<[FoundLine], ReadFault>) -> GlanceWork {
        var work = GlanceWork()
        guard let field = bounds else { return work }
        var left = budget
        let parts = Self.scopes(unread, lines: lines, field: field).sorted { $0.area < $1.area }
        partsLoop: for first in parts {
            var part = first
            var regrown = 0
            while true {
                let whole = part.grown(Self.pad, within: field)
                // A part larger than what is left is read from its top, a
                // band at a time, if a band worth reading is left.
                let rows = min(whole.h, left / max(1, whole.w))
                if rows < whole.h, rows < Self.band, left < budget { break partsLoop }
                let sample = PixelRect(x: whole.x, y: whole.y, w: whole.w, h: max(1, rows))
                let found: [FoundLine]
                switch engine(sample) {
                case .failure(let fault):
                    work.fault = fault   // not asked again now: the part stays unread
                    return work
                case .success(let lines): found = lines
                }
                work.reads += 1
                work.readPixels += sample.area
                left -= sample.area
                let read = found.compactMap { f -> PageLine? in
                    guard let inside = f.rect.clipped(to: PixelRect(x: 0, y: 0, w: sample.w, h: sample.h)) else { return nil }
                    return PageLine(rect: PixelRect(x: sample.x + inside.x, y: sample.y + inside.y, w: inside.w, h: inside.h),
                                    text: f.text, confidence: f.confidence, readAt: date)
                }
                let banded = sample.bottom < whole.bottom
                var later: PixelRect?
                if !banded, regrown < 2, let bigger = Self.regrow(part, cut: read, sample: sample, field: field) {
                    if bigger.grown(Self.pad, within: field).area <= left {
                        part = bigger
                        regrown += 1
                        continue
                    }
                    // It does not fit what is left of this look: keep what
                    // this read found, and read the grown part next time.
                    later = bigger
                }
                let whole_ = read.filter { !Self.cut($0.rect, sample: sample, field: field) }
                // In a band, what its lower edge cut is read with the rest:
                // the part that is done ends above the highest such line.
                let lowest = read.filter { Self.cut($0.rect, sample: sample, field: field) && $0.rect.bottom + Self.edge > sample.bottom }
                    .map(\.rect.y).filter { $0 > part.y }.min()
                let done: PixelRect = banded
                    ? PixelRect(x: part.x, y: part.y, w: part.w, h: max(0, min(lowest ?? sample.bottom, part.bottom) - part.y))
                    : part
                if done.h == 0 { break partsLoop }   // nothing whole fitted: the part waits for a bigger budget
                let replaced = lines.filter { done.centres($0.rect) }
                let fresh = whole_.filter { done.centres($0.rect) }
                lines.removeAll { done.centres($0.rect) }
                lines.append(contentsOf: fresh)
                lines.sort { ($0.rect.y, $0.rect.x) < ($1.rect.y, $1.rect.x) }
                work.newRows += Self.rows(fresh)
                work.replacedRows += Self.rows(replaced)
                unread.removeAll { part.holds($0) || first.holds($0) }
                if done.h < part.h {
                    unread.append(PixelRect(x: part.x, y: done.bottom, w: part.w, h: part.h - done.h))
                }
                if let later { unread.append(later) }
                break
            }
        }
        return work
    }

    /// `part`, grown on every side where `read` holds a line cut by the
    /// sample's edge that reaches into the part; nil when none does.
    static func regrow(_ part: PixelRect, cut read: [PageLine], sample: PixelRect, field: PixelRect) -> PixelRect? {
        var grown = part
        for line in read.map(\.rect) where cut(line, sample: sample, field: field) && line.meets(part) {
            if (line.x < sample.x + edge && sample.x > field.x) || (line.right + edge > sample.right && sample.right < field.right) {
                grown = grown.with(PixelRect(x: field.x, y: line.y, w: field.w, h: line.h))
            }
            let reach = max(2 * line.h, band / 4)
            if line.y < sample.y + edge && sample.y > field.y {
                grown = grown.with(PixelRect(x: line.x, y: max(field.y, line.y - reach), w: line.w, h: 1))
            }
            if line.bottom + edge > sample.bottom && sample.bottom < field.bottom {
                grown = grown.with(PixelRect(x: line.x, y: min(field.bottom, line.bottom + reach) - 1, w: line.w, h: 1))
            }
        }
        grown = grown.clipped(to: field) ?? part
        return grown == part ? nil : grown
    }

    /// The window's text: its lines as rows, top to bottom.
    var text: String { Self.rows(lines).joined(separator: "\n") }

    /// The rows on screen, for touching up their history.
    var rows: [String] { Self.rows(lines) }

    // MARK: - Pure geometry (ocr-predictor's, at retina scale)

    /// Lines to rows: lines whose middles are within half a line height of
    /// each other are one row, left to right; rows run top to bottom.
    static func rows(_ lines: [PageLine]) -> [String] {
        var rows: [[PageLine]] = []
        for line in lines.sorted(by: { $0.rect.y + $0.rect.h / 2 < $1.rect.y + $1.rect.h / 2 }) {
            if let first = rows.last?.first,
               abs((first.rect.y + first.rect.h / 2) - (line.rect.y + line.rect.h / 2)) * 2 < min(first.rect.h, line.rect.h) {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.map { $0.sorted { $0.rect.x < $1.rect.x }.map(\.text).joined(separator: " ") }
    }

    /// Whether `line` is one the changed `part` touches or goes on from: it
    /// shares a row with it and is no further from it, along that row, than
    /// a line is tall. Text written at the end of a line is that line, longer.
    static func continues(_ part: PixelRect, _ line: PixelRect) -> Bool {
        let reach = max(pad, min(part.h, line.h))
        let beside = PixelRect(x: part.x - reach, y: part.y, w: part.w + 2 * reach, h: part.h)
        return beside.meets(line)
    }

    /// `parts`, with those that meet or go on from each other made one,
    /// until none do.
    static func apart(_ parts: [PixelRect]) -> [PixelRect] {
        var parts = parts
        while true {
            var merged: [PixelRect] = []
            for part in parts {
                if let i = merged.firstIndex(where: { continues($0, part) || continues(part, $0) }) {
                    merged[i] = merged[i].with(part)
                } else {
                    merged.append(part)
                }
            }
            if merged.count == parts.count { return merged }
            parts = merged
        }
    }

    /// What is read to bring `damage` up to date. A line is read whole or
    /// not at all: a part runs the window's width (Vision drops a glyph it
    /// is shown with too little beside it, and a row-high strip of a whole
    /// window is a few hundredths of a second), takes in every line it
    /// touches or goes on from, then every line whose middle it holds.
    /// Lines merely above or below are left: taking those in too is how a
    /// whole page gets read again.
    static func scopes(_ damage: [PixelRect], lines: [PageLine], field: PixelRect) -> [PixelRect] {
        var scopes = damage.map { part in
            lines.filter { continues(part, $0.rect) }.reduce(part.across(field)) { $0.with($1.rect) }
        }
        while true {
            let before = scopes
            scopes = scopes.map { scope in
                lines.filter { scope.centres($0.rect) }.reduce(scope) { $0.with($1.rect) }
            }
            scopes = apart(scopes)
            if scopes == before { return scopes }
        }
    }

    /// Whether a line read from `sample` may have been cut by its edge: it
    /// comes within `edge` pixels of an edge that is not the window's own.
    static func cut(_ line: PixelRect, sample: PixelRect, field: PixelRect) -> Bool {
        (line.x < sample.x + edge && sample.x > field.x)
            || (line.y < sample.y + edge && sample.y > field.y)
            || (line.right + edge > sample.right && sample.right < field.right)
            || (line.bottom + edge > sample.bottom && sample.bottom < field.bottom)
    }
}
