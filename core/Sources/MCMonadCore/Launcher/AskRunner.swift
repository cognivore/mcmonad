import Foundation

// AI-assisted update (the SDK route, locked down like laptop-pool's workers;
// a receipt per question in the ledger; no API route): model
// claude-opus-5-5; reasoning effort unavailable (not exposed by the harness).

/// Runs one launcher question to the model and ends in exactly one
/// `Ask.Outcome`, by the one route there is: Claude Code headless
/// (`claude -p`, the Agent SDK's engine) on the user's own Claude login,
/// streaming its transcript back (`ClaudeAccess`). There is no Messages API
/// route: its tokens cost money the subscription already covers. The
/// prompt goes in on stdin and no local session is
/// persisted. This does not control the provider's retention. Every
/// question, answered or not, leaves a receipt in the `AskLedger`, which
/// has no field for text.
@MainActor
protocol AskRunning: AnyObject {
    var onFinished: ((Ask.Outcome) -> Void)? { get set }
    func start(_ request: Ask.Request)
    func cancel()
}

@MainActor
final class AskRunner: AskRunning {
    /// Text to append to the on-screen transcript, in order.
    var onTranscript: ((String) -> Void)?
    /// A protocol event worth a dim line in the transcript.
    var onNote: ((String) -> Void)?
    /// Fires once per `start`, after which the runner is idle again.
    var onFinished: ((Ask.Outcome) -> Void)?

    private var process: Process?
    private var finished = false
    private var runID: UUID?
    private var task: Task<Void, Never>?
    /// The receipt of the question in flight, and the retention its
    /// settings named.
    private var receipt: Ask.Receipt?
    private var retention: Ask.Retention?

    /// The longest the CLI may run: just under the 120 s the launcher
    /// gives a whole question, so the reason shown is the CLI's own.
    static let sdkDeadline: TimeInterval = 115

    /// Where receipts go and where the settings come from: the real ones,
    /// or a check's.
    private let ledger: AskLedger
    private let loadSettings: () -> Result<ClaudeAccess.Settings, ClaudeAccess.Problem>

    init(ledger: AskLedger,
         loadSettings: @escaping () -> Result<ClaudeAccess.Settings, ClaudeAccess.Problem> = ClaudeRoutes.loadSettings) {
        self.ledger = ledger
        self.loadSettings = loadSettings
    }

    /// A byte buffer one reader thread appends to; boxed so the sendable
    /// handlers may hold it.
    private final class Bytes: @unchecked Sendable {
        var data = Data()
    }

