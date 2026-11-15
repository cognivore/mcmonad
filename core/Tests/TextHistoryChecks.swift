// AI-generated text: model claude-opus-5-5; reasoning effort unavailable (not exposed by the harness).
//
// Compiled with the index's pure files (PixelTiles, WindowPage, TextHistory,
// GlancePolicy, TextSearch) and run by the Nix package checkPhase.
//
// The page is checked the way ocr-predictor checks its screen: on a drawn
// window whose engine reads exactly what the test drew, and reads nonsense
// where a crop cut a line. Generated histories (text typed, rubbed out,
// replaced, scrolled under a fixed header; reads given little or much) must
// end where reading the window from nothing ends, and every unchanged look
// must read nothing.
import Foundation

@main
enum TextHistoryChecks {
    static func main() {
        checkRects()
        checkTilesAndScroll()
        checkFirstReadAndQuiet()
        checkTypingReadsOneLine()
        checkScrollReadsOnlyWhatScrolledIn()
        checkBudgetCarriesUnread()
        checkResizeStartsOver()
        checkRegrowthCarriesOver()
        checkGeneratedHistories()
        checkHistoryKeysAndRecords()
        checkHistoryPrune()
        checkEvidence()
        checkPulseAndPolicy()
        print("Text history checks passed")
    }

    // MARK: - A drawn window

    struct Drawn: Equatable {
        var row: Int
        var text: String
    }

    /// A window `rows` text rows tall: each glyph a 9 × 24 block whose bytes
    /// depend on the character and the pixel within it, so typing changes
    /// only the new glyphs' pixels and a scrolled line keeps its bytes.
    struct Canvas {
        static let lineHeight = 32, glyph = 9, left = 16
        let width: Int
        let rows: Int
        var lines: [Drawn] = []
        var height: Int { rows * Self.lineHeight }

        func rect(_ l: Drawn) -> PixelRect {
            PixelRect(x: Self.left, y: l.row * Self.lineHeight + 4, w: max(1, l.text.count) * Self.glyph, h: 24)
        }

        func pixels() -> [UInt8] {
            var px = [UInt8](repeating: 0x20, count: width * height * 4)
            for l in lines {
                let r = rect(l)
                let chars = Array(l.text.unicodeScalars)
                for y in r.y..<min(r.bottom, height) {
                    for x in r.x..<min(r.right, width) {
                        let i = (x - r.x) / Self.glyph
                        let c = Int(chars[i].value)
                        let v = UInt8(truncatingIfNeeded: c &* 7 &+ ((x - r.x) % Self.glyph) &* 13 &+ (y - r.y) &* 3 &+ 1)
                        let o = (y * width + x) * 4
                        px[o] = v; px[o + 1] = v &+ 1; px[o + 2] = v &+ 2; px[o + 3] = 255
                    }
                }
            }
            return px
        }

        func tiles() -> PixelTiles {
            let px = pixels()
            return px.withUnsafeBytes { PixelTiles(pixels: $0.baseAddress!, width: width, height: height, bytesPerRow: width * 4) }
        }

        /// The engine: every drawn line wholly inside `sample` is read as
        /// drawn; a line the sample cuts is read as nonsense, clipped.
        func engine(_ sample: PixelRect) -> Result<[FoundLine], ReadFault> {
            var out: [FoundLine] = []
            for l in lines {
                let r = rect(l)
                guard let inside = r.clipped(to: sample) else { continue }
                let local = PixelRect(x: inside.x - sample.x, y: inside.y - sample.y, w: inside.w, h: inside.h)
                out.append(FoundLine(rect: local, text: inside == r ? l.text : "#cut#", confidence: 1))
            }
            return .success(out)
        }

        var truth: [String] {
            lines.sorted { $0.row < $1.row }.map(\.text)
        }
    }

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// Observe the canvas and read with `budget`; the page and what it cost.
    @discardableResult
    static func look(_ page: inout WindowPage, _ canvas: Canvas, budget: Int = 50_000_000, at: Date = t0) -> GlanceWork {
        page.observe(canvas.tiles(), at: at)
        return page.read(budget: budget, at: at, engine: canvas.engine)
    }

