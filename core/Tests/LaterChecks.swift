// AI-generated text: model claude-opus-5-5; reasoning effort unavailable (not exposed by the harness).
//
// Compiled with Later/LaterModel.swift and Later/LaterInbox.swift and run by
// the Nix package checkPhase. The protocol fixtures are what beads-mcmonad's
// `later` (1decc55) printed; the inbox checks run a stand-in `later` (a shell
// script) through the same process code the daemon uses.
import Foundation

@main
enum LaterChecks {
    static func main() async {
        checkVerb()
        checkProtocol()
        checkRequest()
        checkRows()
        checkScale()
        await checkInbox()
        print("Later checks passed")
    }

    static func expect(_ ok: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
        if !ok {
            print("FAILED: \(what) (\(file):\(line))")
            exit(1)
        }
    }

    // MARK: The verb

    static func checkVerb() {
        expect(LaterVerb.words(in: "later check the pangram API") == "check the pangram API", "later + words")
        expect(LaterVerb.words(in: "todo p1 split rageveil") == "p1 split rageveil", "the priority is later's to read")
        expect(LaterVerb.words(in: "Later: ask about h10n") == "ask about h10n", "dictated punctuation")
        expect(LaterVerb.words(in: "To do, call the bank") == "call the bank", "dictated 'to do'")
        expect(LaterVerb.words(in: "  later  ") == "", "the verb alone")
        expect(LaterVerb.words(in: "latergator") == nil, "a longer word is not the verb")
        expect(LaterVerb.words(in: "todoist") == nil, "an app name is not the verb")
        expect(LaterVerb.words(in: "timer 5 later") == nil, "the verb must come first")
        expect(LaterVerb.words(in: "") == nil, "empty")
    }

    // MARK: Protocol 1, as later printed it

    static let snapshotJSON = """
    {"protocol":1,"readAt":"2026-11-15T22:16:32.183032Z","unreadable":[],"beads":[
     {"id":"later-u3r","title":"check pangram API","status":"open","standing":"ready","priority":1,
      "createdAt":"2026-11-15T22:16:30Z","deferUntil":null,"labels":["app:ghostty","mcmonad","ws:3"],
      "origin":{"window":{"kind":"mac","windowId":123,"pid":456},"app":"Ghostty","title":"codex","workspace":"3",
                "screenshot":"/later/attachments/20261115-221623.png","savedAt":"2026-11-15T22:16:23.759672Z"},
      "waitsFor":[],"actions":["start","prompt","snooze","done"]},
     {"id":"later-lwp","title":"after it","status":"open","standing":"waiting","priority":2,
      "createdAt":"2026-11-15T22:16:30Z","deferUntil":null,"labels":["later"],"origin":null,"waitsFor":["later-u3r"],
      "actions":["prompt","snooze"]}]}
    """

    static let startedJSON = """
    {"protocol":1,"id":"later-u3r","prompt":"check pangram API\\n\\n(Saved for later as later-u3r on 2026-11-15 22:16 from Ghostty — “codex”. `later show later-u3r` prints everything saved with it.)","claimed":true,
     "origin":{"window":{"kind":"wayland","identifier":"toplevel-9"},"app":"foot","title":"","workspace":null,"screenshot":null,"savedAt":"2026-11-15T22:16:23Z"}}
    """

    static func snapshot() -> LaterSnapshot {
        switch Later.decode(LaterSnapshot.self, Data(snapshotJSON.utf8), version: { $0.protocol }) {
        case .success(let s): return s
        case .failure(let e): expect(false, "the snapshot decodes: \(e)"); fatalError()
        }
    }

