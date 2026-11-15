import Foundation

// AI-generated text: model claude-opus-5-5; reasoning effort unavailable (not exposed by the harness).

/// How a launcher question reaches Claude, and with which credentials. The
/// pure half: reading the settings, the locked-down CLI's arguments and
/// environment, and the Messages API request and answer. The effects are
/// `ClaudeRoutes` and `AskRunner`.
///
/// Two routes, tried in order, the way laptop-pool runs its workers:
///
///  1. **SDK** — Claude Code headless (`claude -p`, the Agent SDK's
///     engine), on the user's own Claude login. Its child gets an
///     environment allowlist (an `ANTHROPIC_API_KEY` the daemon happens to
///     carry is not passed on), no tools, no MCP servers, no settings, no
///     CLAUDE.md or auto-memory, no session written. Its `init` line is
///     checked for exactly that before any answer is believed. An OAuth
///     token can be named (a command that prints it, or an owner-only
///     file) when the CLI's own login discovery is not enough.
///  2. **API** — the Messages API, only when the SDK route could not answer
///     (no CLI, a failed run) and a key source is configured: a command
///     that prints the key (`rageveil show …`, `security
///     find-generic-password -w …`) or an owner-only file. Never a bare
///     environment variable.
///
/// Settings: `~/.config/mcmonad/claude.json`, read at every question, all
/// of it optional:
///
///     { "sdk": { "cli": "/abs/path/claude",
///                "oauthTokenCommand": ["rageveil", "show", "claude.ai/oauth-token"] },
///       "api": { "keyCommand": ["rageveil", "show", "anthropic/api-key"] } }
///
/// (`oauthTokenFile` / `keyFile` name owner-only files instead.) Without
/// the file the SDK route uses the CLI's own login and there is no API
/// route; a file that is not this shape is an error, never ignored.
enum ClaudeAccess {
    /// Why a route or a secret is not usable, in words for the transcript.
    /// Never carries a secret's text.
    struct Problem: Error, Equatable, Sendable, CustomStringConvertible {
        let why: String
        init(_ why: String) { self.why = why }
        var description: String { why }
    }

    enum Secret: Equatable, Sendable {
        /// An argv whose standard output is the secret.
        case command([String])
        /// A file only its owner may read.
        case file(String)
    }

    struct Settings: Equatable, Sendable {
        var cli: String?
        var oauthToken: Secret?
        var apiKey: Secret?
    }

    static func settingsPath(home: String) -> String { home + "/.config/mcmonad/claude.json" }

