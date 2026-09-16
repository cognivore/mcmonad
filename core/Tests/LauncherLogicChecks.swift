// Compiled with the launcher's pure files (TextSearch, RecentUse,
// AskProtocol, WhereIsProtocol, WhatsUp, Protocol) and run by the Nix
// package checkPhase.
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
        checkWhatsUp()
        checkWhatsUpCache()
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
        precondition(WhereIs.arguments.contains("--no-session-persistence"))
        precondition(WhereIs.arguments.contains("--json-schema"))
        precondition(WhereIs.arguments.contains(WhereIs.systemPrompt))
        precondition(Ask.candidates(home: "/h", path: "/usr/bin:/opt/homebrew/bin")
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
        precondition(WhereIs.parseLine(ok, known: known) == .final(.answered(.windows(
            matches: [.init(windowId: 7, reason: "title says deploy"), .init(windowId: 9, reason: "cats")],
            droppedUnknownIds: 4))))
        let empty = #"{"type":"result","is_error":false,"structured_output":{"matches":[]}}"#
        precondition(WhereIs.parseLine(empty, known: known) == .final(.answered(.windows(matches: [], droppedUnknownIds: 0))))
        let failed = #"{"type":"result","is_error":true,"result":"Not logged in"}"#
        precondition(WhereIs.parseLine(failed, known: known) == .final(.failed("Not logged in")))
        let malformed = #"{"type":"result","is_error":false,"result":"plain prose"}"#
        precondition(WhereIs.parseLine(malformed, known: known) == .final(.malformed("plain prose")))
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
                            screens: screens.enumerated().map { OverlayScreenEntry(screenId: $0.offset, frame: .zero, workspaceTag: $0.element.0, windows: $0.element.1) },
                            hiddenWorkspaces: hidden.map { OverlayHiddenWorkspace(tag: $0.0, windows: $0.1) })
        }
        var hashes: [UInt32: Int] = [7: 1]
        let cache = WhatsUpCache(text: { _ in nil }, textHash: { hashes[$0] })
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
        // An answer for a fingerprint that moved meanwhile keeps the workspace stale.
        let stale = ["3": WhatsUpCache.Fingerprint(structure: 0, text: 0)]
        cache.apply([.init(tag: "3", summary: "Later.", reason: "r")], asked: stale, at: t0)
        precondition(cache.rows[0].summary?.summary == "Later." && cache.due(at: t0.addingTimeInterval(WhatsUpCache.textRefreshAge)) == ["3"])
        precondition(cache.due(at: t0).isEmpty, "a moved-but-young text summary waits for the age gate")
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
