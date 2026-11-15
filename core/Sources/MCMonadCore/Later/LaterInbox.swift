import Foundation
import os

// AI-generated text: model claude-opus-5-5; reasoning effort unavailable (not exposed by the harness).

/// Why a call to the inbox CLI gave no usable answer. Each case says, in
/// words, what was being done; only `verb` (never a note, a title or the
/// window text in the arguments) goes to the log.
enum LaterFault: Error, Equatable, Sendable, CustomStringConvertible {
    /// The configured CLI is not an executable file: the settings name a
    /// wrong path, or a home-manager generation that was collected.
    case missing(cli: String)
    case launch(cli: String, reason: String)
    /// It ran and exited non-zero. `stderr` is the end of what it said.
    case exited(verb: String, status: Int32, stderr: String)
    case timedOut(verb: String, seconds: Int)
    case malformed(verb: String, LaterParseError)

    var description: String {
        switch self {
        case .missing(let cli):
            return "The later inbox CLI \(cli) is not an executable file. Run home-manager switch, or check ~/.config/mcmonad/later.json."
        case .launch(let cli, let reason):
            return "Could not start \(cli): \(reason)"
        case .exited(let verb, let status, let stderr):
            return "`\(Later.cliName) \(verb)` failed with status \(status)" + (stderr.isEmpty ? "" : ": \(stderr)")
        case .timedOut(let verb, let seconds):
            return "`\(Later.cliName) \(verb)` gave no answer within \(seconds) s and was stopped"
        case .malformed(let verb, let why):
            return "`\(Later.cliName) \(verb)` answered something unexpected: \(why)"
        }
    }

    /// For the log: the kind and the verb, no content.
    var kind: String {
        switch self {
        case .missing: return "missing"
        case .launch: return "launch"
        case .exited(let verb, let status, _): return "\(verb) exited \(status)"
        case .timedOut(let verb, _): return "\(verb) timed out"
        case .malformed(let verb, _): return "\(verb) malformed"
        }
    }
}

/// The inbox CLI (`later`, home-manager's wrapper that runs `bd` against
/// the inbox database). Every call is one process with a deadline, run off
/// the main actor, ending in one outcome. bd's embedded Dolt takes
/// concurrent readers and writers from separate processes, so a refresh
/// may overlap a save or a `later` typed in a terminal.
struct LaterInbox: Sendable {
    private static let logger = Logger(subsystem: "com.mcmonad.core", category: "Later")

    let cli: String
    /// The longest one call may take. A create with Dolt's first-run
    /// initialisation takes a few seconds; nothing should take this long.
    var deadline: TimeInterval = 30

    // MARK: Operations

    /// Every open bead, and bd's own answer to which of them are ready.
    /// `--limit 0`: bd lists 50 (ready: 100) by default, and a silently
    /// shortened inbox would hide what was saved.
    func snapshot(now: Date) async -> Result<LaterSnapshot, LaterFault> {
        async let list = beads("list", ["list", "--json", "--limit=0"])
        async let ready = beads("ready", ["ready", "--json", "--limit=0"])
        let (l, r) = await (list, ready)
        switch (l, r) {
        case (.failure(let f), _), (_, .failure(let f)): return .failure(f)
        case (.success(let l), .success(let r)): return .success(LaterSnapshot(list: l, ready: r, readAt: now))
        }
    }

    func create(title: String, description: String, priority: Int?, labels: [String],
                metadata: String?) async -> Result<Bead, LaterFault> {
        // `--flag=value` throughout: a title that starts with "-" stays a value.
        var args = ["create", "--json", "--title=\(title)", "--body-file=-", "--labels=\(labels.joined(separator: ","))"]
        if let priority { args.append("--priority=\(priority)") }
        if let metadata { args.append("--metadata=\(metadata)") }
        return await run("create", args, stdin: Data(description.utf8)).flatMap { data in
            Later.parseOne(data).mapError { .malformed(verb: "create", $0) }
        }
    }

