import Foundation
import os

// AI-generated text: model claude-opus-5-5; reasoning effort unavailable (not exposed by the harness).

/// Why a call to `later` gave no usable answer. Each case says, in words,
/// what was being done; only `verb` (never a note, a title or window text)
/// goes to the log.
enum LaterFault: Error, Equatable, Sendable, CustomStringConvertible {
    /// The `later` mcmonad was built with is not an executable file.
    case missing(cli: String)
    case launch(cli: String, reason: String)
    /// It ran and exited non-zero. `stderr` is the end of what it said:
    /// `later` explains there what failed and what happened to the change.
    case exited(verb: String, status: Int32, stderr: String)
    case timedOut(verb: String, seconds: Int)
    case malformed(verb: String, LaterDecodeError)

    var description: String {
        switch self {
        case .missing(let cli):
            return "later is not at \(cli): mcmonad was built with a later that is no longer there; switch home-manager again."
        case .launch(let cli, let reason):
            return "Could not start \(cli): \(reason)"
        case .exited(let verb, let status, let stderr):
            return "`later \(verb)` failed with status \(status)" + (stderr.isEmpty ? "" : ": \(stderr)")
        case .timedOut(let verb, let seconds):
            return "`later \(verb)` gave no answer within \(seconds) s and was stopped; it may or may not have done its work"
        case .malformed(let verb, let why):
            return "`later \(verb)` answered something unexpected: \(why)"
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

/// `later`, the inbox's own program (beads-mcmonad), which mcmonad is built
/// with. It owns everything about beads; this runs it, one process per
/// call with a deadline, off the main actor, and reads its protocol-1
/// answers.
struct LaterInbox: Sendable {
    private static let logger = Logger(subsystem: "com.mcmonad.core", category: "Later")

    let cli: String
    /// The longest one call may take. A first call creates the database,
    /// which takes a few seconds; nothing should take this long.
    var deadline: TimeInterval = 30

    /// `later` inside the running bundle, where a build with the inbox puts
    /// it; nil for a build without it.
    static func inBundle(_ bundle: Bundle = .main) -> String? {
        let path = bundle.bundleURL.appendingPathComponent("Contents/Helpers/later").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    // MARK: Operations

    func snapshot() async -> Result<LaterSnapshot, LaterFault> {
        await answer("snapshot", ["snapshot"], LaterSnapshot.self) { $0.protocol }
    }

    func save(_ request: LaterSaveRequest) async -> Result<LaterSaved, LaterFault> {
        await answer("save", ["save"], LaterSaved.self, stdin: Later.encode(request)) { $0.protocol }
    }

    func start(_ id: BeadID) async -> Result<LaterStarted, LaterFault> {
        await answer("start", ["start", id.raw], LaterStarted.self) { $0.protocol }
    }

    /// The prompt as plain text.
    func prompt(_ id: BeadID) async -> Result<String, LaterFault> {
        await run("prompt", ["prompt", id.raw]).map {
            String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .newlines)
        }
    }

    func done(_ id: BeadID) async -> Result<Void, LaterFault> {
        await run("done", ["done", id.raw]).map { _ in () }
    }

    func snooze(_ id: BeadID) async -> Result<Void, LaterFault> {
        await run("snooze", ["snooze", id.raw]).map { _ in () }
    }

    func wake(_ id: BeadID) async -> Result<Void, LaterFault> {
        await run("wake", ["wake", id.raw]).map { _ in () }
    }

    func putBack(_ id: BeadID) async -> Result<Void, LaterFault> {
        await run("put-back", ["put-back", id.raw]).map { _ in () }
    }

    /// Write the inbox as a page and open it.
    func view() async -> Result<Void, LaterFault> {
        await run("view", ["view"]).map { _ in () }
    }

    private func answer<T: Decodable>(_ verb: String, _ args: [String], _ type: T.Type, stdin: Data? = nil,
                                      version: @escaping (T) -> Int) async -> Result<T, LaterFault> {
        await run(verb, args, stdin: stdin).flatMap { data in
            Later.decode(type, data, version: version).mapError { .malformed(verb: verb, $0) }
        }
    }

    // MARK: One process

    /// Run `later` with `arguments`, feeding `stdin`; the stdout of a zero
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

    /// Owned by exactly one blocking call; the box lets its reader threads
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
            var err = String(decoding: box.err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if err.hasPrefix("later: ") { err.removeFirst("later: ".count) }
            return .failure(.exited(verb: verb, status: p.terminationStatus, stderr: String(err.suffix(600))))
        }
        return .success(box.out)
    }
}
