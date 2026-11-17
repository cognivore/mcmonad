import Foundation

// AI-assisted update (the SDK route, locked down like laptop-pool's workers;
// a receipt per question in the ledger; no API route; Codex first, Claude
// as fallback): model claude-opus-5-5; reasoning effort unavailable (not
// exposed by the harness).

/// Runs one launcher question to the model and ends in exactly one
/// `Ask.Outcome`. It goes first to Codex (`codex exec`, the Codex SDK's
/// engine, `CodexAccess`) on the user's ChatGPT login, and only when that
/// gives no usable answer (no CLI, a failure, an answer out of shape, its
/// deadline) to Claude Code headless (`claude -p`, the Agent SDK's engine,
/// `ClaudeAccess`) on the user's Claude login. Each streams its transcript
/// back. There is no Messages API route: its tokens cost money the
/// subscriptions already cover. The prompt goes in on stdin and no local
/// session is persisted. This does not control the providers' retention.
/// Every question, answered or not, leaves a receipt in the `AskLedger`,
/// which has no field for text.
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
    /// A CLI is about to start: which, where, and its arguments.
    var onRoute: ((Ask.Engine, String, [String]) -> Void)?

    private var process: Process?
    private var finished = false
    private var runID: UUID?
    private var task: Task<Void, Never>?
    /// The receipt of the question in flight, and the retention its
    /// settings named.
    private var receipt: Ask.Receipt?
    private var retention: Ask.Retention?

    /// The longest the CLIs may run between them: just under the 120 s
    /// the launcher gives a whole question, so the reason shown is a CLI's
    /// own. Codex may take `codexDeadline` of it; Claude has the rest.
    static let cliBudget: TimeInterval = 115
    static let codexDeadline: TimeInterval = 70

    /// How long `engine` may run, `elapsed` seconds into the question.
    static func cliDeadline(_ engine: Ask.Engine, elapsed: TimeInterval) -> TimeInterval {
        let left = max(cliBudget - elapsed, 1)
        return engine == .codex ? min(codexDeadline, left) : left
    }

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

    /// Locate `engine`'s CLI when the settings do not name it; nil when
    /// no candidate is an executable file.
    static func locateCLI(_ engine: Ask.Engine) -> String? {
        candidates(engine).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func candidates(_ engine: Ask.Engine) -> [String] {
        let env = ProcessInfo.processInfo.environment
        return Ask.candidates(engine, home: NSHomeDirectory(), user: env["USER"] ?? NSUserName(), path: env["PATH"])
    }

    /// The longest a whole question may take, fetching the OAuth token
    /// included. "What's up" has no clock of its own.
    static let deadline: TimeInterval = 180

    func start(_ request: Ask.Request) {
        cancel()
        let runID = UUID()
        self.runID = runID
        finished = false
        let started = Date()
        receipt = Ask.Receipt(id: String(runID.uuidString.prefix(8)).lowercased(), kind: request.kind, started: started)
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
            var failures: [(Ask.Engine, Ask.Outcome)] = []
            for engine in Ask.Engine.allCases {
                let began = Date()
                let deadline = Self.cliDeadline(engine, elapsed: began.timeIntervalSince(started))
                guard let run = await self.runCLI(engine, request, settings: settings, deadline: deadline, runID: runID),
                      self.runID == runID else { return }
                self.receipt?.runs.append(Ask.CLIRun(engine: engine, seconds: Date().timeIntervalSince(began),
                                                     end: run.timedOut ? .timedOut : Ask.End(run.outcome), facts: run.facts))
                if case .answered = run.outcome {
                    self.finish(run.outcome, runID: runID)
                    return
                }
                failures.append((engine, run.outcome))
                if engine != Ask.Engine.allCases.last {
                    self.onTranscript?("\n\n✗ \(engine.rawValue): \(Ask.reason(run.outcome))\n\n")
                }
            }
            self.finish(Ask.combined(failures), runID: runID)
        }
    }

    // MARK: - The CLI routes

    /// How a CLI run ended: its outcome, what its receipt keeps of it, and
    /// whether its own deadline ended it.
    private struct CLIResult {
        let outcome: Ask.Outcome
        let facts: Ask.Facts
        var timedOut = false
    }

    /// One run of `engine`'s locked-down CLI; nil when cancelled.
    private func runCLI(_ engine: Ask.Engine, _ request: Ask.Request, settings: ClaudeAccess.Settings,
                        deadline: TimeInterval, runID: UUID) async -> CLIResult? {
        guard let cli = (engine == .codex ? settings.codexCLI : settings.cli) ?? Self.locateCLI(engine) else {
            return CLIResult(outcome: .unavailable("No \(engine.rawValue) CLI found. Looked in:\n"
                                                   + Self.candidates(engine).joined(separator: "\n")),
                             facts: Ask.Facts(detail: "no-cli"))
        }
        guard FileManager.default.isExecutableFile(atPath: cli) else {
            return CLIResult(outcome: .unavailable("\(cli) is not executable"), facts: Ask.Facts(detail: "not-executable"))
        }
        let env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory(), user = env["USER"] ?? NSUserName()
        // An empty private directory: nothing for the CLI to find around it.
        let cwd = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mcmonad-ask", isDirectory: true)
        try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let environment: [String: String]
        let arguments: [String]
        switch engine {
        case .codex:
            guard let files = Self.writeContract(request) else {
                return CLIResult(outcome: .unavailable("could not write Codex's schema and instructions files"),
                                 facts: Ask.Facts(detail: "contract"))
            }
            environment = CodexAccess.environment(inherited: env, home: home, user: user)
            arguments = CodexAccess.arguments(files: files, cwd: cwd.path)
        case .claude:
            var token: String?
            if let secret = settings.oauthToken {
                switch await ClaudeRoutes.fetch(secret) {
                case .failure(let problem):
                    return CLIResult(outcome: .unavailable("OAuth token: \(problem.why)"), facts: Ask.Facts(detail: "token"))
                case .success(let t): token = t
                }
            }
            environment = ClaudeAccess.cliEnvironment(inherited: env, home: home, user: user, token: token)
            arguments = Ask.arguments(schema: request.schema, systemPrompt: request.systemPrompt)
        }
        guard self.runID == runID else { return nil }
        onRoute?(engine, cli, arguments)
        return await withCheckedContinuation { (done: CheckedContinuation<CLIResult?, Never>) in
            launch(engine, cli: cli, arguments: arguments, request: request, environment: environment, cwd: cwd,
                   deadline: deadline, runID: runID) { done.resume(returning: $0) }
        }
    }

    /// Where Codex reads `request`'s schema and system prompt: one pair of
    /// files per feature in a private directory, rewritten before each
    /// run. Fixed text, nothing of the screen. Nil when they cannot be
    /// written.
    static func writeContract(_ request: Ask.Request) -> Ask.ContractFiles? {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mcmonad-ask-contract", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let schema = dir.appendingPathComponent("\(request.kind.rawValue).schema.json")
            let instructions = dir.appendingPathComponent("\(request.kind.rawValue).instructions.md")
            try Data(request.schema.utf8).write(to: schema, options: .atomic)
            try Data(request.systemPrompt.utf8).write(to: instructions, options: .atomic)
            return Ask.ContractFiles(schema: schema.path, instructions: instructions.path)
        } catch {
            return nil
        }
    }

    /// A stream reader, used by one reader thread at a time; boxed so the
    /// sendable handlers may hold it.
    private final class ReaderBox: @unchecked Sendable {
        var reader: Ask.Reader
        init(_ reader: Ask.Reader) { self.reader = reader }
    }

    /// Starts the CLI and calls `done` exactly once: with its outcome, or
    /// nil when the run is cancelled.
    private func launch(_ engine: Ask.Engine, cli: String, arguments: [String], request: Ask.Request,
                        environment: [String: String], cwd: URL, deadline: TimeInterval, runID: UUID,
                        done: @escaping (CLIResult?) -> Void) {
        sdkDone = done
        sessionChecked = false
        // Lines and timers of an earlier CLI in the same question (Codex,
        // before Claude) can still be queued: they carry its launch.
        let launch = UUID()
        launchID = launch

        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = arguments
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
        let box = ReaderBox(request.reader(for: engine))
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            // Empty read = EOF; unhook, or this handler spins until exit.
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; drained.leave(); return }
            buffer.data.append(chunk)
            while let nl = buffer.data.firstIndex(of: 0x0A) {
                let lineData = buffer.data.subdata(in: buffer.data.startIndex..<nl)
                buffer.data.removeSubrange(buffer.data.startIndex...nl)
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                let (item, facts) = box.reader.read(line)
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.runID == runID, self.launchID == launch, self.sdkDone != nil else { return }
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
                            self.resolveSDK(CLIResult(outcome: believed, facts: Ask.Facts(detail: detail, usage: facts?.usage,
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
                    self.resolveSDK(CLIResult(
                        outcome: .failed((status == 0 ? "\(engine.rawValue) exited without a result" : "\(engine.rawValue) exited with status \(status)")
                            + (errText.isEmpty ? "" : "\n" + errText)),
                        facts: Ask.Facts(detail: status == 0 ? "no-result" : "exit-\(status)")))
                }
            }
        }

        do {
            try p.run()
        } catch {
            resolveSDK(CLIResult(outcome: .unavailable("Could not start \(cli): \(error.localizedDescription)"),
                                 facts: Ask.Facts(detail: "launch")))
            return
        }
        process = p

        // No run may go on for ever. A CLI stuck on the network or on a
        // prompt of its own would otherwise hold what it was sent.
        DispatchQueue.main.asyncAfter(deadline: .now() + deadline) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.runID == runID, self.launchID == launch, self.sdkDone != nil else { return }
                self.stopProcess()
                self.resolveSDK(CLIResult(outcome: .failed("\(engine.rawValue) gave no answer within \(Int(deadline)) seconds"),
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

    /// The CLI run in flight, among those of one question.
    private var launchID: UUID?
    /// Where the CLI run in flight reports; called once, then cleared.
    private var sdkDone: ((CLIResult?) -> Void)?
    /// The run's session line came: Claude's `init`, showing the
    /// locked-down session; Codex's thread start.
    private var sessionChecked = false

    /// An answer counts only from a session that said what it was; one
    /// that never did may have had tools, servers or settings.
    private func believed(_ outcome: Ask.Outcome) -> Ask.Outcome {
        switch outcome {
        case .answered, .malformed:
            return sessionChecked ? outcome : .failed("the CLI answered without describing its session; not believed")
        case .failed, .unavailable:
            return outcome
        }
    }

    private func resolveSDK(_ result: CLIResult?) {
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