    func claim(_ id: BeadID) async -> Result<Void, LaterFault> {
        await run("update --claim", ["update", id.raw, "--claim", "--json"]).map { _ in () }
    }

    func putBack(_ id: BeadID) async -> Result<Void, LaterFault> {
        await run("update --status", ["update", id.raw, "--status=open", "--assignee=", "--json"]).map { _ in () }
    }

    func close(_ id: BeadID) async -> Result<Void, LaterFault> {
        await run("close", ["close", id.raw, "--reason=Done (from the mcmonad launcher)", "--json"]).map { _ in () }
    }

    func snooze(_ id: BeadID, until: String) async -> Result<Void, LaterFault> {
        await run("defer", ["defer", id.raw, "--until=\(until)", "--json"]).map { _ in () }
    }

    private func beads(_ verb: String, _ args: [String]) async -> Result<BeadList, LaterFault> {
        await run(verb, args).flatMap { data in
            Later.parseList(data).mapError { .malformed(verb: verb, $0) }
        }
    }

    // MARK: One process

    /// Run the CLI with `arguments`, feeding `stdin`; the stdout of a zero
    /// exit, or why there is none.
    func run(_ verb: String, _ arguments: [String], stdin: Data? = nil) async -> Result<Data, LaterFault> {
        guard FileManager.default.isExecutableFile(atPath: cli) else {
            Self.logger.error("later: CLI missing")
            return .failure(.missing(cli: cli))
        }
        let cli = self.cli, deadline = self.deadline
        let started = Date()
        let result: Result<Data, LaterFault> = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: Self.runBlocking(cli: cli, verb: verb, arguments: arguments,
                                                        stdin: stdin, deadline: deadline))
            }
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        switch result {
        case .success: Self.logger.info("later: \(verb, privacy: .public) ok in \(ms) ms")
        case .failure(let f): Self.logger.error("later: \(f.kind, privacy: .public) after \(ms) ms")
        }
        return result
    }

    /// Owned by exactly one blocking call; the boxes let its reader threads
    /// and its deadline hand results back.
    private final class Box: @unchecked Sendable {
        let process = Process()
        var out = Data()
        var err = Data()
        var timedOut = false
    }

    private static func runBlocking(cli: String, verb: String, arguments: [String], stdin: Data?,
                                    deadline: TimeInterval) -> Result<Data, LaterFault> {
        let box = Box()
        let p = box.process
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = arguments
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"
        env["BD_NON_INTERACTIVE"] = "1"
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        do {
            try p.run()
        } catch {
            return .failure(.launch(cli: cli, reason: error.localizedDescription))
        }
        // Read both pipes and write stdin at once: any one of them can fill
        // its buffer and stall the child while we wait on another.
        let io = DispatchGroup()
        DispatchQueue.global().async(group: io) { box.out = outPipe.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global().async(group: io) { box.err = errPipe.fileHandleForReading.readDataToEndOfFile() }
        let writer = inPipe.fileHandleForWriting
        DispatchQueue.global().async {
            // A child that exits without reading stdin closes the pipe; that
            // write failing is expected, not a fault of the call.
            if let stdin { try? writer.write(contentsOf: stdin) }
            try? writer.close()
        }
        let stop = DispatchWorkItem {
            guard box.process.isRunning else { return }
            box.timedOut = true
            box.process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + deadline, execute: stop)
        p.waitUntilExit()
        stop.cancel()
        // A grandchild still holding a pipe must not hold this call.
        if io.wait(timeout: .now() + 5) == .timedOut {
            return .failure(.timedOut(verb: verb, seconds: Int(deadline)))
        }
        if box.timedOut { return .failure(.timedOut(verb: verb, seconds: Int(deadline))) }
        guard p.terminationStatus == 0 else {
            let err = String(decoding: box.err, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.exited(verb: verb, status: p.terminationStatus, stderr: String(err.suffix(600))))
        }
        return .success(box.out)
    }
}
