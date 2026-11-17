import Foundation

// AI-generated text: model claude-opus-5-5; reasoning effort unavailable (not exposed by the harness).

/// How a launcher question reaches Codex, the route tried first. The pure
/// half: the locked-down `codex exec` arguments and environment, and
/// reading its JSONL events back. The effects are `AskRunner`'s.
///
/// The Codex SDK drives `codex exec --json` and reads the same events;
/// mcmonad drives it itself, on the user's own ChatGPT login (Codex's
/// `auth.json`), with `Ask.Engine.codex`'s model and effort, locked down:
///
/// - `--ignore-user-config`, `--ignore-rules`: none of the user's MCP
///   servers, hooks, profiles, notify commands or exec rules.
/// - Every feature that hands the model a tool is disabled. What the model
///   still declares fails closed: code mode has no host, and a sub-agent
///   cannot load an ephemeral thread.
/// - `model_instructions_file`: the question's system prompt replaces
///   Codex's coding-agent instructions; no AGENTS.md, environment or
///   permissions context is added.
/// - `--ephemeral` and history off: no rollout, history line, session
///   index or memory is written. (Checked on Codex 0.169: nothing of a
///   probe's prompt or thread reached `~/.codex`.)
/// - `--sandbox read-only` in an empty private directory, for whatever is
///   left.
///
/// A stream that shows any tool item is refused there and then, and the
/// run stopped. An `OPENAI_API_KEY` the daemon happens to carry is not
/// passed on: the subscription carries the cost.
enum CodexAccess {
    /// Features that give the model a tool, or keep state across sessions.
    static let disabledFeatures = [
        "shell_tool", "unified_exec", "code_mode_host", "apps", "plugins", "image_generation",
        "browser_use", "computer_use", "hooks", "multi_agent", "multi_agent_v2", "goals",
        "memories", "skill_search", "tool_suggest", "sleep_tool", "shell_snapshot",
    ]

    /// Configuration that keeps the web, project files, the environment and
    /// local history out of the call.
    static let settings = [
        #"web_search="disabled""#,
        "project_doc_max_bytes=0",
        "include_environment_context=false",
        "include_permissions_instructions=false",
        "include_apps_instructions=false",
        #"history.persistence="none""#,
        "agents.max_depth=0",
    ]

    /// Arguments after the executable. The prompt, which carries screen
    /// text, goes on stdin ("-"); the files hold only the request's fixed
    /// schema and system prompt.
    static func arguments(files: Ask.ContractFiles, cwd: String) -> [String] {
        var args = [
            "exec", "--json", "--ephemeral", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check",
            "--sandbox", "read-only", "--cd", cwd,
            "--model", Ask.Engine.codex.model,
            "--config", "model_reasoning_effort=" + toml(Ask.Engine.codex.effort),
            "--config", "model_instructions_file=" + toml(files.instructions),
            "--output-schema", files.schema,
        ]
        for feature in disabledFeatures { args += ["--disable", feature] }
        for setting in settings { args += ["--config", setting] }
        args.append("-")
        return args
    }

    /// `s` as a TOML basic string.
    static func toml(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The Codex child's whole environment: what it needs to find itself and
    /// the login, and nothing else.
    static func environment(inherited env: [String: String], home: String, user: String) -> [String: String] {
        var out: [String: String] = [
            "HOME": home,
            "USER": user,
            "LOGNAME": user,
            "PATH": ClaudeAccess.searchPath(home: home, user: user, inherited: env["PATH"]),
        ]
        for key in ["TMPDIR", "LANG", "SSL_CERT_FILE", "NIX_SSL_CERT_FILE"] { if let v = env[key] { out[key] = v } }
        return out
    }

    /// Item types that are the model talking or thinking, or Codex's own
    /// warnings. Any other item is a tool.
    static let quietItems: Set<String> = ["agent_message", "reasoning", "error"]

    /// Reads `codex exec --json` events in order. The structured answer is
    /// the turn's last agent message, believed when the turn completes.
    struct Stream {
        private let answer: @Sendable ([String: Any]) -> Ask.Answer?
        private var lastMessage: String?

        init(answer: @escaping @Sendable ([String: Any]) -> Ask.Answer?) {
            self.answer = answer
        }

        mutating func read(_ line: String) -> Ask.StreamItem {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let type = obj["type"] as? String
            else { return .ignore }
            switch type {
            case "thread.started":
                return .session("codex thread started")
            case "item.started", "item.updated", "item.completed":
                guard let item = obj["item"] as? [String: Any], let itemType = item["type"] as? String else {
                    return .note(type)
                }
                guard CodexAccess.quietItems.contains(itemType) else {
                    return .final(.failed("refused to use the answer: the session used the tool item \(itemType)"))
                }
                guard type == "item.completed" else { return .ignore }
                switch itemType {
                case "agent_message":
                    let text = item["text"] as? String ?? ""
                    lastMessage = text
                    return .delta(text)
                case "error":
                    let message = (item["message"] as? String ?? "").split(separator: "\n").first.map(String.init) ?? ""
                    return .note("codex: \(message)")
                default:
                    return .note(itemType)
                }
            case "turn.completed":
                guard let text = lastMessage else { return .final(.malformed("the turn ended without a message")) }
                if let structured = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                   let parsed = answer(structured) {
                    return .final(.answered(parsed))
                }
                return .final(.malformed(String(text.prefix(400))))
            case "turn.failed":
                let why = ((obj["error"] as? [String: Any])?["message"] as? String) ?? "the turn failed"
                return .final(.failed(why))
            case "error":
                return .note("codex error: " + ((obj["message"] as? String) ?? ""))
            default:
                return .note(type)
            }
        }
    }
}

extension Ask.Facts {
    /// The facts of a Codex turn's last event; nil for any other line.
    /// Codex counts cached input inside `input_tokens`.
    static func ofCodexLine(_ line: String) -> Ask.Facts? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        switch type {
        case "turn.completed":
            var usage: Ask.Usage?
            if let u = obj["usage"] as? [String: Any], let input = u["input_tokens"] as? Int,
               let output = u["output_tokens"] as? Int {
                let cached = u["cached_input_tokens"] as? Int ?? 0
                usage = Ask.Usage(input: input - cached, output: output, cacheRead: cached,
                                  cacheWrite: u["cache_write_input_tokens"] as? Int ?? 0)
            }
            return Ask.Facts(detail: "completed", usage: usage)
        case "turn.failed":
            return Ask.Facts(detail: "turn-failed")
        default:
            return nil
        }
    }
}
