import Foundation

// AI-generated text: model claude-opus-5-5; reasoning effort unavailable (not exposed by the harness).

/// How a launcher question reaches Claude, and with which login. The pure
/// half: reading the settings, and the locked-down CLI's arguments and
/// environment. The effects are `ClaudeRoutes` and `AskRunner`.
///
/// One route, the way laptop-pool runs its workers: Claude Code headless
/// (`claude -p`, the Agent SDK's engine) on the user's own Claude login.
/// Its child gets an environment allowlist (an `ANTHROPIC_API_KEY` the
/// daemon happens to carry is not passed on), no tools, no MCP servers, no
/// settings, no CLAUDE.md or auto-memory, no session written. Its `init`
/// line is checked for exactly that before any answer is believed. An
/// OAuth token can be named (a command that prints it, or an owner-only
/// file) when the CLI's own login discovery is not enough. There is no
/// Messages API route: its tokens cost money the subscription covers.
///
/// Settings: `~/.config/mcmonad/claude.json`, read at every question, all
/// of it optional:
///
///     { "sdk": { "cli": "/abs/path/claude",
///                "oauthTokenCommand": ["rageveil", "show", "claude.ai/oauth-token"] },
///       "retention": { "receipts": "log", "hours": 24 } }
///
/// (`oauthTokenFile` names an owner-only file instead.) Without the file
/// the CLI uses its own login; a file that is not this shape is an error,
/// never ignored. `retention` is what is kept of questions once they are
/// over (`Ask.Retention`): receipts in memory for `hours` (1 to 168), and
/// with `"log"` also one line each in mcmonad-core.log; `"memory"` keeps
/// them out of the log.
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
        var retention = Ask.Retention()
    }

    static func settingsPath(home: String) -> String { home + "/.config/mcmonad/claude.json" }

    /// The settings in `data`, or why they are not usable.
    static func parse(_ data: Data) -> Result<Settings, Problem> {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(Problem("not a JSON object"))
        }
        for key in root.keys where !["sdk", "retention"].contains(key) { return .failure(Problem("unknown key \"\(key)\"")) }
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
        if let retention = root["retention"] {
            switch parseRetention(retention) {
            case .failure(let problem): return .failure(problem)
            case .success(let r): settings.retention = r
            }
        }
        return .success(settings)
    }

    private static func parseRetention(_ value: Any) -> Result<Ask.Retention, Problem> {
        guard let o = value as? [String: Any] else { return .failure(Problem("\"retention\" is not an object")) }
        for key in o.keys where !["receipts", "hours"].contains(key) {
            return .failure(Problem("unknown key \"retention.\(key)\""))
        }
        var retention = Ask.Retention()
        if let v = o["receipts"] {
            guard let s = v as? String, let r = Ask.Retention.Receipts(rawValue: s) else {
                return .failure(Problem("\"retention.receipts\" is neither \"memory\" nor \"log\""))
            }
            retention.receipts = r
        }
        if let v = o["hours"] {
            // A JSON true is an NSNumber too; it is not a number of hours.
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  let hours = Int(exactly: n.doubleValue), Ask.Retention.hourRange.contains(hours) else {
                return .failure(Problem("\"retention.hours\" is not a whole number from 1 to 168"))
            }
            retention.hours = hours
        }
        return .success(retention)
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
            "CLAUDE_CODE_MAX_OUTPUT_TOKENS": String(Ask.maxOutputTokens),
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
}
