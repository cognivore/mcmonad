import Foundation

/// Order-preserving subsequence fuzzy matcher, shared by the Spotlight
/// launcher's app/command/window filtering. Extracted from the original
/// window-search controller so the launcher index and the panel rank the
/// same way.
enum FuzzyMatch {
    /// Returns nil when `query` is not a subsequence of `haystack`;
    /// otherwise a score rewarding contiguous runs and earlier matches.
    /// Both arguments are expected to be lowercased by the caller.
    static func score(query: String, in haystack: String) -> Int? {
        let hs = Array(haystack)
        let qs = Array(query)
        if qs.isEmpty { return 0 }
        var hi = 0
        var score = 0
        var streak = 0
        for qc in qs {
            var matched = false
            while hi < hs.count {
                let hc = hs[hi]
                hi += 1
                if hc == qc {
                    streak += 1
                    // Contiguous matches and matches near the start score higher.
                    score += 10 + streak * 5 + max(0, 20 - hi)
                    matched = true
                    break
                } else {
                    streak = 0
                }
            }
            if !matched { return nil }
        }
        return score
    }
}
