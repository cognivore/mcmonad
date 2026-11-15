import Foundation
import os

// AI-assisted update (SDK route first, locked down like laptop-pool's workers;
// the Messages API only as its fallback): model claude-opus-5-5; reasoning
// effort unavailable (not exposed by the harness).

/// Runs one launcher question to the model and ends in exactly one
/// `Ask.Outcome`. The SDK route first — Claude Code headless (`claude -p`)
/// on the user's own login, streaming its transcript back; the Messages API
/// only when that route could not answer and a key source is configured
/// (`ClaudeAccess`). The prompt goes in on stdin and no local session is
/// persisted. This does not control the provider's retention.
@MainActor
protocol AskRunning: AnyObject {
    var onFinished: ((Ask.Outcome) -> Void)? { get set }
    func start(_ request: Ask.Request)
    func cancel()
}

@MainActor
final class AskRunner: AskRunning {
    private static let logger = Logger(subsystem: "com.mcmonad.core", category: "Ask")

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

    /// The longest the SDK route may take before the API route is tried;
    /// the launcher gives a whole question 120 s.
    static let sdkDeadline: TimeInterval = 75

    /// Where the settings come from and how the API is called: the real
    /// ones, or a check's.
    private let loadSettings: () -> Result<ClaudeAccess.Settings, ClaudeAccess.Problem>
    private let callAPI: (Ask.Request, String) async -> Ask.Outcome

    init(loadSettings: @escaping () -> Result<ClaudeAccess.Settings, ClaudeAccess.Problem> = ClaudeRoutes.loadSettings,
         callAPI: @escaping (Ask.Request, String) async -> Ask.Outcome = { await ClaudeRoutes.callAPI($0, key: $1) }) {
        self.loadSettings = loadSettings
        self.callAPI = callAPI
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

    func start(_ request: Ask.Request) {
        cancel()
        let runID = UUID()
        self.runID = runID
        finished = false
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            let settings: ClaudeAccess.Settings
            switch self.loadSettings() {
            case .failure(let problem): self.finish(.unavailable(problem.why), runID: runID); return
            case .success(let s): settings = s
            }
            guard let sdk = await self.runSDK(request, settings: settings, runID: runID), self.runID == runID else { return }
            switch sdk {
            case .answered, .malformed:
                // An answer, or one in the wrong shape: the model was
                // reached, and asking again elsewhere would pay twice.
                self.finish(sdk, runID: runID)
                return
            case .unavailable(let why), .failed(let why):
                guard let key = settings.apiKey else {
                    self.finish(sdk, runID: runID)
                    return
                }
                Self.logger.info("ask: SDK route did not answer; trying the API")
                self.onNote?("SDK route did not answer (\(why.split(separator: "\n").first ?? "")); asking the API")
                let api: Ask.Outcome
                switch await ClaudeRoutes.fetch(key) {
                case .failure(let problem): api = .unavailable("API key: \(problem.why)")
                case .success(let key): api = await self.callAPI(request, key)
                }
                guard self.runID == runID else { return }
                if case .answered = api { Self.logger.info("ask: answered by the API") }
                self.finish(Self.both(sdk: sdk, api: api), runID: runID)
            }
        }
    }

    /// When both routes failed, both reasons.
    private static func both(sdk: Ask.Outcome, api: Ask.Outcome) -> Ask.Outcome {
        func why(_ o: Ask.Outcome) -> String? {
            switch o {
            case .unavailable(let w), .failed(let w), .malformed(let w): return w
            case .answered: return nil
            }
        }
        guard let a = why(api), let s = why(sdk) else { return api }
        let text = "SDK: \(s)\nAPI: \(a)"
        switch api {
        case .unavailable: return .unavailable(text)
        case .malformed: return .malformed(text)
        default: return .failed(text)
        }
    }

    // MARK: - The SDK route

