import Foundation

/// "What's up": one terse sentence per present workspace, each with the
/// evidence the model used, so the user can see why the summary should be
/// believed. Pure; the shared machinery is in `Ask`.
enum WhatsUp {
    /// The phrases that ask it, typed or spoken. Trailing punctuation and a
    /// continuation ("what's up on my desks") are fine.
    private static let triggers = ["what's up", "whats up", "what is up", "sup"]

    static func matches(_ text: String) -> Bool {
        let core = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "?!."))
            .trimmingCharacters(in: .whitespaces)
        return triggers.contains { core == $0 || core.hasPrefix($0 + " ") }
    }

    static let question = "What's up on every workspace?"

    /// The instruction carries the gist of the user's caveman style — terse,
    /// substance only, structured — not the whole skill.
    static let systemPrompt = """
    You summarise a tiling window manager's workspaces on macOS. You receive a JSON manifold: every \
    workspace that has windows (its tag, whether it is on screen right now) and each window on it \
    (numeric id, app, title, whether it is focused, and — when available — text recognised from the \
    window's pixels). For EVERY workspace in the manifold answer with its tag, a summary of what is \
    going on there, and a reason: the evidence (title words or fragments of recognised text) that \
    makes the summary right. Summary and reason are at most one sentence each. Skip no workspace, \
    invent none, use only tags from the manifold.
    Style: caveman. Terse like smart caveman; all substance stays, only fluff dies. Drop articles, \
    filler, hedging, pleasantries. Fragments fine. Never add words to sound caveman. Structured \
    output only.
    """

    /// The structured-output contract. `tag` is the workspace tag from the manifold.
    static let schemaJSON = #"""
    {"type":"object","properties":{"workspaces":{"type":"array","items":{"type":"object","properties":{"tag":{"type":"string"},"summary":{"type":"string"},"reason":{"type":"string"}},"required":["tag","summary","reason"]}}},"required":["workspaces"]}
    """#

    static let arguments = Ask.arguments(schema: schemaJSON, systemPrompt: systemPrompt)

    struct Summary: Equatable {
        let tag: String
        let summary: String
        let reason: String
    }

    /// The model's `structured_output` as summaries of workspaces we have.
    /// Tags outside the manifold, and repeats, are dropped and counted.
    static func answer(from structured: [String: Any], knownTags: Set<String>) -> Ask.Answer? {
        guard let raw = structured["workspaces"] as? [[String: Any]] else { return nil }
        var summaries: [Summary] = []
        var dropped = 0
        var seen = Set<String>()
        for w in raw {
            guard let tag = w["tag"] as? String, let summary = w["summary"] as? String,
                  let reason = w["reason"] as? String,
                  knownTags.contains(tag), !seen.contains(tag)
            else { dropped += 1; continue }
            seen.insert(tag)
            summaries.append(Summary(tag: tag, summary: summary, reason: reason))
        }
        return .workspaces(summaries: summaries, droppedUnknownTags: dropped)
    }

    static func parseLine(_ line: String, knownTags: Set<String>) -> Ask.StreamItem {
        Ask.parseLine(line) { answer(from: $0, knownTags: knownTags) }
    }
}
