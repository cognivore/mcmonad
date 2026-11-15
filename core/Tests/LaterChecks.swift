// AI-generated text: model claude-opus-5-5; reasoning effort unavailable (not exposed by the harness).
//
// Compiled with Later/LaterModel.swift and Later/LaterInbox.swift and run by
// the Nix package checkPhase. The model checks use bd 1.3.4's real JSON
// shapes; the inbox checks run a stand-in CLI (a shell script) through the
// same process code the daemon uses.
import Foundation

@main
enum LaterChecks {
    static func main() async {
        checkSettings()
        checkNote()
        checkParse()
        checkSnapshot()
        checkComposition()
        checkRows()
        await checkInbox()
        print("Later checks passed")
    }

    static func expect(_ ok: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
        if !ok {
            print("FAILED: \(what) (\(file):\(line))")
            exit(1)
        }
    }

    // MARK: Settings

    static func checkSettings() {
        let f = "/h/.config/mcmonad/later.json"
        expect(LaterSettings.load(nil, file: f) == .off, "no file is off")
        let good = Data(#"{"cli": "/nix/store/x-later/bin/later", "attachments": "/h/.local/share/mcmonad/later/attachments"}"#.utf8)
        expect(LaterSettings.load(good, file: f) == .on(LaterSettings(cli: "/nix/store/x-later/bin/later",
                                                                     attachments: "/h/.local/share/mcmonad/later/attachments")),
               "a good file is on")
        if case .unusable(let why) = LaterSettings.load(Data(#"{"cli": "later", "attachments": "/a"}"#.utf8), file: f) {
            expect(why.contains("absolute") && why.contains(f), "a relative cli is refused, saying why and where")
        } else { expect(false, "a relative cli must be unusable") }
        if case .unusable(let why) = LaterSettings.load(Data("not json".utf8), file: f) {
            expect(why.contains(f), "garbage names the file")
        } else { expect(false, "garbage must be unusable") }
        if case .unusable = LaterSettings.load(Data(#"{"cli": "/x"}"#.utf8), file: f) {} else {
            expect(false, "a missing field is unusable, not off")
        }
    }

    // MARK: What the user types or says

    static func checkNote() {
        expect(LaterNote("later check the pangram API") == LaterNote(text: "check the pangram API", priority: nil), "later + text")
        expect(LaterNote("todo p1 split rageveil") == LaterNote(text: "split rageveil", priority: 1), "todo + priority")
        expect(LaterNote("Later: ask about h10n") == LaterNote(text: "ask about h10n", priority: nil), "dictated punctuation")
        expect(LaterNote("To do, call the bank") == LaterNote(text: "call the bank", priority: nil), "dictated 'to do'")
        expect(LaterNote("later") == LaterNote(text: "", priority: nil), "the verb alone")
        expect(LaterNote("  later   P0  ") == LaterNote(text: "", priority: 0), "spaces and upper-case priority")
        expect(LaterNote("later p9 thing") == LaterNote(text: "p9 thing", priority: nil), "p9 is not a priority")
        expect(LaterNote("latergator") == nil, "a longer word is not the verb")
        expect(LaterNote("todoist") == nil, "an app name is not the verb")
        expect(LaterNote("timer 5 later") == nil, "the verb must come first")
        expect(LaterNote("") == nil, "empty")
    }

    // MARK: Parsing bd's answers

    /// `bd list --json`, as bd 1.3.4 writes it.
    static let listJSON = """
    [
      {"id": "later-sqx", "title": "concurrent 3", "status": "in_progress", "priority": 2, "issue_type": "task",
       "assignee": "cognivore", "created_at": "2026-11-15T19:34:00Z", "updated_at": "2026-11-15T19:34:20Z",
       "dependency_count": 0, "dependent_count": 0, "comment_count": 0},
      {"id": "later-a9c", "title": "concurrent 2", "status": "deferred", "priority": 2, "issue_type": "task",
       "created_at": "2026-11-15T19:34:00Z", "defer_until": "2026-11-16T19:34:20Z"},
      {"id": "later-lq1", "title": "check pangram API for h10n", "description": "Captured.\\n", "status": "open",
       "priority": 1, "issue_type": "task", "created_at": "2026-11-15T19:33:39.446016Z",
       "metadata": {"mcmonad": {"app": "Ghostty", "pid": 456, "title": "codex", "windowId": 123,
                                "workspace": "3", "screenshot": "/tmp/x.png", "savedAt": "2026-11-15T19:33:39Z"}},
       "labels": ["app:ghostty", "ws:3"]},
      {"id": "later-zzz", "title": "made by an agent", "status": "open", "priority": 2,
       "created_at": "2026-11-15T18:00:00Z", "metadata": {"other-tool": {"x": 1}}},
      {"id": "later-bad", "title": "unreadable date", "status": "open", "created_at": "yesterday"},
      {"title": "no id", "status": "open", "created_at": "2026-11-15T18:00:00Z"},
      {"id": "later-ped", "title": "a custom status", "status": "pinned", "priority": 3,
       "created_at": "2026-11-15T17:00:00Z", "metadata": {"mcmonad": {"app": 7}}}
    ]
    """

    static func parsedList() -> BeadList {
        guard case .success(let list) = Later.parseList(Data(listJSON.utf8)) else {
            expect(false, "the list parses"); fatalError()
        }
        return list
    }

    static func checkParse() {
        let list = parsedList()
        expect(list.beads.map(\.id.raw) == ["later-sqx", "later-a9c", "later-lq1", "later-zzz", "later-ped"],
               "good beads kept in order")
        expect(list.unreadable == 2, "an unreadable date and a missing id are counted, not fatal")
        let lq1 = list.beads[2]
        expect(lq1.origin == BeadOrigin(windowId: 123, pid: 456, app: "Ghostty", title: "codex", workspace: "3",
                                        screenshot: "/tmp/x.png", savedAt: "2026-11-15T19:33:39Z"),
               "the launcher's origin is read back")
        expect(lq1.priority == 1 && lq1.labels == ["app:ghostty", "ws:3"] && lq1.description == "Captured.\n", "fields")
        expect(list.beads[3].origin == nil, "another tool's metadata is not an origin")
        expect(list.beads[4].origin == nil, "a malformed origin is dropped, the bead kept")
        expect(list.beads[4].status == .other("pinned"), "an unknown status is kept as written")
        expect(list.beads[1].deferUntil == Date.iso("2026-11-16T19:34:20Z"), "defer_until")
        expect(Date.iso("2026-11-15T19:33:39.446016Z") != nil, "fractional seconds")

        if case .failure(let e) = Later.parseList(Data(#"{"error": "no"}"#.utf8)) {
            expect(e.description.contains("JSON array") && e.description.contains("error"), "says what was expected and what came")
        } else { expect(false, "an object is not a list") }
        if case .success(let empty) = Later.parseList(Data("[]".utf8)) {
            expect(empty.beads.isEmpty && empty.unreadable == 0, "an empty inbox is valid")
        } else { expect(false, "[] parses") }

        let created = #"{"created_at": "2026-11-15T19:33:39.446016Z", "id": "later-new", "title": "t", "status": "open", "priority": 2, "schema_version": 1}"#
        expect((try? Later.parseOne(Data(created.utf8)).get())?.id.raw == "later-new", "bd create --json")
        if case .success = Later.parseOne(Data(#"{"id": "", "title": "t", "status": "open", "created_at": "2026-11-15T19:33:39Z"}"#.utf8)) {
            expect(false, "an empty id is not a bead")
        }
    }

    // MARK: The inbox as the launcher sees it

    static func checkSnapshot() {
        let list = parsedList()
        let ready = BeadList(beads: list.beads.filter { ["later-lq1", "later-zzz"].contains($0.id.raw) }, unreadable: 0)
        let s = LaterSnapshot(list: list, ready: ready, readAt: Date())
        expect(s.beads.map(\.id.raw) == ["later-sqx", "later-lq1", "later-zzz", "later-a9c", "later-ped"],
               "started, then ready by priority, then waiting by priority")
        expect(s.readyCount == 2 && s.startedCount == 1, "counts")
        expect(s.standing(s.bead(BeadID(raw: "later-a9c"))!) == .waiting, "snoozed is waiting")
        expect(s.unreadable == 2, "unreadable carried")

        let closed = Bead(id: BeadID(raw: "later-c"), title: "c", description: "", status: .closed, priority: 0,
                          labels: [], createdAt: Date(), deferUntil: nil, origin: nil)
        let withClosed = LaterSnapshot(list: BeadList(beads: [closed], unreadable: 0),
                                       ready: BeadList(beads: [], unreadable: 0), readAt: Date())
        expect(withClosed.beads.isEmpty, "closed beads are not shown")
    }

    // MARK: Composition

    static func checkComposition() {
        let utc = TimeZone(identifier: "UTC")!
        let at = Date.iso("2026-11-15T18:57:03Z")!
        let source = LaterSource(windowId: 42, pid: 7, app: "Ghostty", title: "codex: visageveil", workspace: "3")

        expect(Later.title(note: LaterNote(text: "split rageveil", priority: nil), source: source) == "split rageveil", "note is the title")
        expect(Later.title(note: LaterNote(text: "", priority: nil), source: source) == "Ghostty — codex: visageveil", "window is the title")
        expect(Later.title(note: LaterNote(text: "", priority: nil), source: nil) == nil, "nothing to save")
        let long = LaterSource(windowId: 1, pid: 1, app: "A", title: String(repeating: "x", count: 500), workspace: nil)
        expect(Later.title(note: LaterNote(text: "", priority: nil), source: long)!.count == Later.maxTitle + 1, "long titles are clipped")

        expect(Later.labels(source: LaterSource(windowId: 1, pid: 1, app: "Google Chrome, Beta", title: "", workspace: "a b")) ==
               ["mcmonad", "ws:a-b", "app:google-chrome--beta"], "no commas or spaces inside a label")

        let text = "$ codex\n~~~ a tilde fence ~~~~ inside\n```\nbackticks\n```"
        let d = Later.description(source: source, screenshot: "/s/20261115-185703-w42.png", screenText: text,
                                  missing: [], savedAt: at, timeZone: utc)
        expect(d.hasPrefix("Saved for later from Ghostty — “codex: visageveil” on workspace 3, 2026-11-15 18:57."), "who, where, when")
        expect(d.contains("Screenshot of the window: /s/20261115-185703-w42.png"), "screenshot path")
        expect(d.contains("~~~~~text\n" + text + "\n~~~~~"), "the fence outlasts the text's own tildes")
        let none = Later.description(source: nil, screenshot: nil, screenText: nil,
                                     missing: ["No screenshot: denied."], savedAt: at, timeZone: utc)
        expect(none.contains("no window was focused") && none.contains("No screenshot: denied."), "absences are said")
        let huge = Later.description(source: source, screenshot: nil, screenText: String(repeating: "y", count: 50_000),
                                     missing: [], savedAt: at, timeZone: utc)
        expect(huge.count < Later.maxText + 1_000, "window text is bounded")

        // The metadata the launcher writes is the origin it reads back.
        let origin = BeadOrigin(windowId: 42, pid: 7, app: "Ghostty", title: "codex: \"quoted\"/path", workspace: "3",
                                screenshot: "/s/a.png", savedAt: at.iso)
        let json = #"[{"id": "later-m", "title": "t", "status": "open", "created_at": "2026-11-15T18:57:03Z", "metadata": "#
            + Later.metadata(origin) + "}]"
        expect((try? Later.parseList(Data(json.utf8)).get())?.beads.first?.origin == origin, "metadata round-trips")

        let bead = Bead(id: BeadID(raw: "later-lq1"), title: "check pangram API for h10n", description: "", status: .open,
                        priority: 2, labels: [], createdAt: at, deferUntil: nil, origin: origin)
        let p = Later.prompt(for: bead, timeZone: utc)
        expect(p.hasPrefix("check pangram API for h10n\n\n(Saved for later as later-lq1 on 2026-11-15 18:57 from Ghostty"), "prompt head")
        expect(p.contains("/s/a.png") && p.contains("`later show later-lq1`") && p.contains("`later close later-lq1 --reason"),
               "the prompt says where the rest is and how to close it")

        expect(Later.screenshotName(at: at, windowId: 42, timeZone: utc) == "20261115-185703-w42", "screenshot name")

        // A 1× ultrawide beside a 2× laptop screen: each window at its own display's scale.
        let displays = [Later.Display(bounds: CGRect(x: 0, y: 0, width: 3440, height: 1440), scale: 1),
                        Later.Display(bounds: CGRect(x: -1728, y: 300, width: 1728, height: 1117), scale: 2)]
        expect(Later.scale(for: CGRect(x: 0, y: 30, width: 3440, height: 1410), displays: displays) == 1, "a window on the 1× display")
        expect(Later.scale(for: CGRect(x: -1700, y: 400, width: 800, height: 600), displays: displays) == 2, "a window on the 2× display")
        expect(Later.scale(for: CGRect(x: -200, y: 400, width: 1000, height: 600), displays: displays) == 1, "most of it decides")
        expect(Later.scale(for: CGRect(x: -1727, y: 1416, width: 900, height: 700), displays: displays) == 2, "a parked window, one point on screen")
        expect(Later.scale(for: CGRect(x: 9000, y: 9000, width: 10, height: 10), displays: displays) == 1, "on no display: 1×")
        expect(Later.scale(for: .zero, displays: []) == 1, "no displays known: 1×")
        expect(Later.fence(for: "no tildes") == "~~~", "shortest fence")
        expect(Later.age(from: at, to: at.addingTimeInterval(30)) == "just now", "age")
        expect(Later.age(from: at, to: at.addingTimeInterval(7_300)) == "2 h ago", "age in hours")
    }

    // MARK: Launcher rows

    static func checkRows() {
        let list = parsedList()
        let ready = BeadList(beads: list.beads.filter { $0.id.raw == "later-lq1" }, unreadable: 0)
        let s = LaterSnapshot(list: list, ready: ready, readAt: Date())
        let now = Date.iso("2026-11-15T20:00:00Z")!
        let rows = Later.beadRows(s, now: now)
        expect(rows.count == s.beads.count, "one row per open bead")
        expect(rows[0].title.hasPrefix("▸ ") && rows[1].title.hasPrefix("◆ ") && rows.last!.title.hasPrefix("◇ "), "marks")
        expect(rows[1].haystack.contains("pangram") && rows[1].haystack.contains("ghostty") && rows[1].haystack.contains("later-lq1"),
               "searchable by note, app and id")
        expect(rows.first { $0.action == .open(BeadID(raw: "later-a9c")) }!.detail!.contains("snoozed, back in"), "snoozed says when")

        let started = s.bead(BeadID(raw: "later-sqx"))!
        let a = Later.actionRows(started, standing: .started, originAlive: false)
        expect(a.first!.title.hasPrefix("Continue") && a.contains { $0.action == .putBack(started.id) }, "a started bead continues")
        expect(!a.contains { $0.action == .openScreenshot(started.id) }, "no screenshot row without one")
        let lq1 = s.bead(BeadID(raw: "later-lq1"))!
        let b = Later.actionRows(lq1, standing: .ready, originAlive: true)
        expect(b.first!.title.contains("go back to codex") && b.contains { $0.action == .openScreenshot(lq1.id) }, "ready, window alive")
        let c = Later.actionRows(lq1, standing: .ready, originAlive: false)
        expect(c.first!.title.contains("workspace 3"), "window gone: its workspace")

        let save = Later.saveRow(note: LaterNote(text: "x", priority: 1), source: nil, snapshot: s)
        expect(save.action == .save(LaterNote(text: "x", priority: 1)) && save.detail!.contains("note alone"), "save without a window")
        let nothing = Later.saveRow(note: LaterNote(text: "", priority: nil), source: nil, snapshot: s)
        expect(nothing.action == .browse && nothing.title.contains("1 ready, 1 started"), "nothing to save: browse instead")
    }

    // MARK: The inbox CLI, through the real process code

    static func stand_in() -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("later-checks-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("later").path
        let script = """
        #!/bin/sh
        # Stand-in for the later CLI: answers by subcommand, logs its arguments.
        printf '%s\\n' "$@" > "$0.$1.args"
        case "$1" in
          list)  printf '%s' '[{"id":"later-a","title":"a","status":"open","priority":2,"created_at":"2026-11-15T18:00:00Z"},{"id":"later-b","title":"b","status":"in_progress","priority":2,"created_at":"2026-11-15T18:00:00Z"}]' ;;
          ready) printf '%s' '[{"id":"later-a","title":"a","status":"open","priority":2,"created_at":"2026-11-15T18:00:00Z"}]' ;;
          create) for a in "$@"; do case "$a" in --title=*) t="${a#--title=}" ;; esac; done
                  body=$(cat); printf '{"id":"later-n","title":"%s","status":"open","priority":2,"created_at":"2026-11-15T18:00:00Z","description":"%s"}' "$t" "$body" ;;
          fail)  echo "line one" >&2; echo "Error: no issue found matching later-x" >&2; exit 3 ;;
          slow)  sleep 5 ;;
          junk)  echo "warning: not json" ;;
        esac
        """
        FileManager.default.createFile(atPath: path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o755])
        return path
    }

    static func checkInbox() async {
        let cli = stand_in()
        let inbox = LaterInbox(cli: cli, deadline: 1)

        guard case .success(let snap) = await inbox.snapshot(now: Date()) else { expect(false, "snapshot"); return }
        expect(snap.beads.map(\.id.raw) == ["later-b", "later-a"] && snap.ready == [BeadID(raw: "later-a")], "list + ready")
        for verb in ["list", "ready"] {
            let logged = (try? String(contentsOfFile: "\(cli).\(verb).args", encoding: .utf8)) ?? ""
            expect(logged.contains("--limit=0\n"), "\(verb) asks for every bead, not bd's default page: \(logged)")
        }

        let created = await inbox.create(title: "--not-a-flag", description: "body text", priority: 1,
                                         labels: ["mcmonad", "ws:3"], metadata: nil)
        guard case .success(let bead) = created else { expect(false, "create: \(created)"); return }
        expect(bead.title == "--not-a-flag", "a title like a flag stays the title")
        expect(bead.description == "body text", "the description goes in on stdin")
        let args = (try? String(contentsOfFile: cli + ".create.args", encoding: .utf8)) ?? ""
        expect(args == "create\n--json\n--title=--not-a-flag\n--body-file=-\n--labels=mcmonad,ws:3\n--priority=1\n", "create arguments: \(args)")

        if case .failure(.exited(let verb, let status, let err)) = await inbox.run("fail", ["fail"]) {
            expect(verb == "fail" && status == 3 && err.hasSuffix("no issue found matching later-x"), "exit status and stderr")
        } else { expect(false, "a non-zero exit is a fault") }

        let t0 = Date()
        if case .failure(.timedOut(_, let s)) = await inbox.run("slow", ["slow"]) {
            expect(s == 1 && Date().timeIntervalSince(t0) < 4, "stopped at the deadline")
        } else { expect(false, "a hung call times out") }

        if case .failure(.malformed) = await LaterInbox(cli: cli).run("junk", ["junk"]).flatMap({ d in
            Later.parseList(d).map { _ in d }.mapError { LaterFault.malformed(verb: "junk", $0) } }) {} else {
            expect(false, "non-JSON is malformed")
        }

        if case .failure(.missing(let path)) = await LaterInbox(cli: "/nonexistent/later").snapshot(now: Date()) {
            expect(path == "/nonexistent/later", "a missing CLI says which path")
        } else { expect(false, "a missing CLI is a fault") }
    }
}