    // MARK: - Geometry

    static func checkRects() {
        let a = PixelRect(x: 0, y: 0, w: 10, h: 10), b = PixelRect(x: 10, y: 0, w: 5, h: 5)
        precondition(!a.meets(b) && a.with(b) == PixelRect(x: 0, y: 0, w: 15, h: 10))
        precondition(a.grown(4, within: PixelRect(x: 0, y: 0, w: 12, h: 100)) == PixelRect(x: 0, y: 0, w: 12, h: 14))
        precondition(a.centres(PixelRect(x: 2, y: 2, w: 4, h: 4)) && !a.centres(PixelRect(x: 8, y: 8, w: 6, h: 6)))
        precondition(a.clipped(to: PixelRect(x: 20, y: 20, w: 2, h: 2)) == nil)
        precondition(WindowPage.rows([
            PageLine(rect: PixelRect(x: 50, y: 10, w: 20, h: 20), text: "world", confidence: 1, readAt: t0),
            PageLine(rect: PixelRect(x: 0, y: 12, w: 20, h: 20), text: "hello", confidence: 1, readAt: t0),
            PageLine(rect: PixelRect(x: 0, y: 60, w: 20, h: 20), text: "next", confidence: 1, readAt: t0),
        ]) == ["hello world", "next"])
    }

    static func checkTilesAndScroll() {
        var c = Canvas(width: 700, rows: 20)
        c.lines = (0..<20).map { Drawn(row: $0, text: "line number \($0) of the log") }
        let before = c.tiles()
        precondition(before.columns == 6 && before.hashes.count == 6 * c.height)
        precondition(PixelChange.between(before, c.tiles()) == PixelChange(shift: 0, damage: []))
        // Scroll up by three rows; three new lines come in at the bottom.
        c.lines = (3..<23).map { Drawn(row: $0 - 3, text: "line number \($0) of the log") }
        let after = c.tiles()
        let change = PixelChange.between(before, after)!
        precondition(change.shift == 3 * Canvas.lineHeight, "shift \(change.shift)")
        precondition(change.damage.count == 1 && change.damage[0].y >= 17 * Canvas.lineHeight - PixelChange.rowGap,
                     "\(change.damage)")
        // Another size is another picture.
        precondition(PixelChange.between(before, Canvas(width: 600, rows: 20).tiles()) == nil)
        // A page replaced by unrelated text is not a scroll.
        c.lines = (0..<20).map { Drawn(row: $0, text: "entirely different text \($0 * 7)") }
        precondition(PixelChange.between(after, c.tiles())!.shift == 0)
    }

    // MARK: - The page

    static func checkFirstReadAndQuiet() {
        var c = Canvas(width: 800, rows: 12)
        c.lines = [Drawn(row: 0, text: "Ghostty"), Drawn(row: 2, text: "cargo build --release"), Drawn(row: 3, text: "Finished in 3.2s")]
        var page = WindowPage()
        let first = look(&page, c)
        precondition(page.rows == c.truth && page.isFullyRead, "\(page.rows)")
        precondition(first.newRows == c.truth && first.reads == 1)
        let quiet = look(&page, c)
        precondition(quiet.reads == 0 && quiet.readPixels == 0 && quiet.newRows.isEmpty, "an unchanged window reads nothing")
    }

    static func checkTypingReadsOneLine() {
        var c = Canvas(width: 1600, rows: 30)
        c.lines = (0..<20).map { Drawn(row: $0, text: "an earlier line of output, number \($0)") }
        c.lines.append(Drawn(row: 20, text: "$ git com"))
        var page = WindowPage()
        look(&page, c)
        c.lines[20].text = "$ git commit -m 'scroll moves lines'"
        let typed = look(&page, c)
        precondition(page.rows == c.truth)
        precondition(typed.reads == 1 && typed.readPixels < 1600 * 80, "typing read \(typed.readPixels) px")
        precondition(typed.newRows == ["$ git commit -m 'scroll moves lines'"] && typed.replacedRows == ["$ git com"])
        // An edit in the middle of a line reads that line whole.
        c.lines[5].text = "an earlier line of OUTPUT, number 5"
        let edit = look(&page, c)
        precondition(page.rows == c.truth && edit.newRows == ["an earlier line of OUTPUT, number 5"], "\(edit.newRows)")
    }