    /// Locate the CLI when the settings do not name it; nil when no
    /// candidate is an executable file.
    static func locateCLI() -> String? {
        let env = ProcessInfo.processInfo.environment
        return Ask.candidates(home: NSHomeDirectory(), path: env["PATH"])
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The longest a whole question may take, fetching the OAuth token
    /// included. "What's up" has no clock of its own.
    static let deadline: TimeInterval = 180

    func start(_ request: Ask.Request) {
        cancel()
        let runID = UUID()
        self.runID = runID
        finished = false
        receipt = Ask.Receipt(id: String(runID.uuidString.prefix(8)).lowercased(), kind: request.kind,
                              model: Ask.model, effort: Ask.effort, started: Date())
        retention = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.deadline) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.runID == runID, !self.finished else { return }
                self.finish(.failed("no answer within \(Int(Self.deadline)) seconds"), runID: runID, end: .timedOut)
                self.cancel()
            }
        }
        task = Task { @MainActor [weak self] in
            // Cancelled (or started again) before this body ran: nothing.
            guard let self, self.runID == runID else { return }
            let settings: ClaudeAccess.Settings
            switch self.loadSettings() {
            case .failure(let problem): self.finish(.unavailable(problem.why), runID: runID); return
            case .success(let s): settings = s
            }
            self.retention = settings.retention
            let sdkStarted = Date()
            guard let sdk = await self.runSDK(request, settings: settings, runID: runID), self.runID == runID else { return }
            self.receipt?.run = Ask.CLIRun(seconds: Date().timeIntervalSince(sdkStarted),
                                           end: sdk.timedOut ? .timedOut : Ask.End(sdk.outcome), facts: sdk.facts)
            self.finish(sdk.outcome, runID: runID)
        }
    }

    // MARK: - The SDK route

    /// How the SDK route ended: its outcome, what its receipt keeps of it,
    /// and whether its own deadline ended it.
    private struct SDKResult {
        let outcome: Ask.Outcome
        let facts: Ask.Facts
        var timedOut = false
    }

    /// One run of the locked-down CLI; nil when cancelled.
    private func runSDK(_ request: Ask.Request, settings: ClaudeAccess.Settings, runID: UUID) async -> SDKResult? {
        guard let cli = settings.cli ?? Self.locateCLI() else {
            let looked = Ask.candidates(home: NSHomeDirectory(), path: ProcessInfo.processInfo.environment["PATH"])
            return SDKResult(outcome: .unavailable("No claude CLI found. Looked in:\n" + looked.joined(separator: "\n")),
                             facts: Ask.Facts(detail: "no-cli"))
        }
        guard FileManager.default.isExecutableFile(atPath: cli) else {
            return SDKResult(outcome: .unavailable("\(cli) is not executable"), facts: Ask.Facts(detail: "not-executable"))
        }
        var token: String?
        if let secret = settings.oauthToken {
            switch await ClaudeRoutes.fetch(secret) {
            case .failure(let problem):
                return SDKResult(outcome: .unavailable("OAuth token: \(problem.why)"), facts: Ask.Facts(detail: "token"))
            case .success(let t): token = t
            }
            guard self.runID == runID else { return nil }
        }
        guard self.runID == runID else { return nil }
        let env = ProcessInfo.processInfo.environment
        let environment = ClaudeAccess.cliEnvironment(inherited: env, home: NSHomeDirectory(),
                                                      user: env["USER"] ?? NSUserName(), token: token)
        // An empty private directory: nothing for the CLI to find around it.
        let cwd = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mcmonad-ask", isDirectory: true)
        try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return await withCheckedContinuation { (done: CheckedContinuation<SDKResult?, Never>) in
            launch(cli: cli, request: request, environment: environment, cwd: cwd, runID: runID) { done.resume(returning: $0) }
        }
    }

    /// Starts the CLI and calls `done` exactly once: with its outcome, or
    /// nil when the run is cancelled.
    private func launch(cli: String, request: Ask.Request, environment: [String: String], cwd: URL, runID: UUID,
                        done: @escaping (SDKResult?) -> Void) {
        sdkDone = done
        sessionChecked = false

        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = request.arguments
        p.currentDirectoryURL = cwd
        p.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr

        // Line-buffer stdout on the reader's thread; hand whole lines to the
        // main actor, in order, over the main queue. Both pipes must reach
        // end-of-file before the exit status is read as "no answer": the
        // last line can still be in the pipe when the process exits.
        let drained = DispatchGroup()
        drained.enter()
        drained.enter()
        let buffer = Bytes()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            // Empty read = EOF; unhook, or this handler spins until exit.
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; drained.leave(); return }
            buffer.data.append(chunk)
            while let nl = buffer.data.firstIndex(of: 0x0A) {
                let lineData = buffer.data.subdata(in: buffer.data.startIndex..<nl)
                buffer.data.removeSubrange(buffer.data.startIndex...nl)
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                let item = request.parseLine(line)
                var facts: Ask.Facts?
                if case .final = item { facts = Ask.Facts.ofResultLine(line) }
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.runID == runID, self.sdkDone != nil else { return }
                        switch item {
                        case .delta(let text): self.onTranscript?(text)
                        case .note(let text): self.onNote?(text)
                        case .session(let text):
                            self.sessionChecked = true
                            self.onNote?(text)
                        case .final(let outcome):
                            self.stopProcess()
                            let believed = self.believed(outcome)
                            // A final outcome from any line but the result
                            // line is a session that was not the one asked for.
                            let detail = believed != outcome ? "unchecked-session" : (facts == nil ? "refused-session" : facts?.detail)
                            self.resolveSDK(SDKResult(outcome: believed, facts: Ask.Facts(detail: detail, usage: facts?.usage,
                                                                                         turns: facts?.turns)))
                        case .ignore: break
                        }
                    }
                }
            }
        }
        let errData = Bytes()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; drained.leave(); return }
            errData.data.append(chunk)
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            let pid = proc.processIdentifier
            // Runs on the main queue after every stdout line already posted
            // there, and after stderr has stopped being written.
            drained.notify(queue: .main) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.runID == runID, self.process?.processIdentifier == pid else { return }
                    self.process = nil
                    let errText = String(data: errData.data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    // A result line normally arrives before exit; if it did
                    // not, the exit status is the only evidence there is.
                    self.resolveSDK(SDKResult(
                        outcome: .failed((status == 0 ? "claude exited without a result line" : "claude exited with status \(status)")
                            + (errText.isEmpty ? "" : "\n" + errText)),
                        facts: Ask.Facts(detail: status == 0 ? "no-result" : "exit-\(status)")))
                }
            }
        }

        do {
            try p.run()
        } catch {
            resolveSDK(SDKResult(outcome: .unavailable("Could not start \(cli): \(error.localizedDescription)"),
                                 facts: Ask.Facts(detail: "launch")))
            return
        }
        process = p

        // No run may go on for ever. A CLI stuck on the network or on a
        // prompt of its own would otherwise hold what it was sent.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sdkDeadline) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.runID == runID, self.sdkDone != nil else { return }
                self.stopProcess()
                self.resolveSDK(SDKResult(outcome: .failed("claude gave no answer within \(Int(Self.sdkDeadline)) seconds"),
                                          facts: Ask.Facts(), timedOut: true))
            }
        }

        // Feed the prompt and close stdin so the CLI knows it has everything.
        let data = Data(request.prompt.utf8)
        let writer = stdin.fileHandleForWriting
        DispatchQueue.global(qos: .userInitiated).async {
            // Cancellation closes stdin; a cancelled write is an expected
            // failure, not an Objective-C exception from FileHandle.write.
            try? writer.write(contentsOf: data)
            try? writer.close()
        }
    }

    /// Where the SDK run in flight reports; called once, then cleared.
    private var sdkDone: ((SDKResult?) -> Void)?
    /// The run's `init` line came and showed the locked-down session.
    private var sessionChecked = false

    /// An answer counts only from a session that said what it was; one
    /// that never did may have had tools, servers or settings.
    private func believed(_ outcome: Ask.Outcome) -> Ask.Outcome {
        switch outcome {
        case .answered, .malformed:
            return sessionChecked ? outcome : .failed("claude answered without describing its session; not believed")
        case .failed, .unavailable:
            return outcome
        }
    }

    private func resolveSDK(_ result: SDKResult?) {
        guard let done = sdkDone else { return }
        sdkDone = nil
        done(result)
    }

    /// Stop a running call. No outcome is reported for a cancelled call;
    /// its receipt says it was cancelled.
    func cancel() {
        if !finished, var open = receipt {
            open.close(nil, end: .cancelled, at: Date())
            ledger.record(open, under: retention)
        }
        receipt = nil
        runID = nil
        finished = true
        task?.cancel()
        task = nil
        stopProcess()
        resolveSDK(nil)   // a cancelled run ends without an outcome
    }

    /// How long a stopped CLI has to exit on SIGTERM before SIGKILL. It
    /// holds the prompt, screen text, for as long as it lives.
    static let killGrace: TimeInterval = 2

    /// Detach from the child process and terminate it; kill it if it is
    /// still there after `killGrace`.
    private func stopProcess() {
        guard let p = process else { return }
        process = nil
        p.terminationHandler = nil
        (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (p.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        try? (p.standardInput as? Pipe)?.fileHandleForWriting.close()
        p.terminate()
        let child = Child(p)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.killGrace) { child.kill() }
    }

    /// A stopped child, handed to the queue that makes sure it is gone.
    private final class Child: @unchecked Sendable {
        private let process: Process
        init(_ process: Process) { self.process = process }
        func kill() {
            // Still running means not yet reaped, so the pid is still its own.
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }

    /// Ends the question: its receipt goes to the ledger (counts and
    /// kinds only; the outcome's words can carry the model's words about
    /// screen contents, which stay on screen), then `onFinished`.
    private func finish(_ outcome: Ask.Outcome, runID: UUID, end: Ask.End? = nil) {
        guard self.runID == runID, !finished else { return }
        finished = true
        if var closed = receipt {
            closed.close(outcome, end: end, at: Date())
            ledger.record(closed, under: retention)
        }
        receipt = nil
        onFinished?(outcome)
    }
}
