import Foundation
import os

/// Runs one "where is" question through the Claude Code CLI already on this
/// Mac (`claude -p`), streaming its transcript back and ending in exactly one
/// `WhereIs.Outcome`. The prompt goes in on stdin and the CLI is told not to
/// persist the session, so the recognised screen text it carries exists only
/// in the two processes' memory for the length of the call.
@MainActor
final class WhereIsRunner {
    private static let logger = Logger(subsystem: "com.mcmonad.core", category: "WhereIs")

    /// Text to append to the on-screen transcript, in order.
    var onTranscript: ((String) -> Void)?
    /// Fires once per `start`, after which the runner is idle again.
    var onFinished: ((WhereIs.Outcome) -> Void)?

    private var process: Process?
    private var finished = false

    /// Locate the CLI; nil when no candidate is an executable file.
    static func locateCLI() -> String? {
        let env = ProcessInfo.processInfo.environment
        return WhereIs.candidates(home: NSHomeDirectory(), path: env["PATH"])
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func start(prompt: String, known: Set<UInt32>) {
        cancel()
        finished = false
        guard let cli = Self.locateCLI() else {
            let looked = WhereIs.candidates(home: NSHomeDirectory(),
                                            path: ProcessInfo.processInfo.environment["PATH"])
            finish(.unavailable("No claude CLI found. Looked in:\n" + looked.joined(separator: "\n")))
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = WhereIs.arguments
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            .joined(separator: ":") + (env["PATH"].map { ":" + $0 } ?? "")
        p.environment = env

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr

        // Line-buffer stdout on the reader's thread; hand whole lines to the
        // main actor. `known` and the buffers are owned by this closure.
        let known = known
        nonisolated(unsafe) var buffer = Data()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            // Empty read = EOF; unhook, or this handler spins until exit.
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                let item = WhereIs.parseLine(line, known: known)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    switch item {
                    case .delta(let text): self.onTranscript?(text)
                    case .final(let outcome): self.finish(outcome)
                    case .ignore: break
                    }
                }
            }
        }
        nonisolated(unsafe) var errData = Data()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            errData.append(chunk)
        }
        p.terminationHandler = { [weak self] proc in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            let status = proc.terminationStatus
            let errText = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DispatchQueue.main.async { [weak self] in
                guard let self, self.process === proc else { return }
                self.process = nil
                // A result line normally arrives before exit; if it did not,
                // the exit status is the only evidence we have.
                if !self.finished {
                    let why = status == 0
                        ? "claude exited without a result line" + (errText.isEmpty ? "" : "\n" + errText)
                        : "claude exited with status \(status)" + (errText.isEmpty ? "" : "\n" + errText)
                    self.finish(.failed(why))
                }
            }
        }

        do {
            try p.run()
        } catch {
            finish(.unavailable("Could not start \(cli): \(error.localizedDescription)"))
            return
        }
        process = p
        Self.logger.info("where-is: asked \(WhereIs.model, privacy: .public) via \(cli, privacy: .public)")

        // Feed the prompt and close stdin so the CLI knows it has everything.
        let data = Data(prompt.utf8)
        DispatchQueue.global(qos: .userInitiated).async {
            stdin.fileHandleForWriting.write(data)
            try? stdin.fileHandleForWriting.close()
        }
    }

    /// Stop a running call. No outcome is reported for a cancelled call.
    func cancel() {
        guard let p = process else { return }
        finished = true
        process = nil
        p.terminationHandler = nil
        (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (p.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        p.terminate()
    }

    private func finish(_ outcome: WhereIs.Outcome) {
        guard !finished else { return }
        finished = true
        // Only the kind is logged: the payloads can carry the model's words
        // about screen contents, which stay on screen.
        switch outcome {
        case .answered(let m, let dropped):
            Self.logger.info("where-is: \(m.count, privacy: .public) match(es), \(dropped, privacy: .public) dropped")
        case .unavailable: Self.logger.error("where-is: claude CLI unavailable")
        case .failed: Self.logger.error("where-is: claude CLI failed")
        case .malformed: Self.logger.error("where-is: answer was not in the schema")
        }
        onFinished?(outcome)
    }
}
