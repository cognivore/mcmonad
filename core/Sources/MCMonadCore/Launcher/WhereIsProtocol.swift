import Foundation

/// The pure half of "where is …": recognising the question and sorting the
/// model's answer into windows we have. The shared machinery is in `Ask`.

/// A parsed "where is …" question. Only constructible from text that really
/// asks one, so downstream code never re-checks the prefix.
struct WhereIsQuery: Equatable {
    /// The part after "where is", original case, trimmed.
    let question: String

    private static let prefixes = [
        "where is ", "where's ", "wheres ", "where are ", "where was ", "where were ",
        "where did i put ", "where did i leave ", "where do i have ",
    ]

    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard let prefix = Self.prefixes.first(where: { lower.hasPrefix($0) }) else { return nil }
        let rest = String(trimmed.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "?.!"))
            .trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        question = rest
    }

    var terms: [String] { TextSearch.terms(question) }
}

enum WhereIs {
    static let systemPrompt = """
    You locate windows for a tiling window manager on macOS. The user asks where something is. \
    You receive a JSON manifold: every workspace (its tag, whether it is on screen right now) and \
    every window on it (numeric id, app, title, whether it is focused, and — when available — text \
    recognised from the window's pixels). Answer with the windows that best answer the question, \
    most likely first, at most 8. For each give a one-sentence reason that quotes the evidence you \
    used: the title words or the fragment of recognised text. Only use ids that appear in the \
    manifold. If nothing fits, return an empty list.
    """

    /// The structured-output contract. `id` is the window id from the manifold.
    static let schemaJSON = #"""
    {"type":"object","properties":{"matches":{"type":"array","items":{"type":"object","properties":{"id":{"type":"integer"},"reason":{"type":"string"}},"required":["id","reason"]}}},"required":["matches"]}
    """#

    static let arguments = Ask.arguments(schema: schemaJSON, systemPrompt: systemPrompt)

    struct Match: Equatable {
        let windowId: UInt32
        let reason: String
    }

    /// The model's `structured_output` as windows we have. `known` is the
    /// manifold's window ids; matches naming anything else are dropped and
    /// counted rather than shown as windows we do not have.
    static func answer(from structured: [String: Any], known: Set<UInt32>) -> Ask.Answer? {
        guard let raw = structured["matches"] as? [[String: Any]] else { return nil }
        var matches: [Match] = []
        var dropped = 0
        var seen = Set<UInt32>()
        for m in raw {
            guard let idNum = m["id"] as? NSNumber, let reason = m["reason"] as? String else {
                dropped += 1
                continue
            }
            let id64 = idNum.int64Value
            guard id64 >= 0, id64 <= Int64(UInt32.max) else { dropped += 1; continue }
            let id = UInt32(id64)
            guard known.contains(id), !seen.contains(id) else { dropped += 1; continue }
            seen.insert(id)
            matches.append(Match(windowId: id, reason: reason))
        }
        return .windows(matches: matches, droppedUnknownIds: dropped)
    }

    static func parseLine(_ line: String, known: Set<UInt32>) -> Ask.StreamItem {
        Ask.parseLine(line) { answer(from: $0, known: known) }
    }
}