    static func checkScrollReadsOnlyWhatScrolledIn() {
        var c = Canvas(width: 1200, rows: 30)
        let header = Drawn(row: 0, text: "~/Github/mcmonad — zsh")
        c.lines = [header] + (1..<30).map { Drawn(row: $0, text: "compiling crate \($0) of the workspace") }
        var page = WindowPage()
        let full = look(&page, c)
        c.lines = [header] + (5..<34).map { Drawn(row: $0 - 4, text: "compiling crate \($0) of the workspace") }
        let scrolled = look(&page, c)
        precondition(page.rows == c.truth, "\(page.rows.suffix(5))")
        precondition(scrolled.readPixels * 4 < full.readPixels, "scroll read \(scrolled.readPixels) of \(full.readPixels)")
        precondition(scrolled.newRows == (30..<34).map { "compiling crate \($0) of the workspace" }, "\(scrolled.newRows)")
    }

    static func checkBudgetCarriesUnread() {
        var c = Canvas(width: 1000, rows: 40)
        c.lines = (0..<40).map { Drawn(row: $0, text: "paragraph \($0) of a long document") }
        var page = WindowPage()
        let first = look(&page, c, budget: 1000 * 300)
        precondition(!page.isFullyRead && first.readPixels <= 1000 * 300, "budget kept: \(first.readPixels)")
        precondition(page.rows.allSatisfy { !$0.contains("#cut#") } && page.rows == Array(c.truth.prefix(page.rows.count)))
        var looks = 1
        while !page.isFullyRead {
            look(&page, c, budget: 1000 * 300)
            looks += 1
            precondition(looks < 20, "unread never finished")
        }
        precondition(page.rows == c.truth)
        // A failing engine leaves its part unread and says why.
        var p2 = WindowPage()
        p2.observe(c.tiles(), at: t0)
        let failed = p2.read(budget: 10_000_000, at: t0) { _ in .failure(ReadFault(reason: "busy")) }
        precondition(failed.fault == ReadFault(reason: "busy") && !p2.isFullyRead && p2.lines.isEmpty)
    }

    static func checkResizeStartsOver() {
        var c = Canvas(width: 800, rows: 10)
        c.lines = [Drawn(row: 1, text: "before the resize")]
        var page = WindowPage()
        look(&page, c)
        var wider = Canvas(width: 900, rows: 10)
        wider.lines = [Drawn(row: 2, text: "after the resize")]
        precondition(page.observe(wider.tiles(), at: t0) == nil && page.lines.isEmpty && page.unread == [wider.tiles().bounds])
    }

