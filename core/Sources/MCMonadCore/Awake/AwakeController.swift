import Foundation
import os
import ServiceManagement

// AI-generated text: model claude-opus-5-5; reasoning effort unavailable (not exposed by the harness).

/// Keep awake. awake (./awake in this repository) owns everything about it:
/// what a session does, the lease, the lock, when the Mac sleeps. This runs
/// `Contents/Helpers/awake --json` for the menu, shows what it reports,
/// stops it on request, and registers awake's root guard, the
/// `com.mcmonad.core.awake-guard` daemon, with SMAppService.
///
/// The session's stdin is a pipe held here: when mcmonad-core exits, however
/// it exits, awake sees it close and ends the session, and the guard restores
/// normal sleep.
@MainActor
final class AwakeController {
    private static let logger = Logger(subsystem: "com.mcmonad.core", category: "Awake")
    nonisolated static let guardPlist = "com.mcmonad.core.awake-guard.plist"
    /// What the menu offers, in minutes.
    static let choices: [(title: String, minutes: Int)] =
        [("30 minutes", 30), ("1 hour", 60), ("2 hours", 120), ("4 hours", 240)]

    let cli: String
    private var session: Session?
    /// The running session's latest report.
    private(set) var report: AwakeReport?
    /// How the last session ended, refused or failed, in awake's words.
    private(set) var outcome: String?

    init(cli: String) {
        self.cli = cli
    }

    /// `awake` inside the running bundle; nil for a bundle without it.
    nonisolated static func inBundle(_ bundle: Bundle = .main) -> String? {
        let path = bundle.bundleURL.appendingPathComponent("Contents/Helpers/awake").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    var isRunning: Bool { session != nil }

    // MARK: The guard

    nonisolated static var guardService: SMAppService { SMAppService.daemon(plistName: guardPlist) }

    /// Register the guard unless macOS already knows it. The first
    /// registration asks the user to allow it in Login Items.
    func registerGuard() {
        let service = Self.guardService
        guard service.status == .notRegistered || service.status == .notFound else { return }
        do {
            try service.register()
            Self.logger.info("awake guard registered: \(Self.describe(service.status), privacy: .public)")
        } catch {
            Self.logger.error("awake guard registration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "allowed"
        case .requiresApproval: return "NOT allowed: allow MCMonadCore in Login Items & Extensions"
        case .notRegistered: return "not registered"
        case .notFound: return "missing from MCMonadCore.app"
        @unknown default: return "unknown"
        }
    }

    // MARK: Sessions

    /// One `awake` process, shared with the thread that reads it.
    private final class Session: @unchecked Sendable {
        let process = Process()
        /// Held open for the session's life; see the type's comment.
        let stdin = Pipe()
        let stdout = Pipe()
    }

    func start(minutes: Int) {
        guard session == nil else { return }
        let s = Session()
        s.process.executableURL = URL(fileURLWithPath: cli)
        s.process.arguments = [String(minutes), "--json"]
        s.process.standardInput = s.stdin
        s.process.standardOutput = s.stdout
        s.process.standardError = FileHandle.nullDevice
        do {
            try s.process.run()
        } catch {
            outcome = "awake could not start: \(error.localizedDescription)"
            Self.logger.error("awake: launch failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        session = s
        report = nil
        outcome = nil
        Self.logger.info("awake: started for \(minutes) min, pid \(s.process.processIdentifier)")
        // Lines, then the exit, in order, on the main queue.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let reader = s.stdout.fileHandleForReading
            var buffer = Data()
            while case let chunk = reader.availableData, !chunk.isEmpty {
                buffer.append(chunk)
                for line in AwakeProtocol.takeLines(&buffer) {
                    let decoded = AwakeProtocol.decode(line)
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(decoded, from: s) } }
                }
            }
            s.process.waitUntilExit()
            let status = s.process.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finished(s, status: status) } }
        }
    }

    /// Ask the session to end: awake restores normal sleep and does not
    /// put the Mac to sleep.
    func stop() {
        session?.process.terminate()
    }

    private func received(_ decoded: Result<AwakeReport, AwakeDecodeError>, from s: Session) {
        guard s === session else { return }
        switch decoded {
        case .success(let r) where r.phase == .running:
            report = r
        case .success(let r):
            report = nil
            outcome = r.phase == .ended ? "Ended: \(r.line)" : "\(r.phase == .refused ? "Refused" : "Failed"): \(r.line)"
            Self.logger.info("awake: \(r.phase.rawValue, privacy: .public)")
        case .failure(let e):
            Self.logger.error("awake: unreadable report: \(e.description, privacy: .public)")
            outcome = "awake said something this mcmonad cannot read (\(e.description))"
        }
    }

    private func finished(_ s: Session, status: Int32) {
        guard s === session else { return }
        session = nil
        report = nil
        if outcome == nil { outcome = "awake stopped without saying why (status \(status))" }
        Self.logger.info("awake: exited \(status)")
    }
}