    /// One run of the locked-down CLI; nil when cancelled.
    private func runSDK(_ request: Ask.Request, settings: ClaudeAccess.Settings, runID: UUID) async -> Ask.Outcome? {
        guard let cli = settings.cli ?? Self.locateCLI() else {
            let looked = Ask.candidates(home: NSHomeDirectory(), path: ProcessInfo.processInfo.environment["PATH"])
            return .unavailable("No claude CLI found. Looked in:\n" + looked.joined(separator: "\n"))
        }
        guard FileManager.default.isExecutableFile(atPath: cli) else { return .unavailable("\(cli) is not executable") }
        var token: String?
        if let secret = settings.oauthToken {
            switch await ClaudeRoutes.fetch(secret) {
            case .failure(let problem): return .unavailable("OAuth token: \(problem.why)")
            case .success(let t): token = t
            }
            guard self.runID == runID else { return nil }
        }
        let env = ProcessInfo.processInfo.environment
        let environment = ClaudeAccess.cliEnvironment(inherited: env, home: NSHomeDirectory(),
                                                      user: env["USER"] ?? NSUserName(), token: token)
        // An empty private directory: nothing for the CLI to find around it.
        let cwd = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mcmonad-ask", isDirectory: true)
        try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return await withCheckedContinuation { (done: CheckedContinuation<Ask.Outcome?, Never>) in
            launch(cli: cli, request: request, environment: environment, cwd: cwd, runID: runID) { done.resume(returning: $0) }
        }
    }

    /// Starts the CLI and calls `done` exactly once: with its outcome, or
    /// nil when the run is cancelled.
    private func launch(cli: String, request: Ask.Request, environment: [String: String], cwd: URL, runID: UUID,
                        done: @escaping (Ask.Outcome?) -> Void) {
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
                            self.resolveSDK(self.believed(outcome))
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
                    self.resolveSDK(.failed((status == 0 ? "claude exited without a result line" : "claude exited with status \(status)")
                        + (errText.isEmpty ? "" : "\n" + errText)))
                }
            }
        }

        do {
            try p.run()
        } catch {
            resolveSDK(.unavailable("Could not start \(cli): \(error.localizedDescription)"))
            return
        }
        process = p
        Self.logger.info("ask: \(Ask.model, privacy: .public) via the SDK route (\(cli, privacy: .public))")

        // No run may go on for ever. A CLI stuck on the network or on a
        // prompt of its own would otherwise hold what it was sent.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sdkDeadline) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.runID == runID, self.sdkDone != nil else { return }
                self.stopProcess()
                self.resolveSDK(.failed("claude gave no answer within \(Int(Self.sdkDeadline)) seconds"))
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
    private var sdkDone: ((Ask.Outcome?) -> Void)?
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

    private func resolveSDK(_ outcome: Ask.Outcome?) {
        guard let done = sdkDone else { return }
        sdkDone = nil
        done(outcome)
    }

    /// Stop a running call. No outcome is reported for a cancelled call.
    func cancel() {
        runID = nil
        finished = true
        task?.cancel()
        task = nil
        stopProcess()
        resolveSDK(nil)   // a cancelled run ends without an outcome
    }

    /// Detach from the child process and terminate it.
    private func stopProcess() {
        guard let p = process else { return }
        process = nil
        p.terminationHandler = nil
        (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (p.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        try? (p.standardInput as? Pipe)?.fileHandleForWriting.close()
        p.terminate()
    }

    private func finish(_ outcome: Ask.Outcome, runID: UUID) {
        guard self.runID == runID, !finished else { return }
        finished = true
        // Only the kind is logged: the payloads can carry the model's words
        // about screen contents, which stay on screen.
        switch outcome {
        case .answered(.windows(let m, let dropped)):
            Self.logger.info("ask: \(m.count, privacy: .public) window(s), \(dropped, privacy: .public) dropped")
        case .answered(.workspaces(let s, let dropped)):
            Self.logger.info("ask: \(s.count, privacy: .public) workspace summaries, \(dropped, privacy: .public) dropped")
        case .unavailable: Self.logger.error("ask: no route to the model")
        case .failed: Self.logger.error("ask: the model call failed")
        case .malformed: Self.logger.error("ask: answer was not in the schema")
        }
        onFinished?(outcome)
    }
}