    /// A change lower than the line it is in (no line known there) cuts the
    /// line at the read's top; the part regrows. When the grown part does
    /// not fit what is left of the look, what was read is kept and the grown
    /// part is read next time, not thrown away and read again for ever.
    static func checkRegrowthCarriesOver() {
        let width = 1000, height = 400
        func tiles(_ changed: ClosedRange<Int>?) -> PixelTiles {
            let columns = PixelTiles.columns(for: width)
            var hashes = [UInt32](repeating: 0, count: columns * height)
            if let changed { for y in changed { for c in 0..<columns { hashes[y * columns + c] = 1 } } }
            return PixelTiles(width: width, height: height, columns: columns, hashes: hashes)
        }
        let line = PixelRect(x: 20, y: 100, w: 600, h: 24)
        var shown = false
        let engine: (PixelRect) -> Result<[FoundLine], ReadFault> = { sample in
            guard shown, let inside = line.clipped(to: sample) else { return .success([]) }
            let local = PixelRect(x: inside.x - sample.x, y: inside.y - sample.y, w: inside.w, h: inside.h)
            return .success([FoundLine(rect: local, text: inside == line ? "the whole line" : "#cut#", confidence: 1)])
        }
        var page = WindowPage()
        page.observe(tiles(nil), at: t0)
        _ = page.read(budget: 1_000_000, at: t0, engine: engine)
        precondition(page.isFullyRead && page.lines.isEmpty)
        shown = true
        page.observe(tiles(122...123), at: t0)   // only the line's lowest rows changed
        let first = page.read(budget: 60_000, at: t0, engine: engine)
        precondition(first.reads == 1 && !page.isFullyRead, "\(first)")
        precondition(page.unread.contains { $0.y <= line.y && $0.bottom >= line.bottom }, "the grown part is unread: \(page.unread)")
        var looks = 1
        while !page.isFullyRead {
            page.observe(tiles(122...123), at: t0)
            _ = page.read(budget: 60_000, at: t0, engine: engine)
            looks += 1
            precondition(looks < 6, "the line was never read whole: \(page.unread)")
        }
        precondition(page.rows == ["the whole line"], "\(page.rows)")
    }

    /// A small deterministic generator, so a failing history can be replayed.
    struct Lcg {
        var s: UInt64
        mutating func next(_ n: Int) -> Int {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Int((s >> 33) % UInt64(n))
        }
    }

    static func checkGeneratedHistories() {
        let cases = Int(ProcessInfo.processInfo.environment["TEXT_HISTORY_CASES"] ?? "") ?? 200
        let words = ["deploy", "invoice", "rust", "swift", "HMRC", "tax", "window", "kernel", "budget", "notes", "cat", "PR"]
        for seed in 0..<cases {
            var rng = Lcg(s: UInt64(seed) &* 2654435761 &+ 17)
            var c = Canvas(width: 640 + 64 * rng.next(8), rows: 12 + rng.next(14))
            let header = rng.next(2) == 0 ? Drawn(row: 0, text: "header \(seed)") : nil
            func phrase() -> String { (0..<(1 + rng.next(5))).map { _ in words[rng.next(words.count)] }.joined(separator: " ") }
            c.lines = (header.map { [$0] } ?? [])
            var page = WindowPage()
            var steps: [String] = []
            for step in 0..<12 {
                let first = header == nil ? 0 : 1
                switch rng.next(5) {
                case 0:   // type on a line, or start one
                    if let i = c.lines.indices.filter({ c.lines[$0].row >= first }).randomPick(&rng) {
                        c.lines[i].text += " " + phrase()
                        c.lines[i].text = String(c.lines[i].text.prefix((c.width - 40) / Canvas.glyph))
                    } else {
                        c.lines.append(Drawn(row: first, text: phrase()))
                    }
                    steps.append("type")
                case 1:   // rub a line out
                    if let i = c.lines.indices.filter({ c.lines[$0].row >= first }).randomPick(&rng) { c.lines.remove(at: i) }
                    steps.append("erase")
                case 2:   // write a new line on a free row
                    let free = (first..<c.rows).filter { r in !c.lines.contains { $0.row == r } }
                    if let r = free.randomPick(&rng) { c.lines.append(Drawn(row: r, text: phrase())) }
                    steps.append("write")
                case 3:   // scroll under the header
                    let k = 1 + rng.next(4)
                    c.lines = c.lines.compactMap { l in
                        guard l.row >= first else { return l }
                        return l.row - k >= first ? Drawn(row: l.row - k, text: l.text) : nil
                    }
                    for r in (c.rows - k)..<c.rows where rng.next(3) > 0 { c.lines.append(Drawn(row: r, text: phrase())) }
                    steps.append("scroll \(k)")
                default:  // nothing changed
                    steps.append("still")
                }
                let budget = rng.next(3) == 0 ? c.width * (200 + rng.next(300)) : 50_000_000
                let wasRead = page.isFullyRead
                let work = look(&page, c, budget: budget, at: t0.addingTimeInterval(Double(step)))
                precondition(page.rows.allSatisfy { !$0.contains("#cut#") }, "seed \(seed) kept a cut line after \(steps)")
                if steps.last == "still", wasRead {
                    precondition(work.reads == 0, "seed \(seed): an unchanged, fully read window was read again")
                }
                if page.isFullyRead {
                    precondition(page.rows == c.truth, "seed \(seed) after \(steps): \(page.rows) != \(c.truth)")
                }
            }
            // Going on ends where reading from nothing does.
            var settle = 0
            while !page.isFullyRead { look(&page, c); settle += 1; precondition(settle < 5) }
            var fresh = WindowPage()
            look(&fresh, c)
            precondition(page.rows == fresh.rows && fresh.rows == c.truth, "seed \(seed) after \(steps)")
        }
    }

