import Foundation

// AI-assisted update (history in the manifold; the SDK and API routes): model
// claude-opus-5-5; reasoning effort unavailable (not exposed by the harness).

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
    /// a streamed transcript; locked down the way laptop-pool runs the Agent
    /// SDK: no tools, no MCP server, no settings, nothing to ask, and no
    /// local session history. The prompt carries screen text; these flags do
    /// not control retention at the provider.
    static func arguments(schema: String, systemPrompt: String) -> [String] {
        [
            "-p",
            "--model", model,
            "--effort", effort,
            "--no-session-persistence",
            "--tools", "",
            "--permission-mode", "dontAsk",
            "--strict-mcp-config",
            "--mcp-config", #"{"mcpServers":{}}"#,
            "--setting-sources", "",
            "--exclude-dynamic-system-prompt-sections",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--json-schema", schema,
            "--system-prompt", systemPrompt,
        ]
    }

    /// One question for the model, whichever route takes it: the prompt,
    /// the system prompt and schema it is asked under, and how its
    /// structured answer is read back.
    struct Request: Sendable {
        let systemPrompt: String
        let schema: String
        let prompt: String
        let answer: @Sendable ([String: Any]) -> Answer?

        var arguments: [String] { Ask.arguments(schema: schema, systemPrompt: systemPrompt) }
        func parseLine(_ line: String) -> StreamItem { Ask.parseLine(line, answer: answer) }
    }

    /// Where the Claude Code CLI may live when the settings do not name it
    /// and the daemon's own PATH (a launchd agent's, so nearly empty) does
    /// not either.
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
        /// Lines that were on the window earlier and are gone now, and its
        /// earlier titles, each with when it was seen ("13:02–13:40 …").
        var earlier: [String]? = nil
        /// When the user last worked in it ("HH:MM"), and for how many
        /// minutes over the last day.
        var lastActive: String? = nil
        var activeMinutes: Int? = nil

        enum CodingKeys: String, CodingKey {
            case id, app, title, focused, text, earlier
            case lastActive = "last_active", activeMinutes = "active_minutes"
        }
    }

    /// A window closed within the last day, with what it said.
    struct ManifoldClosedWindow: Codable, Equatable {
        let id: UInt32
        let app: String
        let title: String
        let workspace: String?
        let closedAt: String
        let earlier: [String]

        enum CodingKeys: String, CodingKey {
            case id, app, title, workspace, earlier, closedAt = "closed_at"
        }
    }

    /// What the history adds to one window.
    struct WindowHistory: Equatable {
        let earlier: [String]
        let lastActive: String?
        let activeMinutes: Int
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
        var closedWindows: [ManifoldClosedWindow]? = nil

        enum CodingKeys: String, CodingKey {
            case question, currentWorkspace = "current_workspace", workspaces, closedWindows = "closed_windows"
        }

        var windowIds: Set<UInt32> { Set(workspaces.flatMap { $0.windows.map(\.id) }) }
        var closedIds: Set<UInt32> { Set((closedWindows ?? []).map(\.id)) }
        var tags: Set<String> { Set(workspaces.map(\.tag)) }
    }

    /// Every non-empty workspace (or just those in `only`), on-screen ones
    /// first, each window with an excerpt of its recognised text and, when
    /// `history` has any, what it said earlier. `budget` caps the total
    /// excerpt characters across all windows so the prompt stays one call's
    /// worth; the per-window cap is the budget spread evenly, at most
    /// `perWindow`. (`history` brings its own budget: `HistoryEvidence`.)
    static func manifold(
        question: String,
        snapshot: OverlaySnapshot,
        text: (UInt32) -> String?,
        history: (UInt32) -> WindowHistory? = { _ in nil },
        closed: [ManifoldClosedWindow] = [],
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
                let past = history(w.windowId)
                return ManifoldWindow(
                    id: w.windowId,
                    app: w.appName ?? "?",
                    title: w.title ?? "",
                    focused: w.isFocused,
                    text: text(w.windowId).map { TextSearch.excerpt($0, limit: cap, terms: TextSearch.terms(question)) },
                    earlier: past.flatMap { $0.earlier.isEmpty ? nil : $0.earlier },
                    lastActive: past?.lastActive,
                    activeMinutes: past.flatMap { $0.activeMinutes > 0 ? $0.activeMinutes : nil }
                )
            })
        }
        let current = snapshot.screens.first { $0.windows.contains { $0.isFocused } }?.workspaceTag
            ?? snapshot.screens.first?.workspaceTag
        let open = Set(workspaces.flatMap { $0.windows.map(\.id) })
        let gone = closed.filter { !open.contains($0.id) }
        return Manifold(question: question, currentWorkspace: current, workspaces: workspaces,
                        closedWindows: gone.isEmpty ? nil : gone)
    }

    /// The question, then the manifold. Every "@" is escaped: the CLI reads
    /// "@path" in a prompt as a file to attach, and a window title or a line
    /// of screen text could name one. (In the JSON it is the escape \\u0040;
    /// in the question line, a full-width ＠.)
    static func prompt(for manifold: Manifold) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = (try? encoder.encode(manifold)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let question = manifold.question.replacingOccurrences(of: "@", with: "＠")
        return "\(question)\n\nManifold:\n" + json.replacingOccurrences(of: "@", with: "\\u0040")
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
            if subtype == "init", obj["tools"] != nil, let why = ClaudeAccess.lockedDown(obj) {
                return .final(.failed("refused to use the answer: \(why)"))
            }
            let model = (obj["model"] as? String).map { " model=\($0)" } ?? ""
            let status = (obj["status"] as? String).map { " \($0)" } ?? ""
            let source = (obj["apiKeySource"] as? String).map { " key=\($0)" } ?? ""
            return .note("system \(subtype)\(model)\(status)\(source)")
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
