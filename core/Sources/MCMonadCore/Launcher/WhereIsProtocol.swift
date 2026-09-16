import Foundation

/// The pure half of "where is …": recognising the question, describing every
/// window to the model, reading the CLI's stream back, and sorting its
/// answer into one of four distinct outcomes. No process handling here (see
/// `WhereIsRunner`), so the Nix checkPhase can compile and test it alone.

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
    /// The model and effort the question goes to. Fable 5.1 at low effort:
    /// this is a lookup over evidence we hand it, not a reasoning task.
    static let model = "claude-fable-5-1"
    static let effort = "low"

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

    /// Arguments after the executable. Print mode with structured output and
    /// a streamed transcript; no tools; no session written to disk — the
    /// prompt carries recognised screen text and must not outlive the call.
    static let arguments: [String] = [
        "-p",
        "--model", model,
        "--effort", effort,
        "--no-session-persistence",
        "--tools", "",
        "--exclude-dynamic-system-prompt-sections",
        "--output-format", "stream-json",
        "--verbose",
        "--include-partial-messages",
        "--json-schema", schemaJSON,
        "--system-prompt", systemPrompt,
    ]

    /// Where the Claude Code CLI may live when the daemon's own PATH (a
    /// launchd agent's, so nearly empty) does not name it.
    static func candidates(home: String, path: String?) -> [String] {
        var dirs = [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        for dir in (path ?? "").split(separator: ":").map(String.init) where !dirs.contains(dir) {
            dirs.append(dir)
        }
        return dirs.map { $0 + "/claude" }
    }

    // MARK: - Manifold (what we tell the model)

    struct ManifoldWindow: Codable, Equatable {
        let id: UInt32
        let app: String
        let title: String
        let focused: Bool
        let text: String?
    }

    struct ManifoldWorkspace: Codable, Equatable {
        let tag: String
        let onScreen: Bool
        let windows: [ManifoldWindow]

        enum CodingKeys: String, CodingKey {
            case tag, onScreen = "on_screen", windows
        }
    }

    struct Manifold: Codable, Equatable {
        let question: String
        let currentWorkspace: String?
        let workspaces: [ManifoldWorkspace]

        enum CodingKeys: String, CodingKey {
            case question, currentWorkspace = "current_workspace", workspaces
        }
    }

    /// Every non-empty workspace, on-screen ones first, each window with an
    /// excerpt of its recognised text. `budget` caps the total excerpt
    /// characters across all windows so the prompt stays one call's worth;
    /// the per-window cap is the budget spread evenly, at most `perWindow`.
    static func manifold(
        question: String,
        snapshot: OverlaySnapshot,
        text: (UInt32) -> String?,
        budget: Int = 80_000,
        perWindow: Int = 1_500
    ) -> Manifold {
        var workspaces: [ManifoldWorkspace] = []
        var pending: [(String, Bool, [OverlayWindowEntry])] = []
        for screen in snapshot.screens where !screen.windows.isEmpty {
            pending.append((screen.workspaceTag, true, screen.windows))
        }
        for ws in snapshot.hiddenWorkspaces where !ws.windows.isEmpty {
            pending.append((ws.tag, false, ws.windows))
        }
        let count = pending.reduce(0) { $0 + $1.2.count }
        let cap = count == 0 ? perWindow : min(perWindow, budget / count)
        for (tag, onScreen, entries) in pending {
            let windows = entries.map { w in
                ManifoldWindow(
                    id: w.windowId,
                    app: w.appName ?? "?",
                    title: w.title ?? "",
                    focused: w.isFocused,
                    text: text(w.windowId).map { TextSearch.excerpt($0, limit: cap) }
                )
            }
            workspaces.append(ManifoldWorkspace(tag: tag, onScreen: onScreen, windows: windows))
        }
        let current = snapshot.screens.first { $0.windows.contains { $0.isFocused } }?.workspaceTag
            ?? snapshot.screens.first?.workspaceTag
        return Manifold(question: question, currentWorkspace: current, workspaces: workspaces)
    }

    static func prompt(for manifold: Manifold) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = (try? encoder.encode(manifold)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "Where is: \(manifold.question)\n\nManifold:\n\(json)"
    }

    // MARK: - Answer (what the model tells us)

    struct Match: Equatable {
        let windowId: UInt32
        let reason: String
    }

    /// The four things a call can come back as. They are kept apart because
    /// the launcher shows each differently: an empty answer is a successful
    /// search that found nothing; the other three are not searches at all.
    enum Outcome: Equatable {
        /// The CLI answered in the schema; unknown ids already dropped.
        case answered(matches: [Match], droppedUnknownIds: Int)
        /// No usable CLI on this machine (looked in the listed places).
        case unavailable(String)
        /// The CLI ran and reported a failure (non-zero exit, API error).
        case failed(String)
        /// The CLI exited cleanly but what it printed is not the contract.
        case malformed(String)
    }

    /// What one stream-json line means for the transcript and the outcome.
    enum StreamItem: Equatable {
        /// Text the model produced so far — the structured answer arrives as
        /// JSON fragments, shown as they come.
        case delta(String)
        /// The final result line.
        case final(Outcome)
        /// Housekeeping we do not show.
        case ignore
    }

    /// Parse one line of `--output-format stream-json`. `known` is the set
    /// of window ids in the manifold; matches naming anything else are
    /// dropped and counted rather than shown as windows we do not have.
    static func parseLine(_ line: String, known: Set<UInt32>) -> StreamItem {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String
        else { return .ignore }
        switch type {
        case "stream_event":
            guard let event = obj["event"] as? [String: Any],
                  event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any]
            else { return .ignore }
            if let text = delta["partial_json"] as? String { return .delta(text) }
            if let text = delta["text"] as? String { return .delta(text) }
            return .ignore
        case "result":
            if obj["is_error"] as? Bool == true {
                let why = (obj["result"] as? String)
                    ?? (obj["api_error_status"].map { "\($0)" })
                    ?? "error without a message"
                return .final(.failed(why))
            }
            guard let structured = obj["structured_output"] as? [String: Any],
                  let raw = structured["matches"] as? [[String: Any]]
            else {
                let shown = (obj["result"] as? String) ?? String(line.prefix(400))
                return .final(.malformed(shown))
            }
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
            return .final(.answered(matches: matches, droppedUnknownIds: dropped))
        default:
            return .ignore
        }
    }
}
