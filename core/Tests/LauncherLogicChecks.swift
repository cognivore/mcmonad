// Compiled with the launcher's pure files (TextSearch, RecentUse,
// AskProtocol, WhereIsProtocol, WhatsUp, ClaudeAccess, Protocol) and run by
// the Nix package checkPhase.
//
// AI-assisted update (history manifold, SDK/API route checks): model
// claude-opus-5-5; reasoning effort unavailable (not exposed by the harness).
import Foundation
import CoreGraphics

@main
enum LauncherLogicChecks {
    @MainActor static func main() async {
        checkTerms()
        checkHits()
        checkRanges()
        checkReadingOrder()
        checkWhereIsQuery()
        checkManifold()
        checkHistoryManifold()
        checkClaudeAccess()
        checkTitleEvent()
        checkStream()
        checkWhatsUp()
        checkWhatsUpCache()
        await checkMonitoringPrivacy()
        await checkAskRunner()
        checkAskReceipts()
        checkRecency()
        checkOverlayScreenWire()
        checkWorkspaceWindowLookup()
        checkParkGeometry()
        checkParkedHome()
        print("Launcher logic checks passed")
    }

    // MARK: TextSearch

    static func checkTerms() {
        precondition(TextSearch.terms("Where is the deploy notes?") == ["deploy", "notes"])
        precondition(TextSearch.terms("  ") == [])
        precondition(TextSearch.terms("a an the") == [])
        precondition(TextSearch.terms("Deploy DEPLOY deploy") == ["deploy"])
        precondition(TextSearch.terms("mcmonad.state v4") == ["mcmonad.state", "v4"])
        precondition(TextSearch.excerpt("  a\n\n b\tc  ", limit: 100) == "a b c")
        precondition(TextSearch.excerpt("abcdef", limit: 3) == "abc…")
        precondition(TextSearch.excerpt("abc", limit: 0) == "")
        let terminal = "Ghostty " + String(repeating: "diff code ", count: 300) + " HMRC tax filing system in Rust"
        let evidence = TextSearch.excerpt(terminal, limit: 160, terms: ["claude", "hmrc", "thingie"])
        precondition(evidence.hasPrefix("Ghostty ") && evidence.contains("HMRC tax filing"), evidence)
        precondition(evidence.count <= 161)
    }

    static func checkHits() {
        let text = "first line here\nrestored 35 window(s); 3 pending\nlast line"
        let lower = text.lowercased()
        let hit = TextSearch.hit(terms: ["pending", "restored"], in: text, lower: lower)!
        precondition(hit.snippet == "restored 35 window(s); 3 pending", hit.snippet)
        precondition(hit.ranges == [NSRange(location: 0, length: 8), NSRange(location: 25, length: 7)],
                     "\(hit.ranges)")
        // Every term must be present somewhere, not just the first.
        precondition(TextSearch.hit(terms: ["restored", "absent"], in: text, lower: lower) == nil)
        // Case-insensitive, and an empty term list finds nothing.
        precondition(TextSearch.hit(terms: ["RESTORED"], in: text, lower: lower) != nil)
        precondition(TextSearch.hit(terms: [], in: text, lower: lower) == nil)
        // A long line is clipped around the hit with ellipses on both sides.
        let long = String(repeating: "x", count: 200) + " needle " + String(repeating: "y", count: 200)
        let clipped = TextSearch.hit(terms: ["needle"], in: long, lower: long.lowercased(), context: 10)!
        precondition(clipped.snippet == "…xxxxxxxxx needle yyyyyyyyy…", clipped.snippet)
        precondition(clipped.ranges == [NSRange(location: 11, length: 6)], "\(clipped.ranges)")
    }

    static func checkRanges() {
        let r = TextSearch.ranges(of: ["deploy", "deployment"], in: "Deploy the deployment; deploy again")
        precondition(r == [NSRange(location: 0, length: 6), NSRange(location: 11, length: 10),
                           NSRange(location: 23, length: 6)], "\(r)")
        precondition(TextSearch.ranges(of: [], in: "anything") == [])
        precondition(TextSearch.ranges(of: ["zzz"], in: "anything") == [])
    }

    static func checkReadingOrder() {
        // Vision boxes: bottom-left origin. Two lines, second line's words out of order.
        let obs: [(CGRect, String)] = [
            (CGRect(x: 0.5, y: 0.10, width: 0.2, height: 0.05), "world"),
            (CGRect(x: 0.0, y: 0.80, width: 0.2, height: 0.05), "Top"),
            (CGRect(x: 0.1, y: 0.11, width: 0.2, height: 0.05), "hello"),
        ]
        precondition(TextSearch.readingOrder(obs) == ["Top", "hello world"], "\(TextSearch.readingOrder(obs))")
        precondition(TextSearch.readingOrder([]) == [])
    }

    // MARK: WhereIs

    static func checkWhereIsQuery() {
        precondition(WhereIsQuery("where is my deploy terminal?")?.question == "my deploy terminal")
        precondition(WhereIsQuery("Where's the PR review")?.question == "the PR review")
        precondition(WhereIsQuery("WHERE ARE the cat videos!")?.question == "the cat videos")
        precondition(WhereIsQuery("where did I put the invoice")?.question == "the invoice")
        for text in ["where is", "where is ?", "whereabouts", "scr", "timer 5 where is x", ""] {
            precondition(WhereIsQuery(text) == nil, text)
        }
        precondition(WhereIsQuery("where is the deploy notes")!.terms == ["deploy", "notes"])
    }

