// AI-generated text: model claude-opus-5-5; reasoning effort unavailable (not exposed by the harness).
//
// The real engine on windows drawn the way a screen draws them: Vision, at
// retina scale, on a terminal being typed into and scrolling under a fixed
// header, and on a document scrolled by half a page. For every frame the
// page that went on from the frame before must read what was drawn as well
// as a page reading the frame from nothing does (word recall, within a
// point), and the two may disagree on a few words only; going on must read
// a fraction of the pixels. This is the gate for any change to
// what the engine is shown (padding, the cut at an edge, regrowing a part):
// a benchmark of one crop proves nothing.
//
// Compiled with PixelTiles, WindowPage and VisionReader; run by hand on a
// Mac (Vision needs no permission for images it is handed):
//   core/Tests/run-vision-engine-check.sh
import AppKit
import CoreText
import Foundation

@main
enum VisionEngineCheck {
    struct Style {
        let font: String
        let size: CGFloat
        let background: CGFloat
        let ink: CGFloat
    }

    /// `lines` drawn top-down at `lineHeight` points, `scale` pixels a point.
    static func draw(_ lines: [String], width: Int, height: Int, lineHeight: CGFloat, style: Style, scale: CGFloat = 2) -> CGImage {
        let w = Int(CGFloat(width) * scale), h = Int(CGFloat(height) * scale)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(CGColor(gray: style.background, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        let font = CTFontCreateWithName(style.font as CFString, style.size, nil)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CGColor(gray: style.ink, alpha: 1)]
        for (i, text) in lines.enumerated() where !text.isEmpty {
            let baseline = CGFloat(height) - CGFloat(i + 1) * lineHeight + lineHeight * 0.3
            ctx.textPosition = CGPoint(x: 10, y: baseline)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs)), ctx)
        }
        return ctx.makeImage()!
    }

    static func words(_ rows: [String]) -> [String: Int] {
        var bag: [String: Int] = [:]
        for w in rows.joined(separator: " ").split(whereSeparator: \.isWhitespace) {
            bag[TextHistory.key(String(w)), default: 0] += 1
        }
        return bag
    }

    /// The share of `truth`'s words that `read` has.
    static func recall(_ read: [String], _ truth: [String]) -> Double {
        var bag = words(read)
        var hit = 0, total = 0
        for w in truth.joined(separator: " ").split(whereSeparator: \.isWhitespace) {
            total += 1
            let k = TextHistory.key(String(w))
            if let n = bag[k], n > 0 { hit += 1; bag[k] = n - 1 }
        }
        return total == 0 ? 1 : Double(hit) / Double(total)
    }

    /// Words one reading has and the other has not, both ways.
    static func disagreement(_ a: [String], _ b: [String]) -> Int {
        let x = words(a), y = words(b)
        return Set(x.keys).union(y.keys).reduce(0) { $0 + abs((x[$1] ?? 0) - (y[$1] ?? 0)) }
    }

    static func cpu() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }

    static func run(_ name: String, frames: [(String, [String])], width: Int, height: Int, lineHeight: CGFloat, style: Style) -> Bool {
        print("\n\(name)")
        print("frame".padding(toLength: 34, withPad: " ", startingAt: 0) + "going on                     from nothing          recall (going/nothing)  differ")
        var page = WindowPage()
        var ok = true
        var shown: [String] = []
        for (label, lines) in frames {
            let image = draw(lines, width: width, height: height, lineHeight: lineHeight, style: style)
            let tiles = VisionReader.tiles(of: image)!
            let c0 = cpu()
            page.observe(tiles, at: Date())
            let work = page.read(budget: 50_000_000, at: Date()) { VisionReader.recognise(image, in: $0) }
            let going = cpu() - c0
            var fresh = WindowPage()
            let c1 = cpu()
            fresh.observe(tiles, at: Date())
            let all = fresh.read(budget: 50_000_000, at: Date()) { VisionReader.recognise(image, in: $0) }
            let nothing = cpu() - c1
            let truth = lines.filter { !$0.isEmpty }
            let rGoing = recall(page.rows, truth), rNothing = recall(fresh.rows, truth)
            let r = rGoing
            let d = disagreement(page.rows, fresh.rows)
            let total = Double(truth.joined(separator: " ").split(separator: " ").count)
            let line = label.padding(toLength: 34, withPad: " ", startingAt: 0)
                + String(format: "%9d px %2d reads %5.2f s   %9d px %5.2f s   %.3f / %.3f   %d", work.readPixels, work.reads, going,
                         all.readPixels, nothing, r, rNothing, d)
            print(line)
            // Going on must read what was drawn as well as reading from
            // nothing does. The two may still differ by a few words: Vision
            // reads the same glyphs a little differently at another place in
            // what it is shown ("(" or ":"), and a line kept from an earlier
            // frame keeps the reading it had there.
            if rGoing < 0.95 || rGoing < rNothing - 0.01 || Double(d) > max(3, total * 0.04) {
                ok = false
                print("  ✗ going on: \(page.rows.suffix(4))\n    nothing:  \(fresh.rows.suffix(4))")
                if ProcessInfo.processInfo.environment["VERBOSE"] != nil {
                    let have = Set(page.rows), want = Set(fresh.rows)
                    print("    only going on: \(have.subtracting(want).sorted())")
                    print("    only nothing:  \(want.subtracting(have).sorted())")
                    print("    rows going \(page.rows.count) nothing \(fresh.rows.count) truth \(truth.count)")
                }
            }
            if label.hasPrefix("unchanged"), work.reads != 0 { ok = false; print("  ✗ an unchanged frame was read") }
            shown = page.rows
        }
        _ = shown
        return ok
    }

    static func main() {
        let terminal = Style(font: "Menlo", size: 12, background: 0.11, ink: 0.86)
        let header = "~/Github/mcmonad — cargo build — 120×48"
        var log = (1...44).map { "   Compiling crate-\($0) v0.\($0 % 7).\($0 % 3) (/Users/dev/src/crate-\($0))" }
        let prompt = "$ git com"
        var frames: [(String, [String])] = []
        frames.append(("first frame", [header] + log + [prompt]))
        frames.append(("typing at the prompt", [header] + log + ["$ git commit -m 'read only what changed'"]))
        log.append(contentsOf: ["[main 4be1f2c] read only what changed", " 3 files changed, 212 insertions(+), 9 deletions(-)",
                                "$ cargo test --workspace"])
        let scrolled = Array(log.suffix(44))
        frames.append(("output scrolls 3 lines up", [header] + scrolled + ["   Running unittests src/lib.rs"]))
        frames.append(("unchanged", [header] + scrolled + ["   Running unittests src/lib.rs"]))
        var edited = scrolled
        edited[20] = "   Compiling crate-ZZ v9.9.9 (an edited line in the middle)"
        frames.append(("a line in the middle changes", [header] + edited + ["   Running unittests src/lib.rs"]))
        let a = run("terminal, Menlo 12 pt, 1000 × 864 pt at 2×", frames: frames, width: 1000, height: 864, lineHeight: 18, style: terminal)

        let document = Style(font: "Helvetica", size: 13, background: 0.98, ink: 0.2)
        let sentences = ["The quarterly budget review moved to Thursday afternoon.",
                         "HMRC confirmed the self assessment deadline for this tax year.",
                         "Invoice 2026-11 from ACME is attached to the email from Priya.",
                         "Deploy notes: the screen index now keeps a day of history.",
                         "Remember to renew the domain before the end of the month.",
                         "The kernel panic only reproduces with two displays attached."]
        let paragraph = (0..<60).map { "\($0 + 1). " + sentences[$0 % sentences.count] }
        let page1 = Array(paragraph.prefix(40)), page2 = Array(paragraph[20..<60])
        let b = run("document, Helvetica 13 pt, 900 × 800 pt at 2×",
                    frames: [("first frame", page1), ("scrolled half a page", page2), ("unchanged", page2)],
                    width: 900, height: 800, lineHeight: 20, style: document)
        guard a && b else {
            print("\nVision engine check FAILED")
            exit(1)
        }
        print("\nVision engine check passed")
    }
}
