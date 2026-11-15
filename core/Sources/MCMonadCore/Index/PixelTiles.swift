import Foundation

// AI-generated text: model claude-opus-5-5; reasoning effort unavailable (not exposed by the harness).

/// A box in one capture's own pixels: top-left origin and integers, so
/// unions and comparisons are exact.
struct PixelRect: Equatable, Hashable, Sendable, CustomStringConvertible {
    var x: Int
    var y: Int
    var w: Int
    var h: Int

    var right: Int { x + w }
    var bottom: Int { y + h }
    var area: Int { w * h }
    var description: String { "(\(x),\(y) \(w)×\(h))" }

    /// They overlap by at least one pixel.
    func meets(_ o: PixelRect) -> Bool {
        x < o.right && o.x < right && y < o.bottom && o.y < bottom
    }

    /// `o` lies wholly inside.
    func holds(_ o: PixelRect) -> Bool {
        x <= o.x && y <= o.y && o.right <= right && o.bottom <= bottom
    }

    /// The smallest box around both.
    func with(_ o: PixelRect) -> PixelRect {
        let left = min(x, o.x), top = min(y, o.y)
        return PixelRect(x: left, y: top, w: max(right, o.right) - left, h: max(bottom, o.bottom) - top)
    }

    /// This box with `by` more pixels on every side, as far as `within` goes.
    func grown(_ by: Int, within: PixelRect) -> PixelRect {
        let left = max(x - by, within.x), top = max(y - by, within.y)
        let r = min(right + by, within.right), b = min(bottom + by, within.bottom)
        return PixelRect(x: left, y: top, w: max(0, r - left), h: max(0, b - top))
    }

    /// The middle of `o` is inside.
    func centres(_ o: PixelRect) -> Bool {
        let cx = o.x + o.w / 2, cy = o.y + o.h / 2
        return x <= cx && cx < right && y <= cy && cy < bottom
    }

    /// The part inside `within`, or nil when nothing is.
    func clipped(to within: PixelRect) -> PixelRect? {
        let left = max(x, within.x), top = max(y, within.y)
        let r = min(right, within.right), b = min(bottom, within.bottom)
        guard r > left, b > top else { return nil }
        return PixelRect(x: left, y: top, w: r - left, h: b - top)
    }

    func shifted(dy: Int) -> PixelRect { PixelRect(x: x, y: y + dy, w: w, h: h) }

    /// These rows, as wide as `field`.
    func across(_ field: PixelRect) -> PixelRect { PixelRect(x: field.x, y: y, w: field.w, h: h) }
}

/// A capture reduced to what telling it from the next one needs: a 32-bit
/// hash of every `tileWidth` × 1 strip of pixels. Rows rather than blocks,
/// because text lies in rows and a scroll moves content by whole rows. The
/// pixels themselves are never kept: comparing hashes is as good as
/// comparing pixels, and a big window's hashes are a quarter of a megabyte
/// where its pixels are thirty.
struct PixelTiles: Equatable, Sendable {
    /// Pixels per strip. A change is located to within this much along its
    /// row: wide enough to keep the hashes small, narrow enough that a
    /// changed word does not drag in half of the row.
    static let tileWidth = 128

    let width: Int
    let height: Int
    let columns: Int
    /// Row-major: `hashes[y * columns + column]`.
    let hashes: [UInt32]

    var bounds: PixelRect { PixelRect(x: 0, y: 0, w: width, h: height) }

    init(width: Int, height: Int, columns: Int, hashes: [UInt32]) {
        precondition(width > 0 && height > 0 && columns == Self.columns(for: width)
                     && hashes.count == columns * height, "tiles do not match their size")
        self.width = width
        self.height = height
        self.columns = columns
        self.hashes = hashes
    }

    static func columns(for width: Int) -> Int { (width + tileWidth - 1) / tileWidth }

    /// Hashes of 4-byte pixels (any channel order: a window's captures are
    /// only ever compared with each other) laid out `bytesPerRow` apart.
    init(pixels base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int) {
        precondition(width > 0 && height > 0 && bytesPerRow >= width * 4, "not a 32-bit capture")
        let columns = Self.columns(for: width)
        var hashes = [UInt32](repeating: 0, count: columns * height)
        hashes.withUnsafeMutableBufferPointer { out in
            for y in 0..<height {
                let row = base + y * bytesPerRow
                for c in 0..<columns {
                    let start = c * Self.tileWidth * 4
                    let end = min(width, (c + 1) * Self.tileWidth) * 4
                    out[y * columns + c] = Self.hash(row + start, count: end - start, seed: UInt64(c))
                }
            }
        }
        self.init(width: width, height: height, columns: columns, hashes: hashes)
    }

