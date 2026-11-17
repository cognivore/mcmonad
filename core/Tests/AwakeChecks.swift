// AI-generated text: model claude-opus-5-5; reasoning effort unavailable (not exposed by the harness).
//
// Compiled with Awake/AwakeReport.swift and Awake/AwakeController.swift and
// run by the Nix package checkPhase. The protocol fixtures are what
// awake_core::Report::encode prints (awake/core's own test pins the same
// text); the session checks run a stand-in `awake` (a shell script) through
// the same process code the daemon uses.
import Foundation

@main
enum AwakeChecks {
    static func main() async {
        checkProtocol()
        checkLines()
        await checkSessions()
        print("Awake checks passed")
    }

    static func expect(_ ok: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
        if !ok {
            print("FAILED: \(what) (\(file):\(line))")
            exit(1)
        }
    }

    static let running = #"{"awake":1,"phase":"running","line":"0:29 left · 85% · floor 20%","warning":"a \"quote\"\nand a\tback\\slash","holders":[{"pid":7,"process":"caffeinate","what":"PreventUserIdleSystemSleep (caffeinate command-line tool)"}]}"#
    static let ended = #"{"awake":1,"phase":"ended","line":"stopped; normal sleep is back","warning":null,"holders":[]}"#

    static func checkProtocol() {
        guard case .success(let r) = AwakeProtocol.decode(Data(running.utf8)) else {
            return expect(false, "a running report decodes")
        }
        expect(r.phase == .running && r.line == "0:29 left · 85% · floor 20%", "phase and line")
        expect(r.warning == "a \"quote\"\nand a\tback\\slash", "escapes")
        expect(r.holders == [.init(pid: 7, process: "caffeinate", what: "PreventUserIdleSystemSleep (caffeinate command-line tool)")], "holders")
        guard case .success(let e) = AwakeProtocol.decode(Data(ended.utf8)) else {
            return expect(false, "an ended report decodes")
        }
        expect(e.phase == .ended && e.warning == nil, "ended, no warning")
        let v2 = ended.replacingOccurrences(of: #""awake":1"#, with: #""awake":2"#)
        expect(AwakeProtocol.decode(Data(v2.utf8)) == .failure(.version(2)), "another version is refused")
        let odd = ended.replacingOccurrences(of: #""ended""#, with: #""napping""#)
        if case .failure(.malformed) = AwakeProtocol.decode(Data(odd.utf8)) {} else { expect(false, "an unknown phase is refused") }
        if case .failure(.malformed) = AwakeProtocol.decode(Data("awake: words".utf8)) {} else { expect(false, "words are refused") }
    }

    static func checkLines() {
        var buffer = Data("one\ntwo\n\nthr".utf8)
        let lines = AwakeProtocol.takeLines(&buffer).map { String(decoding: $0, as: UTF8.self) }
        expect(lines == ["one", "two"], "complete lines, blank ones dropped: \(lines)")
        expect(String(decoding: buffer, as: UTF8.self) == "thr", "the unfinished line stays")
        buffer.append(Data("ee\n".utf8))
        expect(AwakeProtocol.takeLines(&buffer).map { String(decoding: $0, as: UTF8.self) } == ["three"], "and completes later")
    }

    /// A stand-in `awake`: `body` is the script after the shebang.
    static func standIn(_ body: String) -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("awake-checks-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("awake-\(UUID().uuidString)").path
        FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n\(body)\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        return path
    }

    @MainActor
    static func waitFor(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        expect(false, "timed out waiting for: \(what)")
    }

    @MainActor
    static func checkSessions() async {
        // Reports, then Stop: awake is asked with SIGTERM and says how it ended.
        let polite = AwakeController(cli: standIn("""
            ended=\(shellQuoted(ended))
            trap 'printf "%s\\n" "$ended"; exit 0' TERM
            printf "%s\\n" \(shellQuoted(running))
            while :; do sleep 0.05; done
            """))
        polite.start(minutes: 30)
        expect(polite.isRunning, "running once started")
        await waitFor("the running report") { polite.report != nil }
        expect(polite.report?.line == "0:29 left · 85% · floor 20%", "the running line is shown")
        polite.stop()
        await waitFor("the session to end") { !polite.isRunning }
        expect(polite.outcome == "Ended: stopped; normal sleep is back", "awake's own words: \(polite.outcome ?? "nil")")
        expect(polite.report == nil, "no running report after the end")

        // The arguments mcmonad passes, and a refusal in awake's words.
        let refusing = AwakeController(cli: standIn("""
            [ "$1 $2" = "60 --json" ] || { echo "wrong arguments: $*" >&2; exit 9; }
            echo '{"awake":1,"phase":"refused","line":"the battery is at 10%, already at or below the 20% floor","warning":null,"holders":[]}'
            exit 2
            """))
        refusing.start(minutes: 60)
        await waitFor("the refusal") { !refusing.isRunning }
        expect(refusing.outcome == "Refused: the battery is at 10%, already at or below the 20% floor",
               "refused: \(refusing.outcome ?? "nil")")

        // Silence and a crash are reported as such.
        let silent = AwakeController(cli: standIn("exit 3"))
        silent.start(minutes: 30)
        await waitFor("the silent exit") { !silent.isRunning }
        expect(silent.outcome == "awake stopped without saying why (status 3)", "silent: \(silent.outcome ?? "nil")")

        // An awake that is not there.
        let missing = AwakeController(cli: "/nonexistent/awake")
        missing.start(minutes: 30)
        expect(!missing.isRunning && missing.outcome?.hasPrefix("awake could not start") == true, "a missing awake")
    }

    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
