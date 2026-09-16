// Compiled with the launcher's pure files (TextSearch, RecentUse,
// WhereIsProtocol, Protocol) and run by the Nix package checkPhase.
import Foundation
import CoreGraphics

@main
enum LauncherLogicChecks {
    static func main() {
        checkTerms()
        checkHits()
        checkRanges()
        checkReadingOrder()
        checkWhereIsQuery()
        checkManifold()
        checkStream()
        checkRecency()
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
                OverlayScreenEntry(screenId: 0, frame: .zero, workspaceTag: "3",
                                   windows: [w(7, "Ghostty", "deploy notes", focused: true)]),
                OverlayScreenEntry(screenId: 1, frame: .zero, workspaceTag: "2", windows: []),
            ],
            hiddenWorkspaces: [
                OverlayHiddenWorkspace(tag: "o5", windows: [w(9, "Chrome", "cats"), w(11, "?", "")]),
                OverlayHiddenWorkspace(tag: "z", windows: []),
            ]
        )
        let m = WhereIs.manifold(question: "the deploy", snapshot: snap,
                                 text: { $0 == 9 ? "a  b\nc" : nil }, budget: 30, perWindow: 100)
        precondition(m.currentWorkspace == "3")
        precondition(m.workspaces.map(\.tag) == ["3", "o5"], "\(m.workspaces.map(\.tag))")
        precondition(m.workspaces[0].onScreen && !m.workspaces[1].onScreen)
        precondition(m.workspaces[0].windows == [WhereIs.ManifoldWindow(id: 7, app: "Ghostty", title: "deploy notes", focused: true, text: nil)])
        // Budget 30 over 3 windows → 10 chars per window.
        precondition(m.workspaces[1].windows[0].text == "a b c")
        precondition(m.workspaces[1].windows[1].text == nil)
        let big = WhereIs.manifold(question: "q", snapshot: snap,
                                   text: { _ in String(repeating: "t", count: 50) }, budget: 30, perWindow: 100)
        precondition(big.workspaces[0].windows[0].text == String(repeating: "t", count: 10) + "…")
        let prompt = WhereIs.prompt(for: m)
        precondition(prompt.hasPrefix("Where is: the deploy\n\nManifold:\n{\"current_workspace\":\"3\""), prompt)
        precondition(prompt.contains("\"on_screen\":true"))
        precondition(WhereIs.arguments.contains("--no-session-persistence"))
        precondition(WhereIs.arguments.contains("--json-schema"))
        precondition(WhereIs.candidates(home: "/h", path: "/usr/bin:/opt/homebrew/bin")
                     == ["/h/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "/usr/bin/claude"])
    }

    static func checkStream() {
        let known: Set<UInt32> = [7, 9]
        let delta = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{\"matches\":["}}}"#
        precondition(WhereIs.parseLine(delta, known: known) == .delta("{\"matches\":["))
        let textDelta = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}}"#
        precondition(WhereIs.parseLine(textDelta, known: known) == .delta("hi"))
        precondition(WhereIs.parseLine(#"{"type":"system","subtype":"init"}"#, known: known) == .ignore)
        precondition(WhereIs.parseLine("not json", known: known) == .ignore)
        precondition(WhereIs.parseLine("", known: known) == .ignore)

        let ok = #"{"type":"result","subtype":"success","is_error":false,"result":"…","structured_output":{"matches":[{"id":7,"reason":"title says deploy"},{"id":9,"reason":"cats"},{"id":7,"reason":"dup"},{"id":4242,"reason":"made up"},{"id":-1,"reason":"neg"},{"reason":"no id"}]}}"#
        precondition(WhereIs.parseLine(ok, known: known) == .final(.answered(
            matches: [.init(windowId: 7, reason: "title says deploy"), .init(windowId: 9, reason: "cats")],
            droppedUnknownIds: 4)))
        let empty = #"{"type":"result","is_error":false,"structured_output":{"matches":[]}}"#
        precondition(WhereIs.parseLine(empty, known: known) == .final(.answered(matches: [], droppedUnknownIds: 0)))
        let failed = #"{"type":"result","is_error":true,"result":"Not logged in"}"#
        precondition(WhereIs.parseLine(failed, known: known) == .final(.failed("Not logged in")))
        let malformed = #"{"type":"result","is_error":false,"result":"plain prose"}"#
        precondition(WhereIs.parseLine(malformed, known: known) == .final(.malformed("plain prose")))
    }

    // MARK: RecentUse

    static func checkRecency() {
        let stamps: [String: UInt64] = ["b": 5, "d": 9]
        let ordered = RecentUse.order(["a", "b", "c", "d"]) { stamps[$0] ?? 0 }
        precondition(ordered == ["d", "b", "a", "c"], "\(ordered)")
        precondition(RecentUse.order([String]()) { _ in 0 } == [])
        precondition(RecentUse.window(12) == "w:12")
        precondition(RecentUse.app(bundleId: "com.x", path: "/p") == "a:com.x")
        precondition(RecentUse.app(bundleId: nil, path: "/p") == "a:/p")
    }
}
