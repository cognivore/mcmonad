import Foundation

// AI-generated text: model claude-opus-5-5; reasoning effort unavailable (not exposed by the harness).

/// The effects behind `ClaudeAccess`: reading the settings file, fetching a
/// secret from the command or file it names, and one Messages API call.
/// Secrets live only in these functions' locals and the child's
/// environment; nothing here logs or keeps one.
enum ClaudeRoutes {
    /// The settings, or why they are unusable. No file: the defaults (the
    /// CLI's own login, no API route).
    static func loadSettings() -> Result<ClaudeAccess.Settings, ClaudeAccess.Problem> {
        let path = ClaudeAccess.settingsPath(home: NSHomeDirectory())
        guard let data = FileManager.default.contents(atPath: path) else {
            return FileManager.default.fileExists(atPath: path)
                ? .failure(ClaudeAccess.Problem("\(path) cannot be read")) : .success(ClaudeAccess.Settings())
        }
        return ClaudeAccess.parse(data).mapError { ClaudeAccess.Problem("\(path): \($0.why)") }
    }

    /// How long a credential command may take (it may ask for a touch).
    static let commandDeadline: TimeInterval = 60

    /// The secret, or why it could not be had (never the secret's text).
    static func fetch(_ secret: ClaudeAccess.Secret, deadline: TimeInterval = commandDeadline) async -> Result<String, ClaudeAccess.Problem> {
        switch secret {
        case .file(let raw):
            let path = raw.hasPrefix("~/") ? NSHomeDirectory() + String(raw.dropFirst(1)) : raw
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let mode = attrs[.posixPermissions] as? Int,
                  let owner = attrs[.ownerAccountID] as? Int
            else { return .failure(ClaudeAccess.Problem("\(path) cannot be read")) }
            guard owner == Int(getuid()), ClaudeAccess.ownerOnly(mode) else {
                return .failure(ClaudeAccess.Problem("\(path) must be yours and readable by you alone (chmod 600)"))
            }
            guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else {
                return .failure(ClaudeAccess.Problem("\(path) cannot be read"))
            }
            return ClaudeAccess.credential(text).mapError { ClaudeAccess.Problem("\(path) \($0.why)") }
        case .command(let argv):
            return await run(argv, deadline: deadline).flatMap { ClaudeAccess.credential($0).mapError { ClaudeAccess.Problem("\(argv[0]) printed a value that \($0.why)") } }
        }
    }

    /// Runs `argv` with no input and its errors discarded; its output, if
    /// it exits 0 within `commandDeadline`.
    private static func run(_ argv: [String], deadline: TimeInterval) async -> Result<String, ClaudeAccess.Problem> {
        let env = ProcessInfo.processInfo.environment
        let user = env["USER"] ?? NSUserName()
        let path = ClaudeAccess.searchPath(home: NSHomeDirectory(), user: user, inherited: env["PATH"])
        let executable: String
        if argv[0].hasPrefix("/") {
            executable = argv[0]
        } else if let found = path.split(separator: ":").map({ "\($0)/\(argv[0])" })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            executable = found
        } else {
            return .failure(ClaudeAccess.Problem("\(argv[0]) is not on \(path)"))
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = Array(argv.dropFirst())
        var childEnv = env
        childEnv["PATH"] = path
        p.environment = childEnv
        p.standardInput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        return await withCheckedContinuation { (done: CheckedContinuation<Result<String, ClaudeAccess.Problem>, Never>) in
            let once = Once()
            // The output is read to its end on its own thread; the answer
            // needs both that end and the exit. A child the command left
            // behind can hold the pipe open for ever: the deadline answers
            // then, whatever else has or has not happened.
            let output = Output()
            let finished = DispatchGroup()
            finished.enter()
            finished.enter()
            DispatchQueue.global().async {
                output.data = out.fileHandleForReading.readDataToEndOfFile()
                finished.leave()
            }
            p.terminationHandler = { _ in finished.leave() }
            do {
                try p.run()
            } catch {
                try? out.fileHandleForWriting.close()   // lets the reader thread end
                once.run { done.resume(returning: .failure(ClaudeAccess.Problem("\(argv[0]) could not start: \(error.localizedDescription)"))) }
                return
            }
            finished.notify(queue: .global()) {
                guard p.terminationReason == .exit, p.terminationStatus == 0 else {
                    once.run { done.resume(returning: .failure(ClaudeAccess.Problem("\(argv[0]) exited with status \(p.terminationStatus)"))) }
                    return
                }
                once.run { done.resume(returning: .success(String(decoding: output.data, as: UTF8.self))) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + deadline) {
                if p.isRunning { p.terminate() }
                once.run { done.resume(returning: .failure(ClaudeAccess.Problem("\(argv[0]) gave nothing within \(Int(deadline)) s"))) }
            }
        }
    }

    /// What the reader thread read, handed to whoever answers.
    private final class Output: @unchecked Sendable {
        var data = Data()
    }

    /// Resumes a continuation once, whichever of several paths gets there.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func run(_ body: () -> Void) {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return }
            done = true
            body()
        }
    }

    static let apiDeadline: TimeInterval = 60

    /// One Messages API call for `request`, keyed by `key`: its outcome,
    /// and what its receipt keeps of it.
    static func callAPI(_ request: Ask.Request, key: String, session: URLSession = .shared) async -> (Ask.Outcome, Ask.Facts) {
        guard let body = ClaudeAccess.apiBody(request) else { return (.malformed("the schema is not JSON"), Ask.Facts(detail: "schema")) }
        var http = URLRequest(url: ClaudeAccess.apiURL, timeoutInterval: apiDeadline)
        http.httpMethod = "POST"
        for (name, value) in ClaudeAccess.apiHeaders(key: key) { http.setValue(value, forHTTPHeaderField: name) }
        http.httpBody = body
        do {
            let (data, response) = try await session.data(for: http)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (ClaudeAccess.apiOutcome(status: status, data: data, request: request),
                    ClaudeAccess.apiFacts(status: status, data: data))
        } catch {
            return (.failed("API call failed: \(error.localizedDescription)"), Ask.Facts(detail: "transport"))
        }
    }
}