    /// 64-bit multiply-xor over 8-byte words, folded to 32 bits. Not a
    /// cryptographic hash: two strips of the same window are told apart.
    private static func hash(_ p: UnsafeRawPointer, count: Int, seed: UInt64) -> UInt32 {
        var h: UInt64 = 0x9E37_79B9_7F4A_7C15 ^ (seed &* 0xC2B2_AE3D_27D4_EB4F)
        var i = 0
        while i + 8 <= count {
            h = (h ^ p.loadUnaligned(fromByteOffset: i, as: UInt64.self)) &* 0x0000_0100_0000_01B3
            h ^= h >> 29
            i += 8
        }
        while i < count {
            h = (h ^ UInt64(p.load(fromByteOffset: i, as: UInt8.self))) &* 0x0000_0100_0000_01B3
            i += 1
        }
        h ^= h >> 33
        h = h &* 0xFF51_AFD7_ED55_8CCD
        h ^= h >> 33
        return UInt32(truncatingIfNeeded: h ^ (h >> 32))
    }

    func at(_ y: Int, _ c: Int) -> UInt32 { hashes[y * columns + c] }
}

/// How one capture of a window differs from the one before.
struct PixelChange: Equatable, Sendable {
    /// The window's content scrolled: what was at row `y + shift` is now at
    /// row `y`. Positive when content moved up (reading down a page), zero
    /// when nothing scrolled.
    let shift: Int
    /// Parts whose pixels are neither as they were nor merely scrolled: one
    /// box around each run of changed rows, each as wide as its changed
    /// strips reach.
    let damage: [PixelRect]

    var isNone: Bool { shift == 0 && damage.isEmpty }

    /// Rows closer than this are one part: a line's glyphs leave rows
    /// between them unchanged, and two parts that close are read together.
    static let rowGap = 12

    /// What changed from `old` to `new`, both of one size; nil when the
    /// sizes differ, which makes it another picture altogether.
    static func between(_ old: PixelTiles, _ new: PixelTiles) -> PixelChange? {
        guard old.width == new.width, old.height == new.height else { return nil }
        if old.hashes == new.hashes { return PixelChange(shift: 0, damage: []) }
        let shift = scroll(old, new)
        var damage: [PixelRect] = []
        for y in 0..<new.height {
            var first = -1, last = -1
            for c in 0..<new.columns {
                let now = new.at(y, c)
                if now == old.at(y, c) { continue }
                let from = y + shift
                if shift != 0, from >= 0, from < old.height, now == old.at(from, c) { continue }
                if first < 0 { first = c }
                last = c
            }
            guard first >= 0 else { continue }
            let x = first * PixelTiles.tileWidth
            let row = PixelRect(x: x, y: y, w: min(new.width, (last + 1) * PixelTiles.tileWidth) - x, h: 1)
            if let part = damage.last, y <= part.bottom + rowGap {
                damage[damage.count - 1] = part.with(row)
            } else {
                damage.append(row)
            }
        }
        return PixelChange(shift: shift, damage: damage)
    }

    /// The vertical scroll most changed strips agree on, or 0. A strip that
    /// is unique in its column before and after votes for the distance it
    /// travelled; blank and repeated strips say nothing. A shift wins with
    /// at least `minVotes` votes and a quarter of the strips able to vote.
    static let minVotes = 8

    static func scroll(_ old: PixelTiles, _ new: PixelTiles) -> Int {
        let rows = new.height, cols = new.columns
        // Which (column, hash) pairs occur once in each picture.
        func once(_ t: PixelTiles) -> [UInt64: Int] {
            var at: [UInt64: Int] = [:]
            at.reserveCapacity(rows * cols / 4)
            for y in 0..<rows {
                for c in 0..<cols {
                    let key = UInt64(c) << 32 | UInt64(t.at(y, c))
                    if at[key] == nil { at[key] = y } else { at[key] = -1 }
                }
            }
            return at
        }
        let before = once(old)
        let after = once(new)
        var votes: [Int: Int] = [:]
        var voters = 0
        for (key, y) in after where y >= 0 {
            let c = Int(key >> 32)
            if new.at(y, c) == old.at(y, c) { continue }   // unchanged in place
            guard let from = before[key] else { continue }
            voters += 1
            if from >= 0, from != y { votes[from - y, default: 0] += 1 }
        }
        guard let (shift, count) = votes.max(by: { $0.value != $1.value ? $0.value < $1.value : abs($0.key) > abs($1.key) }),
              count >= minVotes, count * 4 >= voters
        else { return 0 }
        return shift
    }

    /// Whether the strips under `rect` in `new` are those under it in `old`.
    static func stayed(_ rect: PixelRect, _ old: PixelTiles, _ new: PixelTiles) -> Bool {
        same(rect, old, new, from: 0)
    }

    /// Whether the strips under `rect` in `new` are those `shift` rows below
    /// it in `old`: whatever was there scrolled up into it intact.
    static func scrolledIn(_ rect: PixelRect, _ old: PixelTiles, _ new: PixelTiles, shift: Int) -> Bool {
        shift != 0 && same(rect, old, new, from: shift)
    }

    private static func same(_ rect: PixelRect, _ old: PixelTiles, _ new: PixelTiles, from shift: Int) -> Bool {
        guard let r = rect.clipped(to: new.bounds), r == rect else { return false }
        guard r.y + shift >= 0, r.bottom + shift <= old.height else { return false }
        let c0 = r.x / PixelTiles.tileWidth, c1 = (r.right - 1) / PixelTiles.tileWidth
        for y in r.y..<r.bottom {
            for c in c0...c1 where new.at(y, c) != old.at(y + shift, c) { return false }
        }
        return true
    }
}