    // MARK: - History

    static func checkHistoryKeysAndRecords() {
        precondition(TextHistory.key("  Invoice   NO. 1O ") == "lnvolce no. lo", TextHistory.key("  Invoice   NO. 1O "))
        precondition(TextHistory.key("I l 1 |") == TextHistory.key("l 1 I |"))
        precondition(!TextHistory.meaningful("$ >") && !TextHistory.meaningful("12") && TextHistory.meaningful("ls -la"))
        var h = TextHistory()
        h.noteWindows([(7, "Ghostty", "deploy notes", "3")], at: t0)
        h.record(7, rows: ["$ git com", ">"], replaced: [], at: t0)
        h.record(7, rows: ["$ git commit -m 'x'"], replaced: ["$ git com"], at: t0.addingTimeInterval(120))
        let w = h.windows[7]!
        let screen = w.sightings.filter { $0.kind == .screen }
        precondition(screen.count == 1 && screen[0].text == "$ git commit -m 'x'" && screen[0].firstSeen == t0
                     && screen[0].lastSeen == t0.addingTimeInterval(120), "\(screen)")
        precondition(w.sightings.filter { $0.kind == .title }.map(\.text) == ["deploy notes"])
        // The same line read again is one sighting, seen later.
        h.touch(7, rows: ["$ GIT COMMIT  -m 'x'"], at: t0.addingTimeInterval(600))
        precondition(h.windows[7]!.sightings.filter { $0.kind == .screen }.count == 1)
        precondition(h.windows[7]!.sightings.first { $0.kind == .screen }!.lastSeen == t0.addingTimeInterval(600))
        // Titles accumulate; a window gone from the snapshot is closed, and
        // reopens if it comes back.
        h.noteWindows([(7, "Ghostty", "cargo test", "3")], at: t0.addingTimeInterval(700))
        precondition(h.windows[7]!.sightings.filter { $0.kind == .title }.map(\.text) == ["deploy notes", "cargo test"])
        h.noteWindows([], at: t0.addingTimeInterval(800))
        precondition(h.windows[7]!.closedAt == t0.addingTimeInterval(800))
        h.noteWindows([(7, "Ghostty", "cargo test", "3")], at: t0.addingTimeInterval(900))
        precondition(h.windows[7]!.closedAt == nil)
        h.noteInput(7, at: t0.addingTimeInterval(910))
        h.noteInput(7, at: t0.addingTimeInterval(920))
        precondition(h.windows[7]!.activeMinutes.count == 1 && h.windows[7]!.lastInput == t0.addingTimeInterval(920))
        // Unknown windows are ignored, not invented.
        h.record(99, rows: ["something"], replaced: [], at: t0)
        precondition(h.windows[99] == nil)
    }