    /// The settings in `data`, or why they are not usable.
    static func parse(_ data: Data) -> Result<Settings, Problem> {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(Problem("not a JSON object"))
        }
        for key in root.keys where key != "sdk" && key != "api" { return .failure(Problem("unknown key \"\(key)\"")) }
        var settings = Settings()
        if let sdk = root["sdk"] {
            guard let sdk = sdk as? [String: Any] else { return .failure(Problem("\"sdk\" is not an object")) }
            for key in sdk.keys where !["cli", "oauthTokenCommand", "oauthTokenFile"].contains(key) {
                return .failure(Problem("unknown key \"sdk.\(key)\""))
            }
            if let cli = sdk["cli"] {
                guard let cli = cli as? String, cli.hasPrefix("/") else { return .failure(Problem("\"sdk.cli\" is not an absolute path")) }
                settings.cli = cli
            }
            switch secret(sdk, command: "oauthTokenCommand", file: "oauthTokenFile", in: "sdk") {
            case .failure(let problem): return .failure(problem)
            case .success(let s): settings.oauthToken = s
            }
        }
        if let api = root["api"] {
            guard let api = api as? [String: Any] else { return .failure(Problem("\"api\" is not an object")) }
            for key in api.keys where !["keyCommand", "keyFile"].contains(key) {
                return .failure(Problem("unknown key \"api.\(key)\""))
            }
            switch secret(api, command: "keyCommand", file: "keyFile", in: "api") {
            case .failure(let problem): return .failure(problem)
            case .success(let s):
                guard let s else { return .failure(Problem("\"api\" names neither keyCommand nor keyFile")) }
                settings.apiKey = s
            }
        }
        return .success(settings)
    }

    private static func secret(_ o: [String: Any], command: String, file: String, in section: String) -> Result<Secret?, Problem> {
        switch (o[command], o[file]) {
        case (nil, nil): return .success(nil)
        case (.some, .some): return .failure(Problem("\"\(section)\" names both \(command) and \(file)"))
        case (let argv?, nil):
            guard let argv = argv as? [String], !argv.isEmpty, !argv[0].isEmpty else {
                return .failure(Problem("\"\(section).\(command)\" is not a non-empty list of strings"))
            }
            return .success(.command(argv))
        case (nil, let path?):
            guard let path = path as? String, path.hasPrefix("/") || path.hasPrefix("~/") else {
                return .failure(Problem("\"\(section).\(file)\" is not an absolute path"))
            }
            return .success(.file(path))
        }
    }

    /// A token or key as printed or stored: one line, its trailing newline
    /// dropped, no whitespace inside, 32 to 512 characters.
    static func credential(_ raw: String) -> Result<String, Problem> {
        var s = raw
        while s.hasSuffix("\n") || s.hasSuffix("\r") { s.removeLast() }
        guard !s.contains(where: \.isWhitespace) else { return .failure(Problem("contains whitespace")) }
        guard (32...512).contains(s.count) else { return .failure(Problem("is \(s.count) characters, not 32 to 512")) }
        return .success(s)
    }

    /// A file mode that lets nobody but the owner read.
    static func ownerOnly(_ mode: Int) -> Bool { mode & 0o077 == 0 }

    // MARK: - The SDK route

    /// Where binaries a launchd agent's PATH does not name may live: the
    /// CLI's own installer, Homebrew, and the Nix profiles (rageveil).
    static func searchPath(home: String, user: String, inherited: String?) -> String {
        var dirs = [home + "/.local/bin", home + "/.nix-profile/bin", "/etc/profiles/per-user/\(user)/bin",
                    "/run/current-system/sw/bin", "/nix/var/nix/profiles/default/bin",
                    "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        for dir in (inherited ?? "").split(separator: ":").map(String.init) where !dirs.contains(dir) { dirs.append(dir) }
        return dirs.joined(separator: ":")
    }

    /// The CLI child's whole environment: what it needs to find itself and
    /// the login, the OAuth token when one was named, and the switches that
    /// keep memory, CLAUDE.md files and background traffic out of the call.
    static func cliEnvironment(inherited env: [String: String], home: String, user: String, token: String?) -> [String: String] {
        var out: [String: String] = [
            "HOME": home,
            "USER": user,
            "LOGNAME": user,
            "PATH": searchPath(home: home, user: user, inherited: env["PATH"]),
            "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1",
            "CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "DISABLE_AUTOUPDATER": "1",
        ]
        for key in ["TMPDIR", "LANG", "SSL_CERT_FILE", "NIX_SSL_CERT_FILE"] { if let v = env[key] { out[key] = v } }
        if let token { out["CLAUDE_CODE_OAUTH_TOKEN"] = token }
        return out
    }

    /// What the `init` line must say before an answer is believed: no tool
    /// but structured output, no MCP server, nothing asked.
    static func lockedDown(_ initLine: [String: Any]) -> String? {
        let tools = (initLine["tools"] as? [String]) ?? []
        if let extra = tools.first(where: { $0 != "StructuredOutput" }) { return "the session has the tool \(extra)" }
        if let mcp = initLine["mcp_servers"] as? [Any], !mcp.isEmpty { return "the session has \(mcp.count) MCP server(s)" }
        guard initLine["permissionMode"] as? String == "dontAsk" else {
            return "the session's permission mode is \(initLine["permissionMode"].map { "\($0)" } ?? "unstated")"
        }
        return nil
    }

    // MARK: - The API route

    static let apiURL = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2026-10-21"
    /// Server-side refusal fallbacks: a declined request is re-run on the
    /// model Anthropic recommends for its category, inside the same call.
    static let apiBeta = "server-side-fallback-2026-07-01"

    static func apiHeaders(key: String) -> [String: String] {
        ["content-type": "application/json", "x-api-key": key,
         "anthropic-version": apiVersion, "anthropic-beta": apiBeta]
    }

    /// The request body: the same model, effort, system prompt and schema
    /// as the SDK route, the prompt as the one user turn.
    static func apiBody(_ request: Ask.Request) -> Data? {
        guard let schema = try? JSONSerialization.jsonObject(with: Data(request.schema.utf8)) else { return nil }
        let body: [String: Any] = [
            "model": Ask.model,
            "max_tokens": 16_000,
            "system": request.systemPrompt,
            "messages": [["role": "user", "content": request.prompt]],
            "output_config": ["effort": Ask.effort, "format": ["type": "json_schema", "schema": schema]],
            "fallbacks": "default",
        ]
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// The API's reply as an outcome. Only the kind of an error is kept:
    /// its type and message, which are about the request, not its content.
    static func apiOutcome(status: Int, data: Data, request: Ask.Request) -> Ask.Outcome {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200 else {
            let error = obj?["error"] as? [String: Any]
            let kind = (error?["type"] as? String) ?? "error"
            let message = (error?["message"] as? String).map { ": \($0)" } ?? ""
            return .failed("API returned HTTP \(status) (\(kind)\(message))")
        }
        guard let obj else { return .malformed("API answer is not JSON") }
        if obj["stop_reason"] as? String == "refusal" {
            let category = ((obj["stop_details"] as? [String: Any])?["category"] as? String).map { " (\($0))" } ?? ""
            return .failed("the model declined the request\(category)")
        }
        let texts = ((obj["content"] as? [[String: Any]]) ?? []).filter { $0["type"] as? String == "text" }
        guard let text = texts.compactMap({ $0["text"] as? String }).last,
              let structured = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let answer = request.answer(structured)
        else { return .malformed("API answer is not in the schema (stop_reason \(obj["stop_reason"] as? String ?? "unstated"))") }
        return .answered(answer)
    }
}
