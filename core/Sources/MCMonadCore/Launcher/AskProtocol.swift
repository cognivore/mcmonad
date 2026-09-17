import Foundation

/// What every launcher question to the model shares — "where is …" and
/// "what's up": describing every window to it (the manifold), calling the
/// Claude Code CLI already on this Mac, and reading its stream back into one
/// of four distinct outcomes. Pure; the process handling is `AskRunner`.
enum Ask {
    /// The model and effort every question goes to. Fable 5.1 at low effort:
    /// these are lookups over evidence we hand it, not reasoning tasks.
    static let model = "claude-fable-5-1"
    static let effort = "low"

    /// Arguments after the executable. Print mode with structured output and
    /// a streamed transcript; no tools; no session written to disk — the
    /// prompt carries recognised screen text and must not outlive the call.
    static func arguments(schema: String, systemPrompt: String) -> [String] {
        [
            "-p",
            "--model", model,
            "--effort", effort,
            "--no-session-persistence",
            "--tools", "",
            "--exclude-dynamic-system-prompt-sections",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--json-schema", schema,
            "--system-prompt", systemPrompt,
        ]
    }

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

        var windowIds: Set<UInt32> { Set(workspaces.flatMap { $0.windows.map(\.id) }) }
        var tags: Set<String> { Set(workspaces.map(\.tag)) }
    }

    /// Every non-empty workspace (or just those in `only`), on-screen ones
    /// first, each window with an excerpt of its recognised text. `budget`
    /// caps the total excerpt characters across all windows so the prompt
    /// stays one call's worth; the per-window cap is the budget spread
    /// evenly, at most `perWindow`.
    static func manifold(
        question: String,
        snapshot: OverlaySnapshot,
        text: (UInt32) -> String?,
        only: Set<String>? = nil,
        budget: Int = 80_000,
        perWindow: Int = 1_500
    ) -> Manifold {
        var pending: [(String, Bool, [OverlayWindowEntry])] = []
        for screen in snapshot.screens where !screen.windows.isEmpty && only?.contains(screen.workspaceTag) ?? true {
            pending.append((screen.workspaceTag, true, screen.windows))
        }
        for ws in snapshot.hiddenWorkspaces where !ws.windows.isEmpty && only?.contains(ws.tag) ?? true {
            pending.append((ws.tag, false, ws.windows))
        }
        let count = pending.reduce(0) { $0 + $1.2.count }
        let cap = count == 0 ? perWindow : min(perWindow, budget / count)
        let workspaces = pending.map { tag, onScreen, entries in
            ManifoldWorkspace(tag: tag, onScreen: onScreen, windows: entries.map { w in
                ManifoldWindow(
                    id: w.windowId,
                    app: w.appName ?? "?",
                    title: w.title ?? "",
                    focused: w.isFocused,
                    text: text(w.windowId).map { TextSearch.excerpt($0, limit: cap) }
                )
            })
        }
        let current = snapshot.screens.first { $0.windows.contains { $0.isFocused } }?.workspaceTag
            ?? snapshot.screens.first?.workspaceTag
        return Manifold(question: question, currentWorkspace: current, workspaces: workspaces)
    }

    static func prompt(for manifold: Manifold) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = (try? encoder.encode(manifold)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "\(manifold.question)\n\nManifold:\n\(json)"
    }

    // MARK: - Answer (what the model tells us)

    /// The two shapes an answer takes. Unknown ids/tags are already dropped
    /// and counted: the model may not name windows or workspaces we do not have.
    enum Answer: Equatable {
        case windows(matches: [WhereIs.Match], droppedUnknownIds: Int)
        case workspaces(summaries: [WhatsUp.Summary], droppedUnknownTags: Int)
    }

    /// The four things a call can come back as. They are kept apart because
    /// the launcher shows each differently: an empty answer is a successful
    /// search that found nothing; the other three are not searches at all.
    enum Outcome: Equatable {
        /// The CLI answered in the schema.
        case answered(Answer)
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
        /// A protocol event that is not content: shown as one dim line so a
        /// slow call is visibly alive (init, rate limit, message boundaries).
        case note(String)
        /// The final result line.
        case final(Outcome)
        /// A line that is not JSON.
        case ignore
    }

    /// Parse one line of `--output-format stream-json`. `answer` turns the
    /// result's `structured_output` object into an `Answer`, or nil when it
    /// is not the contract.
    static func parseLine(_ line: String, answer: ([String: Any]) -> Answer?) -> StreamItem {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String
        else { return .ignore }
        switch type {
        case "stream_event":
            guard let event = obj["event"] as? [String: Any],
                  let eventType = event["type"] as? String
            else { return .note("stream_event") }
            if eventType == "content_block_delta", let delta = event["delta"] as? [String: Any] {
                if let text = delta["partial_json"] as? String { return .delta(text) }
                if let text = delta["text"] as? String { return .delta(text) }
            }
            return .note(eventType)
        case "system":
            let subtype = (obj["subtype"] as? String) ?? ""
            let model = (obj["model"] as? String).map { " model=\($0)" } ?? ""
            let status = (obj["status"] as? String).map { " \($0)" } ?? ""
            return .note("system \(subtype)\(model)\(status)")
        case "rate_limit_event":
            let status = ((obj["rate_limit_info"] as? [String: Any])?["status"] as? String)
                ?? (obj["status"] as? String) ?? ""
            return .note("rate_limit \(status)")
        case "assistant", "user":
            return .note("\(type) message")
        case "result":
            if obj["is_error"] as? Bool == true {
                let why = (obj["result"] as? String)
                    ?? (obj["api_error_status"].map { "\($0)" })
                    ?? "error without a message"
                return .final(.failed(why))
            }
            if let structured = obj["structured_output"] as? [String: Any],
               let parsed = answer(structured) {
                return .final(.answered(parsed))
            }
            let shown = (obj["result"] as? String) ?? String(line.prefix(400))
            return .final(.malformed(shown))
        default:
            return .note(type)
        }
    }
}