    static func checkManifold() {
        func w(_ id: UInt32, _ app: String, _ title: String, focused: Bool = false) -> OverlayWindowEntry {
            OverlayWindowEntry(windowId: id, pid: 1, appName: app, title: title, bundleId: nil,
                               workspaceTag: nil, frame: .zero, isFocused: focused, isFloating: false)
        }
        let snap = OverlaySnapshot(
            debugOverlays: false,
            screens: [
                OverlayScreenEntry(screenId: 0, frame: .zero, workspaceTag: "3", isActive: true,
                                   windows: [w(7, "Ghostty", "deploy notes", focused: true)]),
                OverlayScreenEntry(screenId: 1, frame: .zero, workspaceTag: "2", isActive: false, windows: []),
            ],
            hiddenWorkspaces: [
                OverlayHiddenWorkspace(tag: "o5", windows: [w(9, "Chrome", "cats"), w(11, "?", "")]),
                OverlayHiddenWorkspace(tag: "z", windows: []),
            ],
            ignoredWindows: []
        )
        let m = Ask.manifold(question: "Where is: the deploy", snapshot: snap,
                             text: { $0 == 9 ? "a  b\nc" : nil }, budget: 30, perWindow: 100)
        precondition(m.windowIds == [7, 9, 11] && m.tags == ["3", "o5"])
        precondition(m.currentWorkspace == "3")
        precondition(m.workspaces.map(\.tag) == ["3", "o5"], "\(m.workspaces.map(\.tag))")
        precondition(m.workspaces[0].onScreen && !m.workspaces[1].onScreen)
        precondition(m.workspaces[0].windows == [Ask.ManifoldWindow(id: 7, app: "Ghostty", title: "deploy notes", focused: true, text: nil)])
        // Budget 30 over 3 windows → 10 chars per window.
        precondition(m.workspaces[1].windows[0].text == "a b c")
        precondition(m.workspaces[1].windows[1].text == nil)
        let some = Ask.manifold(question: "q", snapshot: snap, text: { _ in nil }, only: ["o5"])
        precondition(some.workspaces.map(\.tag) == ["o5"] && some.currentWorkspace == "3")
        let big = Ask.manifold(question: "q", snapshot: snap,
                               text: { _ in String(repeating: "t", count: 50) }, budget: 30, perWindow: 100)
        precondition(big.workspaces[0].windows[0].text == String(repeating: "t", count: 10) + "…")
        let prompt = Ask.prompt(for: m)
        precondition(prompt.hasPrefix("Where is: the deploy\n\nManifold:\n{\"current_workspace\":\"3\""), prompt)
        precondition(prompt.contains("\"on_screen\":true"))
        let request = WhereIs.request(for: m)
        precondition(request.prompt == prompt && request.arguments == WhereIs.arguments)
        for flag in ["--no-session-persistence", "--json-schema", "--strict-mcp-config", "--setting-sources"] {
            precondition(WhereIs.arguments.contains(flag), flag)
        }
        precondition(WhereIs.arguments.contains(WhereIs.systemPrompt))
        let tools = WhereIs.arguments.firstIndex(of: "--tools")!, mode = WhereIs.arguments.firstIndex(of: "--permission-mode")!
        precondition(WhereIs.arguments[tools + 1] == "" && WhereIs.arguments[mode + 1] == "dontAsk")
        // A laptop-pool profile's turn ceiling; no dollar one on a subscription.
        let turns = WhereIs.arguments.firstIndex(of: "--max-turns")!
        precondition(WhereIs.arguments[turns + 1] == "4" && !WhereIs.arguments.contains("--max-budget-usd"))
        precondition(WhereIs.systemPrompt.contains("snippets") && WhereIs.systemPrompt.contains("Reconstruct"))
        precondition(Ask.candidates(home: "/h", path: "/usr/bin:/opt/homebrew/bin")
                     == ["/h/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "/usr/bin/claude"])
    }

    static func checkHistoryManifold() {
        func w(_ id: UInt32, _ app: String, _ title: String) -> OverlayWindowEntry {
            OverlayWindowEntry(windowId: id, pid: 1, appName: app, title: title, bundleId: nil,
                               workspaceTag: nil, frame: .zero, isFocused: id == 7, isFloating: false)
        }
        let snap = OverlaySnapshot(debugOverlays: false,
                                   screens: [OverlayScreenEntry(screenId: 0, frame: .zero, workspaceTag: "3", isActive: true,
                                                                windows: [w(7, "Ghostty", "zsh"), w(8, "Chrome", "mail@example.com")])],
                                   hiddenWorkspaces: [], ignoredWindows: [])
        let closed = [Ask.ManifoldClosedWindow(id: 40, app: "Preview", title: "invoice.pdf", workspace: "o2",
                                               closedAt: "14:20", earlier: ["14:02 Invoice 2026-11 ACME"]),
                      Ask.ManifoldClosedWindow(id: 8, app: "Chrome", title: "stale", workspace: nil, closedAt: "x", earlier: [])]
        let m = Ask.manifold(question: "where is the @invoice", snapshot: snap, text: { _ in nil },
                             history: { $0 == 7 ? Ask.WindowHistory(earlier: ["13:02 cargo build", "13:05 title: deploy"],
                                                                     lastActive: "13:06", activeMinutes: 12) : nil },
                             closed: closed)
        let ghostty = m.workspaces[0].windows[0]
        precondition(ghostty.earlier == ["13:02 cargo build", "13:05 title: deploy"] && ghostty.lastActive == "13:06"
                     && ghostty.activeMinutes == 12)
        precondition(m.workspaces[0].windows[1].earlier == nil && m.workspaces[0].windows[1].lastActive == nil)
        // A window still open is not also "closed"; closed ids may be answered.
        precondition(m.closedIds == [40] && m.windowIds == [7, 8])
        let json = Ask.prompt(for: m)
        precondition(json.contains("\"closed_windows\"") && json.contains("\"last_active\":\"13:06\"")
                     && json.contains("\"active_minutes\":12"))
        // No "@" reaches the CLI, which would read "@path" as a file to attach.
        precondition(!json.contains("@") && json.contains("mail\\u0040example.com") && json.hasPrefix("where is the ＠invoice"), json)
        let decoded = try! JSONSerialization.jsonObject(with: Data(json.components(separatedBy: "Manifold:\n")[1].utf8)) as! [String: Any]
        let windows = ((decoded["workspaces"] as! [[String: Any]])[0]["windows"] as! [[String: Any]])
        precondition(windows[1]["title"] as? String == "mail@example.com", "the escape is JSON's own")
        let request = WhereIs.request(for: m)
        let answered = request.parseLine(#"{"type":"result","is_error":false,"structured_output":{"matches":[{"id":40,"reason":"closed pdf"},{"id":7,"reason":"build"},{"id":99,"reason":"?"}]}}"#)
        precondition(answered == .final(.answered(.windows(matches: [.init(windowId: 40, reason: "closed pdf"),
                                                                     .init(windowId: 7, reason: "build")],
                                                           droppedUnknownIds: 1))))
        // Without history the manifold is what it was.
        let plain = Ask.manifold(question: "q", snapshot: snap, text: { _ in nil })
        precondition(plain.closedWindows == nil && !Ask.prompt(for: plain).contains("closed_windows"))
    }

    static func checkClaudeAccess() {
        func parse(_ json: String) -> Result<ClaudeAccess.Settings, ClaudeAccess.Problem> { ClaudeAccess.parse(Data(json.utf8)) }
        precondition(parse("{}") == .success(ClaudeAccess.Settings()))
        precondition(parse(#"{"sdk":{"cli":"/x/claude","oauthTokenCommand":["rageveil","show","a/b"]},"api":{"keyFile":"~/.config/k"}}"#)
                     == .success(ClaudeAccess.Settings(cli: "/x/claude", oauthToken: .command(["rageveil", "show", "a/b"]),
                                                       apiKey: .file("~/.config/k"))))
        for bad in ["[]", #"{"apiKey":"sk-ant-x"}"#, #"{"api":{}}"#, #"{"api":{"key":"sk-ant-naked"}}"#,
                    #"{"api":{"keyCommand":["a"],"keyFile":"/k"}}"#, #"{"sdk":{"cli":"claude"}}"#,
                    #"{"api":{"keyCommand":[]}}"#, #"{"api":{"keyFile":"relative"}}"#] {
            guard case .failure = parse(bad) else { preconditionFailure("accepted \(bad)") }
        }
        let token = String(repeating: "t", count: 40)
        precondition(ClaudeAccess.credential(token + "\n") == .success(token))
        precondition(ClaudeAccess.credential("short") != .success("short"))
        precondition(ClaudeAccess.credential("a b" + token) != .success("a b" + token))
        precondition(ClaudeAccess.ownerOnly(0o600) && ClaudeAccess.ownerOnly(0o400) && !ClaudeAccess.ownerOnly(0o640))
        // The CLI child gets an allowlist: a stray API key is not passed on.
        let env = ClaudeAccess.cliEnvironment(inherited: ["ANTHROPIC_API_KEY": "sk-naked", "PATH": "/custom/bin", "LANG": "en_GB.UTF-8",
                                                          "AWS_SECRET_ACCESS_KEY": "x"],
                                              home: "/h", user: "u", token: token)
        precondition(env["ANTHROPIC_API_KEY"] == nil && env["AWS_SECRET_ACCESS_KEY"] == nil)
        precondition(env["CLAUDE_CODE_OAUTH_TOKEN"] == token && env["CLAUDE_CODE_DISABLE_CLAUDE_MDS"] == "1"
                     && env["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] == "1" && env["LANG"] == "en_GB.UTF-8" && env["USER"] == "u")
        precondition(env["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] == "16000")
        precondition(env["PATH"]!.hasPrefix("/h/.local/bin:") && env["PATH"]!.hasSuffix(":/custom/bin"))
        precondition(ClaudeAccess.cliEnvironment(inherited: [:], home: "/h", user: "u", token: nil)["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
        // The init line must show a locked-down session.
        precondition(ClaudeAccess.lockedDown(["tools": ["StructuredOutput"], "mcp_servers": [], "permissionMode": "dontAsk"]) == nil)
        precondition(ClaudeAccess.lockedDown(["tools": ["Bash"], "mcp_servers": [], "permissionMode": "dontAsk"]) != nil)
        precondition(ClaudeAccess.lockedDown(["tools": [], "mcp_servers": [["name": "x"]], "permissionMode": "dontAsk"]) != nil)
        precondition(ClaudeAccess.lockedDown(["tools": [], "mcp_servers": [], "permissionMode": "default"]) != nil)
        let initLine = #"{"type":"system","subtype":"init","model":"m","tools":["Read"],"mcp_servers":[],"permissionMode":"dontAsk"}"#
        guard case .final(.failed) = WhereIs.parseLine(initLine, known: []) else { preconditionFailure("a session with tools was believed") }
        let goodInit = #"{"type":"system","subtype":"init","model":"m","tools":["StructuredOutput"],"mcp_servers":[],"permissionMode":"dontAsk","apiKeySource":"none"}"#
        precondition(WhereIs.parseLine(goodInit, known: []) == .session("system init model=m key=none"))
        // The API route: same model, effort, schema; refusals and errors kept apart.
        let request = Ask.Request(kind: .whereIs, systemPrompt: "sys", schema: WhereIs.schemaJSON, prompt: "q",
                                  answer: { WhereIs.answer(from: $0, known: [7]) })
        let body = try! JSONSerialization.jsonObject(with: ClaudeAccess.apiBody(request)!) as! [String: Any]
        precondition(body["model"] as? String == Ask.model && body["system"] as? String == "sys" && body["fallbacks"] as? String == "default")
        let config = body["output_config"] as! [String: Any]
        precondition(config["effort"] as? String == Ask.effort && (config["format"] as! [String: Any])["type"] as? String == "json_schema")
        precondition(body["thinking"] == nil && body["temperature"] == nil)
        let headers = ClaudeAccess.apiHeaders(key: token)
        precondition(headers["x-api-key"] == token && headers["anthropic-version"] == "2026-10-21")
        func reply(_ json: String, _ status: Int = 200) -> Ask.Outcome {
            ClaudeAccess.apiOutcome(status: status, data: Data(json.utf8), request: request)
        }
        precondition(reply(#"{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":""},{"type":"text","text":"{\"matches\":[{\"id\":7,\"reason\":\"r\"}]}"}]}"#)
                     == .answered(.windows(matches: [.init(windowId: 7, reason: "r")], droppedUnknownIds: 0)))
        guard case .failed = reply(#"{"stop_reason":"refusal","content":[],"stop_details":{"category":"cyber"}}"#),
              case .failed(let why) = reply(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#, 401),
              case .malformed = reply(#"{"stop_reason":"end_turn","content":[{"type":"text","text":"prose"}]}"#)
        else { preconditionFailure("API outcomes") }
        precondition(why.contains("401") && why.contains("authentication_error") && !why.contains(token))
    }

    static func checkStream() {
        let known: Set<UInt32> = [7, 9]
        let delta = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{\"matches\":["}}}"#
        precondition(WhereIs.parseLine(delta, known: known) == .delta("{\"matches\":["))
        let textDelta = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}}"#
        precondition(WhereIs.parseLine(textDelta, known: known) == .delta("hi"))
        // An init line that does not say what the session has is not believed.
        guard case .final(.failed) = WhereIs.parseLine(#"{"type":"system","subtype":"init","model":"m"}"#, known: known) else {
            preconditionFailure("an init line without tools, servers or mode was believed")
        }
        precondition(WhereIs.parseLine(#"{"type":"system","subtype":"status","status":"ok"}"#, known: known) == .note("system status ok"))
        precondition(WhereIs.parseLine(#"{"type":"stream_event","event":{"type":"message_start"}}"#, known: known) == .note("message_start"))
        precondition(WhereIs.parseLine(#"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}"#, known: known) == .note("rate_limit allowed"))
        precondition(WhereIs.parseLine(#"{"type":"assistant","message":{}}"#, known: known) == .note("assistant message"))
        precondition(WhereIs.parseLine("not json", known: known) == .ignore)
        precondition(WhereIs.parseLine("", known: known) == .ignore)

        let ok = #"{"type":"result","subtype":"success","is_error":false,"result":"…","structured_output":{"matches":[{"id":7,"reason":"title says deploy"},{"id":9,"reason":"cats"},{"id":7,"reason":"dup"},{"id":4242,"reason":"made up"},{"id":-1,"reason":"neg"},{"reason":"no id"}]}}"#
        precondition(WhereIs.parseLine(ok, known: known) == .final(.answered(.windows(
            matches: [.init(windowId: 7, reason: "title says deploy"), .init(windowId: 9, reason: "cats")],
            droppedUnknownIds: 4))))
        let empty = #"{"type":"result","is_error":false,"structured_output":{"matches":[]}}"#
        precondition(WhereIs.parseLine(empty, known: known) == .final(.answered(.windows(matches: [], droppedUnknownIds: 0))))
        let failed = #"{"type":"result","is_error":true,"result":"Not logged in"}"#
        precondition(WhereIs.parseLine(failed, known: known) == .final(.failed("Not logged in")))
        let malformed = #"{"type":"result","is_error":false,"result":"plain prose"}"#
        precondition(WhereIs.parseLine(malformed, known: known) == .final(.malformed("plain prose")))
        // A session stopped by a ceiling says which, whatever else it printed.
        let turnsOut = #"{"type":"result","subtype":"error_max_turns","is_error":true}"#
        precondition(WhereIs.parseLine(turnsOut, known: known) == .final(.failed("stopped at the limit of 4 turns")))
        let stopped = #"{"type":"result","subtype":"error_during_execution","is_error":false,"structured_output":{"matches":[]}}"#
        precondition(WhereIs.parseLine(stopped, known: known) == .final(.failed("the session failed while running")))
        let shapeless = #"{"type":"result","subtype":"error_max_structured_output_retries","is_error":true}"#
        guard case .final(.malformed) = WhereIs.parseLine(shapeless, known: known) else { preconditionFailure("retries") }
        let odd = #"{"type":"result","subtype":"error_new_kind","is_error":true}"#
        precondition(WhereIs.parseLine(odd, known: known) == .final(.failed("the session ended as error_new_kind")))
    }

    static func checkTitleEvent() {
        let empty = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(IPCEvent.focusedWindowQueryEmpty)) as! [String: Any]
        precondition(empty["event"] as? String == "focused-window-query-empty" && empty.count == 1)
        for title: String? in ["HMRC tax filing system in Rust", "", nil] {
            let data = try! JSONEncoder().encode(IPCEvent.windowTitleChanged(windowId: 7, pid: 42, title: title))
            let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            precondition(object["event"] as? String == "window-title-changed")
            precondition(object["windowId"] as? Int == 7 && object["pid"] as? Int == 42)
            precondition(object["title"] as? String == title)
        }
    }

    // MARK: WhatsUp

    static func checkWhatsUp() {
        for text in ["what's up", "Whats up?", "WHAT IS UP!", "what’s up on my desks", "sup", "  sup?  "] {
            precondition(WhatsUp.matches(text), text)
        }
        for text in ["", "what", "whatsupdog", "supper", "where is up", "what's up?tell me", "timer 5 what's up"] {
            precondition(!WhatsUp.matches(text), text)
        }
        precondition(WhatsUp.systemPrompt.contains("caveman"))
        precondition(WhatsUp.arguments.contains(WhatsUp.schemaJSON))
        let tags: Set<String> = ["3", "o5"]
        let ok = #"{"type":"result","is_error":false,"structured_output":{"workspaces":[{"tag":"3","summary":"Deploy work.","reason":"title 'deploy notes'"},{"tag":"3","summary":"dup","reason":"dup"},{"tag":"zz","summary":"invented","reason":"none"},{"tag":"o5","summary":"Cats.","reason":"title 'cat videos'"},{"tag":"o5"}]}}"#
        precondition(WhatsUp.parseLine(ok, knownTags: tags) == .final(.answered(.workspaces(
            summaries: [.init(tag: "3", summary: "Deploy work.", reason: "title 'deploy notes'"),
                        .init(tag: "o5", summary: "Cats.", reason: "title 'cat videos'")],
            droppedUnknownTags: 3))))
        let wrong = #"{"type":"result","is_error":false,"result":"x","structured_output":{"matches":[]}}"#
        precondition(WhatsUp.parseLine(wrong, knownTags: tags) == .final(.malformed("x")))
    }

    @MainActor static func checkWhatsUpCache() {
        func w(_ id: UInt32, _ app: String, _ title: String) -> OverlayWindowEntry {
            OverlayWindowEntry(windowId: id, pid: 1, appName: app, title: title, bundleId: nil,
                               workspaceTag: nil, frame: .zero, isFocused: false, isFloating: false)
        }
        func snap(_ screens: [(String, [OverlayWindowEntry])], _ hidden: [(String, [OverlayWindowEntry])]) -> OverlaySnapshot {
            OverlaySnapshot(debugOverlays: false,
                            screens: screens.enumerated().map { OverlayScreenEntry(screenId: $0.offset, frame: .zero, workspaceTag: $0.element.0, isActive: $0.offset == 0, windows: $0.element.1) },
                            hiddenWorkspaces: hidden.map { OverlayHiddenWorkspace(tag: $0.0, windows: $0.1) },
                            ignoredWindows: [])
        }
        var hashes: [UInt32: Int] = [7: 1]
        let suite = "mcmonad-checks-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let cache = WhatsUpCache(text: { _ in nil }, textHash: { hashes[$0] }, quiet: { false },
                                 preferences: preferences, runner: RecordingRunner())
        cache.setEnabled(true)
        cache.noteSnapshot(snap([("3", [w(7, "Ghostty", "deploy")])], [("o5", [w(9, "Chrome", "cats")]), ("z", [])]))
        precondition(cache.order == ["3", "o5"])
        precondition(cache.due() == ["3", "o5"], "new workspaces are due")
        precondition(cache.rows == [.init(tag: "3", summary: nil, refreshing: false), .init(tag: "o5", summary: nil, refreshing: false)])
        // An answer lands for both, matching the fingerprints they were asked with.
        let asked = ["3": cache.entries["3"]!.fingerprint, "o5": cache.entries["o5"]!.fingerprint]
        let t0 = Date()
        cache.apply([.init(tag: "3", summary: "Deploy.", reason: "title"), .init(tag: "o5", summary: "Cats.", reason: "title")], asked: asked, at: t0)
        precondition(cache.due(at: t0).isEmpty, "fresh after apply")
        precondition(cache.rows[0].summary?.summary == "Deploy.")
        // Same windows, new OCR text: not due until the summary is old enough.
        hashes[7] = 2
        cache.noteTextChanged()
        precondition(cache.due(at: t0.addingTimeInterval(60)).isEmpty)
        precondition(cache.due(at: t0.addingTimeInterval(WhatsUpCache.textRefreshAge)) == ["3"])
        // A title change is text too.
        cache.noteSnapshot(snap([("3", [w(7, "Ghostty", "deploy done")])], [("o5", [w(9, "Chrome", "cats")])]))
        precondition(cache.due(at: t0.addingTimeInterval(60)).isEmpty)
        // A new window on o5 changes its window set: due at once; 3 keeps its summary.
        cache.noteSnapshot(snap([("3", [w(7, "Ghostty", "deploy done")])], [("o5", [w(9, "Chrome", "cats"), w(10, "Slack", "geo")])]))
        precondition(cache.due(at: t0.addingTimeInterval(60)) == ["o5"], "\(cache.due(at: t0.addingTimeInterval(60)))")
        precondition(cache.rows[1].summary?.summary == "Cats.", "old summary shown while stale")
        // A workspace that lost every window is gone from the rows.
        cache.noteSnapshot(snap([("3", [w(7, "Ghostty", "deploy done")])], [("o5", [])]))
        precondition(cache.order == ["3"] && cache.entries["o5"] == nil)
        // A workspace the model left out is not asked again until it changes.
        cache.noteSnapshot(snap([("3", [w(7, "Ghostty", "deploy done")])], [("o5", [w(9, "Chrome", "cats"), w(10, "Slack", "geo")])]))
        precondition(cache.due(at: t0) == ["o5"])
        cache.apply([], asked: ["o5": cache.entries["o5"]!.fingerprint], at: t0)
        precondition(cache.due(at: t0.addingTimeInterval(60)).isEmpty, "omitted tag is fresh")
        precondition(cache.rows[1].summary == nil && cache.rows[1].tag == "o5", "row stays, without a summary")
        cache.noteSnapshot(snap([("3", [w(7, "Ghostty", "deploy done")])], [("o5", [])]))
        // An answer for a fingerprint whose TEXT moved meanwhile keeps the summary and waits for the age gate…
        let fp3 = cache.entries["3"]!.fingerprint
        cache.apply([.init(tag: "3", summary: "Later.", reason: "r")], asked: ["3": WhatsUpCache.Fingerprint(structure: fp3.structure, text: 0)], at: t0)
        precondition(cache.rows[0].summary?.summary == "Later.")
        precondition(cache.due(at: t0).isEmpty, "text moved during the call: not due until the age gate")
        precondition(cache.due(at: t0.addingTimeInterval(WhatsUpCache.textRefreshAge)) == ["3"])
        // …whereas a moved window set is due at once.
        cache.apply([.init(tag: "3", summary: "Later2.", reason: "r")], asked: ["3": WhatsUpCache.Fingerprint(structure: 0, text: fp3.text)], at: t0)
        precondition(cache.due(at: t0) == ["3"], "window set moved during the call: due now")
    }

    @MainActor final class RecordingRunner: AskRunning {
        var onFinished: ((Ask.Outcome) -> Void)?
        var prompts: [String] = []
        var completions: [(Ask.Outcome) -> Void] = []
        var running = false

        func start(_ request: Ask.Request) {
            prompts.append(request.prompt)
            completions.append(onFinished!)
            running = true
        }
        func cancel() { running = false }
    }

    /// A controllable clock; even a cancelled sleep can resume, as can an
    /// already enqueued callback in production. The cache must reject it.
    @MainActor final class SuspendedClock {
        var sleepers: [CheckedContinuation<Void, Never>] = []
        func wait(_ seconds: TimeInterval) async throws {
            await withCheckedContinuation { sleepers.append($0) }
        }
        func resume() {
            let waiting = sleepers
            sleepers = []
            for continuation in waiting { continuation.resume() }
        }
    }

    @MainActor static func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @MainActor static func checkMonitoringPrivacy() async {
        let suite = "mcmonad-privacy-checks-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let runner = RecordingRunner()
        let clock = SuspendedClock()
        var quiet = true
        var reads = 0
        let cache = WhatsUpCache(text: { _ in reads += 1; return "private screen text" },
                                 textHash: { _ in 1 }, quiet: { quiet }, preferences: preferences,
                                 runner: runner, wait: clock.wait)
        let window = OverlayWindowEntry(windowId: 7, pid: 1, appName: "App", title: "private title",
                                         bundleId: nil, workspaceTag: nil, frame: .zero,
                                         isFocused: true, isFloating: false)
        let snap = OverlaySnapshot(debugOverlays: false, screens: [],
                                    hiddenWorkspaces: [.init(tag: "hidden", windows: [window])],
                                    ignoredWindows: [])
        precondition(!cache.isEnabled, "fresh installs must not send background screen data")
        cache.noteSnapshot(snap)
        cache.noteTextChanged()
        cache.refreshNow()
        cache.refreshNow(force: true)
        await settle()
        precondition(runner.prompts.isEmpty && reads == 0 && clock.sleepers.isEmpty,
                     "neither idle nor forced refresh may bypass the off switch")

        cache.setEnabled(true)
        await settle()
        precondition(!clock.sleepers.isEmpty)
        quiet = false
        clock.resume()
        await settle()
        precondition(runner.prompts.isEmpty, "returning to the keyboard revokes a queued idle call")

        quiet = true
        cache.noteTextChanged()
        await settle()
        precondition(!clock.sleepers.isEmpty)
        cache.setEnabled(false)
        quiet = false
        cache.setEnabled(true)
        clock.resume()
        await settle()
        precondition(runner.prompts.isEmpty, "off/on must not revive old queued work")

        cache.refreshNow(force: true)
        precondition(runner.prompts.count == 1 && runner.running && reads == 1)
        precondition(runner.prompts[0].contains("private title") && runner.prompts[0].contains("private screen text"),
                     "explicit opt-in exercises the real prompt builder")
        let oldCompletion = runner.completions[0]
        cache.setEnabled(false)
        precondition(!runner.running && !cache.isRefreshing && cache.rows.isEmpty)
        cache.noteSnapshot(snap)
        cache.noteTextChanged()
        cache.refreshNow(force: true)
        precondition(runner.prompts.count == 1)
        let answer = Ask.Outcome.answered(.workspaces(summaries: [.init(tag: "hidden", summary: "Private summary", reason: "evidence")], droppedUnknownTags: 0))
        oldCompletion(answer)
        precondition(cache.rows.isEmpty, "a late answer cannot restore cleared summaries")

        cache.setEnabled(true)
        cache.refreshNow(force: true)
        precondition(runner.prompts.count == 2 && cache.isRefreshing)
        oldCompletion(answer)
        precondition(cache.isRefreshing && cache.summariesAsOf == nil,
                     "an old answer cannot complete a newly authorised call")
        runner.completions[1](answer)
        precondition(cache.rows.first?.summary?.summary == "Private summary")

        quiet = true
        cache.noteSnapshot(OverlaySnapshot(debugOverlays: false,
            screens: [.init(screenId: 0, frame: .zero, workspaceTag: "new", isActive: true, windows: [window])],
            hiddenWorkspaces: [], ignoredWindows: []))
        cache.refreshNow() // queues the minimum-gap retry
        await settle()
        precondition(!clock.sleepers.isEmpty)
        cache.setEnabled(false)
        clock.resume()
        await settle()
        precondition(runner.prompts.count == 2 && cache.rows.isEmpty, "off cancels rate-limited retries too")

        let restarted = WhatsUpCache(text: { _ in nil }, textHash: { _ in nil }, quiet: { true },
                                     preferences: preferences, runner: RecordingRunner())
        precondition(!restarted.isEnabled, "the off choice survives restart")
        cache.setEnabled(true)
        let optedIn = WhatsUpCache(text: { _ in nil }, textHash: { _ in nil }, quiet: { false },
                                   preferences: preferences, runner: RecordingRunner())
        precondition(optedIn.isEnabled, "only an explicit opt-in survives restart")
        cache.setEnabled(false)
        await settle()
        clock.resume()
        await settle()
    }

    // MARK: RecentUse

    /// The real runner against a fake `claude`: a shell script that prints
    /// stream-json lines. No network, no real CLI.
    @MainActor static func checkAskRunner() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcmonad-ask-checks-\(UUID())")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func fake(_ name: String, _ body: String) -> String {
            let path = dir.appendingPathComponent(name).path
            try! ("#!/bin/sh\ncat > /dev/null\n" + body).write(toFile: path, atomically: true, encoding: .utf8)
            try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            return path
        }
        let initLine = #"{"type":"system","subtype":"init","model":"m","tools":["StructuredOutput"],"mcp_servers":[],"permissionMode":"dontAsk"}"#
        let result = #"{"type":"result","subtype":"success","is_error":false,"num_turns":2,"usage":{"input_tokens":1300,"output_tokens":200,"cache_read_input_tokens":5},"structured_output":{"matches":[{"id":7,"reason":"SECRET-REASON"}]}}"#
        let good = fake("good", "echo '\(initLine)'\necho '\(result)'\n")
        let silent = fake("silent", "echo '\(result)'\n")
        let broken = fake("broken", "echo SECRET-STDERR >&2\nexit 3\n")
        // Screen text in the prompt, the model's words in the answer, an
        // error's words on stderr: none of them may reach a log line.
        let request = Ask.Request(kind: .whereIs, systemPrompt: "s", schema: WhereIs.schemaJSON, prompt: "SECRET-SCREEN-TEXT",
                                  answer: { WhereIs.answer(from: $0, known: [7]) })
        let answered = Ask.Outcome.answered(.windows(matches: [.init(windowId: 7, reason: "SECRET-REASON")], droppedUnknownIds: 0))
        let token = String(repeating: "k", count: 40)
        var apiKeys: [String] = []
        var logged: [String] = []
        let ledger = AskLedger(write: { logged.append($0) })
        func run(_ settings: ClaudeAccess.Settings) async -> Ask.Outcome {
            let runner = AskRunner(ledger: ledger, loadSettings: { .success(settings) },
                                   callAPI: { _, key in apiKeys.append(key); return (answered, Ask.Facts(detail: "end_turn", turns: 1)) })
            return await withCheckedContinuation { done in
                runner.onFinished = { done.resume(returning: $0) }
                runner.start(request)
            }
        }
        let first = await run(ClaudeAccess.Settings(cli: good))
        precondition(first == answered, "\(first)")
        // Its receipt: the route, how it ended, turns and tokens, how many
        // windows the answer named.
        let receipt = ledger.recent()[0]
        precondition(receipt.kind == .whereIs && receipt.end == .answered && receipt.named == 1 && receipt.dropped == 0)
        precondition(receipt.legs.count == 1 && receipt.legs[0].route == .sdk && receipt.legs[0].end == .answered)
        precondition(receipt.legs[0].facts == Ask.Facts(detail: "success", usage: Ask.Usage(input: 1300, output: 200, cacheRead: 5), turns: 2))
        precondition(logged.count == 1 && logged[0].hasPrefix("ASK: id=\(receipt.id) kind=where-is model=\(Ask.model)")
                     && logged[0].contains(" end=answered ") && logged[0].contains(" sdk=answered/success,")
                     && logged[0].contains(",turns=2,tokens=1300+200,cache=5+0"), logged[0])
        guard case .failed(let why) = await run(ClaudeAccess.Settings(cli: silent)), why.contains("not believed") else {
            preconditionFailure("an answer from a session that never described itself was believed")
        }
        precondition(apiKeys.isEmpty, "no API route without a key source")
        // The SDK route fails; the API answers, with the key the command printed.
        let fellBack = await run(ClaudeAccess.Settings(cli: broken, apiKey: .command(["/bin/echo", token])))
        precondition(fellBack == answered, "\(fellBack)")
        precondition(apiKeys == [token])
        let both = ledger.recent()[0].legs
        precondition(both.map(\.route) == [.sdk, .api] && both.map(\.end) == [.failed, .answered]
                     && both[0].facts.detail == "exit-3" && both[1].facts.detail == "end_turn", "\(both)")
        // An answer in the wrong shape is not asked again elsewhere.
        let prose = fake("prose", "echo '\(initLine)'\necho '{\"type\":\"result\",\"is_error\":false,\"result\":\"prose\"}'\n")
        guard case .malformed = await run(ClaudeAccess.Settings(cli: prose, apiKey: .command(["/bin/echo", token]))) else {
            preconditionFailure("malformed")
        }
        precondition(apiKeys.count == 1)
        // A cancelled run reports nothing, and a key command that fails says so.
        let slow = fake("slow", "sleep 30\n")
        let runner = AskRunner(ledger: ledger, loadSettings: { .success(ClaudeAccess.Settings(cli: slow)) },
                               callAPI: { _, _ in (answered, Ask.Facts()) })
        var reported = 0
        runner.onFinished = { _ in reported += 1 }
        runner.start(request)
        try? await Task.sleep(for: .milliseconds(300))
        runner.cancel()
        try? await Task.sleep(for: .milliseconds(300))
        precondition(reported == 0, "a cancelled run reported an outcome")
        precondition(ledger.recent()[0].end == .cancelled, "a cancelled run left no receipt")
        // A CLI that ignores SIGTERM is killed: it holds the prompt.
        let pidFile = dir.appendingPathComponent("stubborn.pid").path
        let stubborn = fake("stubborn", "trap '' TERM\necho $$ > '\(pidFile)'\nwhile :; do sleep 1; done\n")
        let holder = AskRunner(ledger: ledger, loadSettings: { .success(ClaudeAccess.Settings(cli: stubborn)) },
                               callAPI: { _, _ in (answered, Ask.Facts()) })
        holder.onFinished = { _ in reported += 1 }
        holder.start(request)
        try? await Task.sleep(for: .milliseconds(500))
        guard let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
              let stubbornPid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            preconditionFailure("the stubborn CLI did not start")
        }
        holder.cancel()
        try? await Task.sleep(for: .milliseconds(Int(AskRunner.killGrace * 1000) + 1000))
        precondition(kill(stubbornPid, 0) != 0, "a CLI that ignored SIGTERM outlived its question")
        precondition(reported == 0)
        // Cancelled in the same turn it started: no CLI is launched at all.
        let marker = dir.appendingPathComponent("launched").path
        let witness = fake("witness", "touch '\(marker)'\n")
        let eager = AskRunner(ledger: ledger, loadSettings: { .success(ClaudeAccess.Settings(cli: witness)) },
                              callAPI: { _, _ in (answered, Ask.Facts()) })
        eager.onFinished = { _ in reported += 1 }
        eager.start(request)
        eager.cancel()
        try? await Task.sleep(for: .milliseconds(500))
        precondition(reported == 0 && !FileManager.default.fileExists(atPath: marker), "a run cancelled before it began still ran")
        guard case .unavailable(let reasons) = await run(ClaudeAccess.Settings(cli: broken, apiKey: .command(["/usr/bin/false"]))),
              reasons.contains("SDK:"), reasons.contains("API key:"), reasons.contains("SECRET-STDERR") else { preconditionFailure("both reasons") }
        precondition(ledger.recent()[0].legs.map(\.facts.detail) == ["exit-3", "key"])
        // What reached the screen stays off the log.
        precondition(!logged.isEmpty && !logged.contains { $0.contains("SECRET") }, "\(logged)")
        // Kept in memory only: still in the ledger, no longer in the log.
        let quiet = logged.count
        var memoryOnly = ClaudeAccess.Settings(cli: good)
        memoryOnly.retention.receipts = .memory
        _ = await run(memoryOnly)
        precondition(logged.count == quiet && ledger.recent()[0].end == .answered && ledger.retention.receipts == .memory)
        // A key command that exits but leaves a child holding its output
        // open does not hang the question: the deadline answers.
        let started = Date()
        guard case .failure = await ClaudeRoutes.fetch(.command(["/bin/sh", "-c", "sleep 5 & echo \(token)"]), deadline: 1) else {
            preconditionFailure("a held-open pipe was believed")
        }
        precondition(Date().timeIntervalSince(started) < 3, "the deadline did not answer")
        guard case .success(token) = await ClaudeRoutes.fetch(.command(["/bin/echo", token])),
              case .failure = await ClaudeRoutes.fetch(.command(["/nonexistent/key-command"])) else {
            preconditionFailure("key commands")
        }
    }

    /// Receipts, the ledger and its retention, and the settings that name it.
    @MainActor static func checkAskReceipts() {
        // Only the result line has facts; a detail that could carry words carries nothing.
        precondition(Ask.Facts.ofResultLine(#"{"type":"assistant"}"#) == nil && Ask.Facts.ofResultLine("x") == nil)
        let facts = Ask.Facts.ofResultLine(#"{"type":"result","subtype":"error_max_turns","num_turns":4,"usage":{"input_tokens":9,"output_tokens":1}}"#)
        precondition(facts == Ask.Facts(detail: "error_max_turns", usage: Ask.Usage(input: 9, output: 1), turns: 4), "\(String(describing: facts))")
        precondition(Ask.Facts(detail: "Not logged in").detail == nil && Ask.Facts(detail: "http-529").detail == "http-529")
        precondition(Ask.Facts(detail: String(repeating: "a", count: 41)).detail == nil)
        precondition(Ask.Usage(["input_tokens": 1]) == nil && Ask.Usage(nil) == nil)
        // A receipt closes with counts, and renders without words.
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var r = Ask.Receipt(id: "abcd1234", kind: .whatsUp, model: "m", effort: "low", started: t0)
        r.legs = [Ask.Leg(route: .sdk, seconds: 1.25, end: .timedOut, facts: Ask.Facts()),
                  Ask.Leg(route: .api, seconds: 2, end: .answered, facts: Ask.Facts(detail: "end_turn", usage: Ask.Usage(input: 1500, output: 100), turns: 1))]
        r.close(.answered(.workspaces(summaries: [.init(tag: "3", summary: "SECRET", reason: "r")], droppedUnknownTags: 2)), at: t0.addingTimeInterval(3.5))
        precondition(r.end == .answered && r.named == 1 && r.dropped == 2 && r.tokens == 1600 && r.seconds == 3.5)
        precondition(r.logLine == "ASK: id=abcd1234 kind=whats-up model=m effort=low end=answered seconds=3.5 named=1 dropped=2"
                     + " sdk=timed-out,1.2s api=answered/end_turn,2.0s,turns=1,tokens=1500+100,cache=0+0", r.logLine)
        precondition(r.menuLine(clock: { _ in "21:40" }) == "21:40  whats-up  answered in 3.5 s via sdk→api · 1.6k tokens · 1 named",
                     r.menuLine(clock: { _ in "21:40" }))
        var timedOut = Ask.Receipt(id: "x", kind: .whereIs, model: "m", effort: "low", started: t0)
        timedOut.close(.failed("no answer"), end: .timedOut, at: t0)
        precondition(timedOut.end == .timedOut && timedOut.named == nil)
        // The ledger keeps receipts for the policy's hours, at most `cap`, newest first.
        var lines: [String] = []
        let ledger = AskLedger(write: { lines.append($0) })
        func receipt(_ id: String, _ at: Date) -> Ask.Receipt { Ask.Receipt(id: id, kind: .whereIs, model: "m", effort: "e", started: at) }
        ledger.record(receipt("old", t0), under: nil, at: t0)
        ledger.record(receipt("new", t0.addingTimeInterval(3600)), under: Ask.Retention(receipts: .log, hours: 1), at: t0.addingTimeInterval(3600))
        precondition(ledger.recent(at: t0.addingTimeInterval(3600)).map(\.id) == ["new", "old"])
        precondition(ledger.recent(at: t0.addingTimeInterval(3601)).map(\.id) == ["new"], "an hour's policy keeps an hour")
        precondition(lines.count == 2)
        ledger.record(receipt("hushed", t0.addingTimeInterval(3700)), under: Ask.Retention(receipts: .memory, hours: 1), at: t0.addingTimeInterval(3700))
        precondition(lines.count == 2 && ledger.recent(at: t0.addingTimeInterval(3700)).first?.id == "hushed")
        // Unreadable settings keep the last policy.
        ledger.record(receipt("kept", t0.addingTimeInterval(3800)), under: nil, at: t0.addingTimeInterval(3800))
        precondition(lines.count == 2 && ledger.retention.receipts == .memory)
        for i in 0..<(AskLedger.cap + 10) { ledger.record(receipt("r\(i)", t0.addingTimeInterval(3900)), under: nil, at: t0.addingTimeInterval(3900)) }
        precondition(ledger.recent(at: t0.addingTimeInterval(3900)).count == AskLedger.cap)
        // claude.json's retention section: strict, like the rest of the file.
        func parse(_ json: String) -> Result<ClaudeAccess.Settings, ClaudeAccess.Problem> { ClaudeAccess.parse(Data(json.utf8)) }
        guard case .success(let none) = parse("{}"), none.retention == Ask.Retention(receipts: .log, hours: 24),
              case .success(let mem) = parse(#"{"retention":{"receipts":"memory","hours":6}}"#),
              mem.retention == Ask.Retention(receipts: .memory, hours: 6),
              case .success(let half) = parse(#"{"retention":{"hours":168}}"#), half.retention.receipts == .log else {
            preconditionFailure("retention settings")
        }
        for bad in [#"{"retention":{"receipts":"disk"}}"#, #"{"retention":{"hours":0}}"#, #"{"retention":{"hours":169}}"#,
                    #"{"retention":{"hours":2.5}}"#, #"{"retention":{"hours":true}}"#, #"{"retention":{"keep":"all"}}"#,
                    #"{"retention":"memory"}"#] {
            guard case .failure = parse(bad) else { preconditionFailure("accepted \(bad)") }
        }
    }

    static func checkRecency() {
        let stamps: [String: UInt64] = ["b": 5, "d": 9]
        let ordered = RecentUse.order(["a", "b", "c", "d"]) { stamps[$0] ?? 0 }
        precondition(ordered == ["d", "b", "a", "c"], "\(ordered)")
        precondition(RecentUse.order([String]()) { _ in 0 } == [])
        precondition(RecentUse.window(12) == "w:12")
        precondition(RecentUse.app(bundleId: "com.x", path: "/p") == "a:com.x")
        precondition(RecentUse.app(bundleId: nil, path: "/p") == "a:/p")
    }

    // MARK: OverlayScreenEntry wire

    static func checkOverlayScreenWire() {
        for active in [true, false] {
            let entry = OverlayScreenEntry(screenId: 1, frame: .zero, workspaceTag: "2", isActive: active, windows: [])
            let data = try! JSONEncoder().encode(entry)
            let back = try! JSONDecoder().decode(OverlayScreenEntry.self, from: data)
            precondition(back.isActive == active && back.screenId == 1 && back.workspaceTag == "2", "\(active)")
        }
    }

    // MARK: Query socket lookup

    static func checkWorkspaceWindowLookup() {
        func w(_ id: UInt32) -> OverlayWindowEntry {
            OverlayWindowEntry(windowId: id, pid: 1, appName: nil, title: nil, bundleId: nil,
                               workspaceTag: nil, frame: .zero, isFocused: false, isFloating: false)
        }
        let left = CGRect(x: 0, y: 0, width: 100, height: 100)
        let right = CGRect(x: 100, y: 0, width: 100, height: 100)
        let snap = OverlaySnapshot(debugOverlays: false, screens: [
            OverlayScreenEntry(screenId: 0, frame: left, workspaceTag: "1", isActive: true, windows: [w(1), w(2)]),
            OverlayScreenEntry(screenId: 1, frame: right, workspaceTag: "2", isActive: false, windows: [w(3)]),
        ], hiddenWorkspaces: [], ignoredWindows: [])
        precondition(WorkspaceWindowLookup.windowIds(forScreenFrame: left, in: snap, ignoredWindowIds: { _ in [] }) == [1, 2])
        precondition(WorkspaceWindowLookup.windowIds(forScreenFrame: right, in: snap, ignoredWindowIds: { _ in [] }) == [3])
        precondition(WorkspaceWindowLookup.windowIds(forScreenFrame: left, in: snap, ignoredWindowIds: { _ in [50] }) == [1, 2, 50], "ignored ids follow the screen windows")
        // a frame a few pixels off still resolves to the nearest screen
        precondition(WorkspaceWindowLookup.windowIds(forScreenFrame: CGRect(x: 102, y: 1, width: 100, height: 100), in: snap, ignoredWindowIds: { _ in [] }) == [3])
        precondition(WorkspaceWindowLookup.windowIds(forScreenFrame: left, in: nil, ignoredWindowIds: { _ in [] }) == [])
        let empty = OverlaySnapshot(debugOverlays: false, screens: [], hiddenWorkspaces: [], ignoredWindows: [])
        precondition(WorkspaceWindowLookup.windowIds(forScreenFrame: left, in: empty, ignoredWindowIds: { _ in [] }) == [])
    }

    // MARK: Parking geometry

    static func checkParkGeometry() {
        func info(_ id: Int, _ frame: CGRect) -> ScreenInfo {
            ScreenInfo(screenId: id, frame: frame, uuid: "u\(id)", name: "s\(id)", role: .primary)
        }
        let size = CGSize(width: 400, height: 300)
        let left = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let right = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        let pair = [info(0, left), info(1, right)]

        func parked(_ origin: CGPoint, _ screens: [ScreenInfo]) -> Bool {
            isAlreadyParked(CGRect(origin: origin, size: size), screens: screens)
        }

        // alone: the bottom-right corner
        let solo = [info(0, left)]
        precondition(parkOrigin(for: left, among: solo, windowSize: size) == CGPoint(x: 999, y: 799))

        // beside another screen: the bottom-right corner would leave a row
        // on the neighbour, so the window hangs off the free left edge
        precondition(parkOrigin(for: left, among: pair, windowSize: size) == CGPoint(x: -399, y: 799))
        precondition(parkOrigin(for: right, among: pair, windowSize: size) == CGPoint(x: 1999, y: 799))

        // whatever is picked reads as parked, and a flush tile does not
        precondition(parked(parkOrigin(for: left, among: pair, windowSize: size), pair))
        precondition(!isAlreadyParked(CGRect(x: 0, y: 0, width: 500, height: 800), screens: pair), "half tile is not parked")
        precondition(!isAlreadyParked(left, screens: pair), "full screen is not parked")
        precondition(!isAlreadyParked(CGRect(x: 1000, y: 0, width: 500, height: 800), screens: pair),
                     "a tile at the right screen's left edge is not parked")

        // three in a row, bottoms aligned: the outer screens use their free
        // edges; the middle one has none, keeps the window's size, and
        // parks at its own bottom-right corner (a one-point row on the
        // right neighbour, nothing more)
        let third = CGRect(x: 2000, y: 0, width: 1000, height: 800)
        let row = [info(0, left), info(1, right), info(2, third)]
        precondition(parkOrigin(for: left, among: row, windowSize: size) == CGPoint(x: -399, y: 799))
        precondition(parkOrigin(for: third, among: row, windowSize: size) == CGPoint(x: 2999, y: 799))
        let mid = parkOrigin(for: right, among: row, windowSize: size)
        precondition(mid == CGPoint(x: 1999, y: 799), "\(mid)")
        precondition(parked(mid, row))
        precondition(homeScreen(for: CGRect(origin: mid, size: size), among: row)?.screenId == 1,
                     "the middle screen's park still belongs to the middle screen")

        // three in a row, the middle one shorter than both neighbours: its
        // own corners would put the window in full view on a neighbour, so
        // it parks at the nearest display corner that shows nothing
        let tallL = CGRect(x: 0, y: 0, width: 1000, height: 1200)
        let short = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        let tallR = CGRect(x: 2000, y: 0, width: 1000, height: 1200)
        let valley = [info(0, tallL), info(1, short), info(2, tallR)]
        let out = parkOrigin(for: short, among: valley, windowSize: size)
        precondition(parked(out, valley), "\(out)")
        precondition(!valley.contains { $0.screenId == 1 && $0.frame.intersects(CGRect(origin: out, size: size)) },
                     "parked on a neighbour's corner, off its own screen: \(out)")

        // a laptop below a row of three: every screen still gets a park
        // that keeps the window's size
        let below = CGRect(x: 1000, y: 800, width: 1000, height: 700)
        let stacked = row + [info(3, below)]
        for s in stacked {
            precondition(parked(parkOrigin(for: s.frame, among: stacked, windowSize: size), stacked), "\(s.screenId)")
        }
    }

    // MARK: Parked window home

    static func checkParkedHome() {
        func info(_ id: Int, _ frame: CGRect) -> ScreenInfo {
            ScreenInfo(screenId: id, frame: frame, uuid: "u\(id)", name: "s\(id)", role: .primary)
        }
        let screens = [info(0, CGRect(x: 0, y: 0, width: 1000, height: 800)),
                       info(1, CGRect(x: 1000, y: 0, width: 1000, height: 800))]
        // the corner parks chosen by freeCorner resolve back to their own screen
        precondition(homeScreen(for: CGRect(x: 1999, y: 799, width: 400, height: 300), among: screens)?.screenId == 1)
        precondition(homeScreen(for: CGRect(x: -399, y: 799, width: 400, height: 300), among: screens)?.screenId == 0)
        precondition(homeScreen(for: CGRect(x: 5000, y: 5000, width: 10, height: 10), among: screens) != nil, "no overlap still yields a screen")
        precondition(homeScreen(for: .zero, among: []) == nil)
        precondition(centeredFrame(of: CGSize(width: 400, height: 300), on: CGRect(x: 0, y: 0, width: 1000, height: 800))
            == CGRect(x: 300, y: 250, width: 400, height: 300))
        precondition(centeredFrame(of: CGSize(width: 400, height: 300), on: CGRect(x: 1000, y: 0, width: 1000, height: 800))
            == CGRect(x: 1300, y: 250, width: 400, height: 300))
    }
}
