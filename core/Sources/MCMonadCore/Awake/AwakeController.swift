import Foundation
import os
import ServiceManagement

// AI-generated text: model claude-opus-5-5; reasoning effort unavailable (not exposed by the harness).
// AI-assisted update (lengths in awake's words, and previews for the
// launcher): model claude-opus-5-5; reasoning effort unavailable (not exposed
// by the harness).

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
    private nonisolated static let logger = Logger(subsystem: "com.mcmonad.core", category: "Awake")
    nonisolated static let guardPlist = "com.mcmonad.core.awake-guard.plist"
    /// What the menu offers, as lengths in awake's words.
    static let choices: [(title: String, length: String)] =
        [("30 minutes", "30"), ("1 hour", "1h"), ("2 hours", "2h"), ("4 hours", "4h")]

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
    //
    // Every SMAppService call is a request to macOS's service-management
    // daemon that can go unanswered for hours (one did, at startup, on the
    // main thread, and mcmonad-core never finished starting). So they all
    // run on one background queue, one at a time, and the main actor only
    // ever reads the last answer.

    /// The guard's last known standing; nil until macOS has answered once.
    static private(set) var guardStatus: SMAppService.Status?
    /// A guard request is with macOS; another is not sent meanwhile.
    private static var guardBusy = false
    private static let guardQueue = DispatchQueue(label: "com.mcmonad.core.awake-guard", qos: .utility)

    /// Ask macOS for the guard's standing, registering it whenever macOS has
    /// no record of it (the first registration asks the user to allow it in
    /// Login Items; a deploy that re-signs the app can briefly lose the
    /// record, so every look repairs it). Returns at once.
    static func refreshGuard() {
        guard !guardBusy else { return }
        guardBusy = true
        guardQueue.async {
            let service = SMAppService.daemon(plistName: guardPlist)
            var status = service.status
            if status == .notRegistered || status == .notFound {
                do {
                    try service.register()
                    status = service.status
                    logger.info("awake guard registered: \(describe(status), privacy: .public)")
                } catch {
                    logger.error("awake guard registration failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guardStatus = status
                    guardBusy = false
                }
            }
        }
    }

    /// The last known standing in words.
    static var guardLine: String {
        guardStatus.map(describe) ?? "checking…"
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

    /// Opening System Settings goes through the same daemon.
    static func openLoginItems() {
        guardQueue.async { SMAppService.openSystemSettingsLoginItems() }
    }

    // MARK: Sessions

    /// One `awake` process, shared with the thread that reads it.
    private final class Session: @unchecked Sendable {
        let process = Process()
        /// Held open for the session's life; see the type's comment.
        let stdin = Pipe()
        let stdout = Pipe()
    }

    /// Start a session of `length`, as the person typed it: awake reads it,
    /// and refuses in its own words what it cannot.
    func start(length: String) {
        guard session == nil else { return }
        let s = Session()
        s.process.executableURL = URL(fileURLWithPath: cli)
        s.process.arguments = Self.words(length) + ["--json"]
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
        lastPreview = nil
        Self.logger.info("awake: started, pid \(s.process.processIdentifier)")
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
        lastPreview = nil
        if outcome == nil { outcome = "awake stopped without saying why (status \(status))" }
        Self.logger.info("awake: exited \(status)")
    }

    // MARK: Previews for the launcher

    /// What awake says a session of some length would do.
    enum Preview: Equatable, Sendable {
        /// Asked; no answer yet.
        case asking
        /// awake's answer: `ready`, or `refused`/`failed` with its reason.
        case answer(AwakeReport)
        /// awake gave no answer this mcmonad can read; why, in words.
        case unreadable(String)
    }

    /// How long an answer stands for the same length; the battery moves.
    private static let previewLife: TimeInterval = 10
    /// The longest one `awake check` may take before it is stopped.
    nonisolated private static let checkDeadline: TimeInterval = 5
    private var lastPreview: (length: String, answer: Preview, at: Date)?
    /// The length whose check is out, if one is.
    private var previewAsking: String?
    /// The newest other length typed while that check was out.
    private var previewWanted: String?
    /// Fires on the main actor when a new answer is in.
    var onPreview: (() -> Void)?

    /// awake's answer for `length` if it is in and fresh; otherwise ask
    /// (one check at a time, the newest length wins) and say so.
    func preview(_ length: String) -> Preview {
        if let last = lastPreview, last.length == length, Date().timeIntervalSince(last.at) < Self.previewLife {
            return last.answer
        }
        if previewAsking != length {
            previewWanted = length
            askNextPreview()
        }
        return .asking
    }

    private func askNextPreview() {
        guard previewAsking == nil, let length = previewWanted else { return }
        previewAsking = length
        previewWanted = nil
        let cli = self.cli
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let answer = Self.check(cli: cli, length: length)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.previewAsking = nil
                    self.lastPreview = (length, answer, Date())
                    self.askNextPreview()
                    self.onPreview?()
                }
            }
        }
    }

    /// One `awake check <length> --json`, waited for at most `checkDeadline`.
    nonisolated static func check(cli: String, length: String) -> Preview {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["check"] + words(length) + ["--json"]
        let out = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return .unreadable("awake could not start: \(error.localizedDescription)")
        }
        let stop = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + checkDeadline, execute: stop)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        stop.cancel()
        var buffer = data + Data([0x0A])
        guard let line = AwakeProtocol.takeLines(&buffer).first else {
            return .unreadable("awake check said nothing (status \(p.terminationStatus))")
        }
        switch AwakeProtocol.decode(line) {
        case .success(let report): return .answer(report)
        case .failure(let why): return .unreadable("awake check said something this mcmonad cannot read (\(why))")
        }
    }

    /// A length as separate arguments; awake joins them again.
    nonisolated private static func words(_ length: String) -> [String] {
        length.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