    static func checkHistoryPrune() {
        var h = TextHistory()
        h.noteWindows([(1, "A", "", nil), (2, "B", "", nil)], at: t0)
        h.record(1, rows: ["old line from yesterday"], replaced: [], at: t0)
        let later = t0.addingTimeInterval(TextHistory.keep - 60)
        h.record(1, rows: ["fresh line from today"], replaced: [], at: later)
        h.noteWindows([(1, "A", "", nil)], at: later)   // window 2 closes
        h.prune(now: t0.addingTimeInterval(TextHistory.keep + 1))
        precondition(h.windows[1]!.sightings.map(\.text) == ["fresh line from today"])
        precondition(h.windows[2] != nil, "closed less than a day ago: kept")
        h.prune(now: later.addingTimeInterval(TextHistory.keep + 1))
        precondition(h.windows[2] == nil && h.windows[1]!.sightings.isEmpty)
        // The per-window cap drops the least recently seen.
        var big = TextHistory()
        big.noteWindows([(5, "Log", "", nil)], at: t0)
        for i in 0..<(TextHistory.maxLinesPerWindow + 10) {
            big.record(5, rows: ["log line \(i)"], replaced: [], at: t0.addingTimeInterval(Double(i)))
        }
        big.prune(now: t0.addingTimeInterval(20_000))
        let kept = big.windows[5]!.sightings
        precondition(kept.count == TextHistory.maxLinesPerWindow && kept.first!.text == "log line 10")
        big.touch(5, rows: ["log line 10"], at: t0.addingTimeInterval(30_000))
        precondition(big.windows[5]!.sightings.filter { $0.text == "log line 10" }.count == 1, "index rebuilt after prune")
    }

    static func checkEvidence() {
        let clock: (Date) -> String = { d in
            let m = Int(d.timeIntervalSince(t0) / 60)
            return String(format: "%02d:%02d", 9 + m / 60, m % 60)
        }
        var h = TextHistory()
        h.noteWindows([(1, "Chrome", "Inbox", "2"), (2, "Ghostty", "zsh", "3"), (3, "Notes", "Groceries", "o1")], at: t0)
        h.record(1, rows: ["HMRC self assessment tax return", "Your invoices for October", "unrelated footer text"], replaced: [], at: t0)
        h.record(1, rows: ["now on screen: the inbox"], replaced: [], at: t0.addingTimeInterval(3600))
        h.record(2, rows: ["cargo build", "error: could not compile invoices crate", "warning: unused"], replaced: [], at: t0.addingTimeInterval(60))
        h.record(3, rows: ["milk", "eggs and bread"], replaced: [], at: t0.addingTimeInterval(120))
        h.noteWindows([(1, "Chrome", "Gmail", "2"), (2, "Ghostty", "zsh", "3")], at: t0.addingTimeInterval(4000))   // Notes closed
        h.noteInput(2, at: t0.addingTimeInterval(65))
        let onScreen: (UInt32) -> Set<String> = { id in id == 1 ? [TextHistory.key("now on screen: the inbox")] : [] }
        let (windows, closed) = HistoryEvidence.select(h, windows: [1, 2], onScreen: onScreen,
                                                       terms: ["invoices"], budget: 10_000, clock: clock)
        let chrome = windows[1]!.earlier
        precondition(chrome.contains("09:00 Your invoices for October") && chrome.contains("09:00 title: Inbox"), "\(chrome)")
        precondition(!chrome.contains { $0.contains("now on screen") }, "what is on screen is not 'earlier'")
        precondition(!chrome.contains { $0.contains("title: Gmail") }, "the current title is not 'earlier'")
        precondition(windows[2]!.earlier.contains("09:01 error: could not compile invoices crate"))
        precondition(windows[2]!.lastActive == t0.addingTimeInterval(65) && windows[2]!.activeMinutes == 1)
        precondition(closed.map(\.id) == [3] && closed[0].closedAt == t0.addingTimeInterval(4000)
                     && closed[0].earlier.contains("09:02 eggs and bread"), "\(closed)")
        // A tight budget keeps the matching line, and the lines read beside it.
        let tight = HistoryEvidence.select(h, windows: [1, 2], onScreen: onScreen, terms: ["invoice"], budget: 120, clock: clock)
        let t1 = tight.windows[1]!.earlier
        precondition(t1.contains("09:00 Your invoices for October"), "\(t1)")
        precondition(t1.joined().count + t1.count <= 120 + tight.windows[2]!.earlier.count * 0 + 200)
        // Thirty windows that each match once all get their match: the
        // budget goes by what a window needs, not 6,000 characters each.
        var many = TextHistory()
        let ids = (1...30).map { UInt32($0) }
        many.noteWindows(ids.map { ($0, "App", "", nil) }, at: t0)
        for id in ids {
            many.record(id, rows: ["window \(id) mentions the invoice once"], replaced: [], at: t0)
            // Plenty seen since, so only the budget for matches can carry it.
            many.record(id, rows: (0..<12).map { "later unrelated line number \($0) of window \(id)" }, replaced: [],
                        at: t0.addingTimeInterval(600))
        }
        let spread = HistoryEvidence.select(many, windows: ids, onScreen: { _ in [] }, terms: ["invoice"], budget: 10_000, clock: clock)
        precondition(ids.allSatisfy { id in spread.windows[id]!.earlier.contains { $0.contains("window \(id) mentions") } },
                     "a matching window lost its match")
        // Spans and plurals.
        var s = TextHistory.Sighting(kind: .screen, text: "x", key: "x", firstSeen: t0, lastSeen: t0.addingTimeInterval(300), order: 1)
        precondition(HistoryEvidence.format(s, clock: clock) == "09:00–09:05 x")
        s.lastSeen = t0
        precondition(HistoryEvidence.format(s, clock: clock) == "09:00 x")
        precondition(HistoryEvidence.variants("invoices").map(\.needle) == ["lnvolces", "lnvolc", "lnvolce"])
    }

