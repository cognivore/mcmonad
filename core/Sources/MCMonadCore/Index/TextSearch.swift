import Foundation
import CoreGraphics

/// Pure text helpers shared by the screen index, the launcher's window
/// search and the "where is" flow. Foundation only, so the Nix checkPhase
/// can compile and exercise them without AppKit or Vision.
enum TextSearch {

    // MARK: - Query terms

    /// Words too common to locate anything on their own.
    static let stopwords: Set<String> = [
        "a", "an", "the", "is", "are", "was", "were", "be", "my", "our", "of",
        "to", "in", "on", "at", "it", "that", "this", "where", "for", "and",
        "or", "with", "i", "s", "did", "do", "put", "thing", "stuff",
    ]

    /// The words of a query worth matching: lowercased, two or more
    /// characters, punctuation trimmed, stopwords dropped. Preserves order and
    /// removes duplicates so highlight passes stay cheap.
    static func terms(_ query: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "_" && $0 != "." }) {
            let word = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
            guard word.count >= 2, !stopwords.contains(word), !seen.contains(word) else { continue }
            seen.insert(word)
            out.append(word)
        }
        return out
    }

    // MARK: - Full-text hits

    /// One window's text matched a query: a short excerpt around the first
    /// term, with the UTF-16 ranges of every term inside that excerpt, ready
    /// for an attributed string.
    struct Hit: Equatable {
        let snippet: String
        let ranges: [NSRange]
    }

    /// A hit when every term occurs somewhere in `text` (case-insensitive
    /// substring). `lower` is `text.lowercased()`, precomputed by the owner
    /// because it is the expensive part and the index keeps it. Returns nil
    /// when any term is absent, and nil for an empty term list: a query with
    /// nothing to look for has not found anything.
    static func hit(terms: [String], in text: String, lower: String, context: Int = 56) -> Hit? {
        guard !terms.isEmpty else { return nil }
        for term in terms where !lower.contains(term.lowercased()) { return nil }
        let ns = text as NSString
        let first = ns.range(of: terms[0], options: [.caseInsensitive, .diacriticInsensitive])
        guard first.location != NSNotFound else { return nil }
        // The line the first term sits on, clamped to `context` UTF-16 units
        // either side of it so a long terminal line does not swallow the row.
        var line = ns.lineRange(for: first)
        let trimmedEnd = ns.rangeOfCharacter(from: .newlines, options: [], range: line)
        if trimmedEnd.location != NSNotFound {
            line = NSRange(location: line.location, length: trimmedEnd.location - line.location)
        }
        let start = max(line.location, first.location - context)
        let end = min(NSMaxRange(line), NSMaxRange(first) + context)
        let window = NSRange(location: start, length: max(0, end - start))
        var snippet = ns.substring(with: window).trimmingCharacters(in: .whitespaces)
        if start > line.location { snippet = "…" + snippet }
        if end < NSMaxRange(line) { snippet += "…" }
        return Hit(snippet: snippet, ranges: ranges(of: terms, in: snippet))
    }

    /// Every occurrence of every term in `text`, as UTF-16 ranges, sorted and
    /// merged so overlapping terms ("deploy", "deployment") highlight once.
    static func ranges(of terms: [String], in text: String) -> [NSRange] {
        let ns = text as NSString
        var found: [NSRange] = []
        for term in terms where !term.isEmpty {
            var cursor = NSRange(location: 0, length: ns.length)
            while cursor.length > 0 {
                let r = ns.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: cursor)
                guard r.location != NSNotFound, r.length > 0 else { break }
                found.append(r)
                let next = NSMaxRange(r)
                cursor = NSRange(location: next, length: ns.length - next)
            }
        }
        found.sort { $0.location != $1.location ? $0.location < $1.location : $0.length > $1.length }
        var merged: [NSRange] = []
        for r in found {
            if let last = merged.last, r.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, r)
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    // MARK: - Vision output

    /// Vision observations to lines in reading order: observations whose
    /// centres fall within half a line height of each other are one line,
    /// left to right; lines run top to bottom. Boxes are Vision's normalised
    /// bottom-left-origin rectangles. Ported from understudy's `Sight.ordered`.
    static func readingOrder(_ observations: [(CGRect, String)]) -> [String] {
        var rows: [[(CGRect, String)]] = []
        for item in observations.sorted(by: { $0.0.midY > $1.0.midY }) {
            if let last = rows.last?.first,
               abs(last.0.midY - item.0.midY) < min(last.0.height, item.0.height) / 2 {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
            }
        }
        return rows.map { row in
            row.sorted { $0.0.minX < $1.0.minX }.map { $0.1 }.joined(separator: " ")
        }
    }

    // MARK: - Excerpts

    /// Whitespace-collapsed, length-capped text for the "where is" manifold.
    /// A cap of zero or less yields an empty string.
    static func excerpt(_ text: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        if collapsed.count <= limit { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }
}