    static func checkProtocol() {
        let s = snapshot()
        expect(s.beads.map(\.id.raw) == ["later-u3r", "later-lwp"], "order is later's")
        expect(s.readyCount == 1 && s.startedCount == 0, "counts")
        expect(s.beads[0].origin?.window == .mac(windowId: 123, pid: 456), "mac window")
        expect(s.beads[0].origin?.screenshot == "/later/attachments/20261115-221623.png", "screenshot path")
        expect(s.beads[1].waitsFor == [BeadID(raw: "later-u3r")] && s.beads[1].standing == .waiting, "waits for")
        expect(s.beads[0].origin?.savedAt == Date.iso("2026-11-15T22:16:23.759672Z"), "fractional seconds")

        if case .success(let st) = Later.decode(LaterStarted.self, Data(startedJSON.utf8), version: { $0.protocol }) {
            expect(st.claimed && st.origin?.window == .wayland(identifier: "toplevel-9"), "started, from Linux")
        } else { expect(false, "started decodes") }

        let v2 = snapshotJSON.replacingOccurrences(of: "\"protocol\":1", with: "\"protocol\":2")
        if case .failure(let e) = Later.decode(LaterSnapshot.self, Data(v2.utf8), version: { $0.protocol }) {
            expect(e.description.contains("protocol 2"), "another version says which: \(e)")
        } else { expect(false, "protocol 2 must be refused") }
        if case .failure(let e) = Later.decode(LaterSnapshot.self, Data("later: no".utf8), version: { $0.protocol }) {
            expect(e.description.contains("later: no"), "garbage is quoted")
        } else { expect(false, "garbage must be refused") }
        let oddStanding = snapshotJSON.replacingOccurrences(of: "\"standing\":\"ready\"", with: "\"standing\":\"maybe\"")
        if case .success = Later.decode(LaterSnapshot.self, Data(oddStanding.utf8), version: { $0.protocol }) {
            expect(false, "a standing protocol 1 does not have is refused")
        }
    }

    static func checkRequest() {
        let source = LaterSource(window: .mac(windowId: 42, pid: 7), app: "Ghostty", title: "codex", workspace: nil)
        let data = Later.encode(LaterSaveRequest(words: "p1 note", source: source, screenshot: "/tmp/x.png", text: nil, missing: ["No text."]))
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        expect(json["protocol"] as? Int == 1 && json["words"] as? String == "p1 note", "version and words")
        let window = ((json["source"] as? [String: Any])?["window"] as? [String: Any]) ?? [:]
        expect(window["kind"] as? String == "mac" && window["windowId"] as? Int == 42 && window["pid"] as? Int == 7, "mac window: \(window)")
        expect(json["text"] == nil && (json["source"] as? [String: Any])?["workspace"] == nil, "absent stays absent")
        expect(json["screenshot"] as? String == "/tmp/x.png" && json["missing"] as? [String] == ["No text."], "capture")
    }

    // MARK: Rows

    static func checkRows() {
        let s = snapshot()
        let now = Date.iso("2026-11-15T23:00:00Z") ?? Date()
        let rows = Later.beadRows(s, now: now)
        expect(rows.count == 2 && rows[0].title == "◆ check pangram API" && rows[1].title == "◇ after it", "marks")
        expect(rows[0].detail?.contains("later-u3r · P1 · ready · Ghostty — codex · ws 3") == true, "detail: \(rows[0].detail ?? "")")
        expect(rows[1].detail?.contains("blocked") == true, "waiting on another bead is blocked")
        expect(rows[0].haystack.contains("pangram") && rows[0].haystack.contains("ghostty"), "searchable")

        let a = Later.actionRows(s.beads[0], originAlive: true)
        let ready = s.beads[0].id
        expect(a.map(\.action) == [.start(ready), .copyPrompt(ready), .openScreenshot(ready), .snooze(ready), .done(ready)],
               "the ready bead's actions, as later allows them")
        expect(a.first?.title.hasPrefix("Start: copy the prompt, and go back to codex") == true, "start, window alive")
        let gone = Later.actionRows(s.beads[0], originAlive: false)
        expect(gone.first?.title.contains("workspace 3") == true, "window gone: its workspace")
        let blocked = s.beads[1].id
        let b = Later.actionRows(s.beads[1], originAlive: false)
        expect(b.map(\.action) == [.copyPrompt(blocked), .snooze(blocked)], "a blocked bead is neither started nor closed")
        let woken = LaterBead(id: blocked, title: "t", status: "deferred", standing: .waiting, priority: 2, createdAt: Date(),
                              deferUntil: nil, labels: [], origin: nil, waitsFor: [], actions: ["wake", "prompt", "done", "teleport"])
        expect(Later.actionRows(woken, originAlive: false).map(\.action) == [.wake(blocked), .copyPrompt(blocked), .done(blocked)],
               "a snoozed bead is woken; an action this launcher does not know is left out")

        let src = LaterSource(window: .mac(windowId: 1, pid: 1), app: "Ghostty", title: "codex", workspace: "3")
        expect(Later.saveRow(words: "x", source: src, snapshot: s).title == "Save for later: “x” — with Ghostty — codex", "save with window")
        expect(Later.saveRow(words: "", source: src, snapshot: s).action == .save(""), "save the window itself")
        expect(Later.saveRow(words: "", source: nil, snapshot: s).action == .browse, "nothing to save: browse")
        expect(Later.viewRow.action == .openView && Later.viewRow.haystack.contains("graph"), "the page is findable as a graph")
    }