    // MARK: - When to look

    static func checkPulseAndPolicy() {
        var p = InputPulse()
        precondition(p.note(.init(keys: 100, clicks: 10, scrolls: 1000), at: t0) == 0, "a first sample scores nothing")
        precondition(p.note(.init(keys: 110, clicks: 11, scrolls: 1016), at: t0.addingTimeInterval(5)) == 10 + 4 + 2)
        precondition(!InputPulse.isIntense(16))
        let score = p.note(.init(keys: 120, clicks: 11, scrolls: 1016), at: t0.addingTimeInterval(10))
        precondition(score == 26 && InputPulse.isIntense(score))
        precondition(p.note(.init(keys: 120, clicks: 11, scrolls: 1016), at: t0.addingTimeInterval(38)) == 10, "old input ages out")
        // Wrapped counters still count forwards.
        var w = InputPulse()
        _ = w.note(.init(keys: UInt32.max - 1, clicks: 0, scrolls: 0), at: t0)
        precondition(w.note(.init(keys: 3, clicks: 0, scrolls: 0), at: t0.addingTimeInterval(5)) == 5)

        var g = GlancePolicy()
        precondition(g.due(at: t0, preferring: 1) == nil, "nothing owed, nothing due")
        g.noteIntense(1, at: t0)
        g.noteIntense(2, at: t0.addingTimeInterval(1))
        precondition(g.due(at: t0.addingTimeInterval(2), preferring: 2) == 2)
        precondition(g.due(at: t0.addingTimeInterval(2), preferring: nil) == 1, "owed longest first")
        precondition(g.due(at: t0.addingTimeInterval(2), preferring: 1, skip: [1]) == 2, "secure input skips its app's windows")
        precondition(g.due(at: t0.addingTimeInterval(2), preferring: 1, skip: [1, 2]) == nil)
        g.noteGlanced(1, at: t0.addingTimeInterval(3))
        g.noteIntense(1, at: t0.addingTimeInterval(10))
        precondition(g.due(at: t0.addingTimeInterval(60), preferring: 1) == 2, "window 1 waits out its N minutes")
        g.noteGlanced(2, at: t0.addingTimeInterval(60))
        precondition(g.due(at: t0.addingTimeInterval(100), preferring: 1) == nil)
        precondition(g.due(at: t0.addingTimeInterval(3 + GlancePolicy.every), preferring: nil) == 1)
        g.keep(only: [2])
        precondition(g.owed.isEmpty && g.lastGlance.keys.sorted() == [2])
    }
}

extension Array {
    func randomPick(_ rng: inout TextHistoryChecks.Lcg) -> Element? {
        isEmpty ? nil : self[rng.next(count)]
    }
}