    static func checkScale() {
        let displays = [Later.Display(bounds: CGRect(x: 0, y: 0, width: 3440, height: 1440), scale: 1),
                        Later.Display(bounds: CGRect(x: -1728, y: 300, width: 1728, height: 1117), scale: 2)]
        expect(Later.scale(for: CGRect(x: 0, y: 30, width: 3440, height: 1410), displays: displays) == 1, "a window on the 1× display")
        expect(Later.scale(for: CGRect(x: -1700, y: 400, width: 800, height: 600), displays: displays) == 2, "a window on the 2× display")
        expect(Later.scale(for: CGRect(x: -200, y: 400, width: 1000, height: 600), displays: displays) == 1, "most of it decides")
        expect(Later.scale(for: CGRect(x: -1727, y: 1416, width: 900, height: 700), displays: displays) == 2, "a parked window")
        expect(Later.scale(for: CGRect(x: 9000, y: 9000, width: 10, height: 10), displays: displays) == 1, "on no display: 1×")
    }

    // MARK: `later`, through the real process code

    static func standIn() -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("later-checks-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("later").path
        let snapshot = snapshotJSON.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "'", with: "")
        let script = """
        #!/bin/sh
        # Stand-in for later: answers by command, keeps what it was sent.
        printf '%s\\n' "$@" > "$0.$1.args"
        case "$1" in
          snapshot) printf '%s' '\(snapshot)' ;;
          save)     cat > "$0.save.stdin"; printf '%s' '{"protocol":1,"id":"later-new","title":"t"}' ;;
          prompt)   printf 'the prompt\\n' ;;
          done)     echo "later: bd close failed with status 1: no issue found matching $2" >&2; exit 1 ;;
          snooze)   sleep 5 ;;
          start)    printf '%s' '{"protocol":2,"id":"x","prompt":"","claimed":false,"origin":null}' ;;
        esac
        """
        FileManager.default.createFile(atPath: path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o755])
        return path
    }

    static func checkInbox() async {
        let cli = standIn()
        let inbox = LaterInbox(cli: cli, deadline: 1)

        guard case .success(let s) = await inbox.snapshot() else { expect(false, "snapshot"); return }
        expect(s.beads.count == 2, "snapshot through a process")

        let source = LaterSource(window: .mac(windowId: 42, pid: 7), app: "Ghostty", title: "codex", workspace: "3")
        guard case .success(let saved) = await inbox.save(LaterSaveRequest(words: "p1 note", source: source, screenshot: nil, text: "x", missing: [])) else {
            expect(false, "save"); return
        }
        expect(saved.id == BeadID(raw: "later-new"), "saved id")
        let sent = (try? String(contentsOfFile: cli + ".save.stdin", encoding: .utf8)) ?? ""
        expect(sent.contains("\"words\":\"p1 note\"") && sent.contains("\"kind\":\"mac\""), "the request goes in on stdin: \(sent)")

        expect(await inbox.prompt(BeadID(raw: "later-u3r")) == .success("the prompt"), "prompt as text")
        let args = (try? String(contentsOfFile: cli + ".prompt.args", encoding: .utf8)) ?? ""
        expect(args == "prompt\nlater-u3r\n", "prompt arguments: \(args)")

        if case .failure(.exited(let verb, let status, let err)) = await inbox.done(BeadID(raw: "later-x")) {
            expect(verb == "done" && status == 1 && err == "bd close failed with status 1: no issue found matching later-x", "stderr kept, prefix dropped: \(err)")
        } else { expect(false, "a non-zero exit is a fault") }

        let t0 = Date()
        if case .failure(.timedOut(_, let secs)) = await inbox.snooze(BeadID(raw: "later-x")) {
            expect(secs == 1 && Date().timeIntervalSince(t0) < 4, "stopped at the deadline")
        } else { expect(false, "a hung call times out") }

        if case .failure(.malformed(let verb, let why)) = await inbox.start(BeadID(raw: "later-x")) {
            expect(verb == "start" && why.description.contains("protocol 2"), "a later of another protocol is refused")
        } else { expect(false, "protocol 2 from later must be refused") }

        if case .failure(.missing(let path)) = await LaterInbox(cli: "/nonexistent/later").snapshot() {
            expect(path == "/nonexistent/later", "a missing later says which path")
        } else { expect(false, "a missing later is a fault") }
    }
}
