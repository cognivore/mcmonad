import Foundation

// AI-generated text: model claude-opus-5-5; reasoning effort unavailable (not exposed by the harness).
// AI-assisted update (a receipt keeps every CLI run, Codex and Claude):
// model claude-opus-5-5; reasoning effort unavailable (not exposed by the
// harness).

/// What mcmonad keeps of each launcher question once it is over, and for
/// how long: its own ledger, kept the way laptop-pool keeps job receipts
/// but under a local retention policy.
///
/// A receipt says which feature asked, which CLIs it went to (Codex, then
/// Claude if Codex gave no usable answer) and how each run ended, how long
/// it took, how many turns and tokens it used, and how many windows or
/// workspaces the answer named. It has no field for text: not the question,
/// the screen text sent, the answer, or an error's words (which can quote
/// any of them). The only strings are closed vocabularies: the CLI's result
/// subtype, or the runner's own short reason. So whatever a receipt is
/// written to learns nothing of the screen.
///
/// Dollars are not counted. The subscription carries the cost, and the
/// CLI's own `total_cost_usd` is a list-price estimate, not a charge.
extension Ask {
    /// Which launcher feature asked.
    enum Kind: String, Sendable {
        case whereIs = "where-is"
        case whatsUp = "whats-up"
    }

    /// How the CLI run, or a whole question, ended.
    enum End: String, Sendable {
        case answered
        case unavailable
        case failed
        case malformed
        case timedOut = "timed-out"
        case cancelled

        init(_ outcome: Outcome) {
            switch outcome {
            case .answered: self = .answered
            case .unavailable: self = .unavailable
            case .failed: self = .failed
            case .malformed: self = .malformed
            }
        }
    }

    /// Tokens one call used, as the CLI's result line counts them.
    struct Usage: Equatable, Sendable {
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheWrite = 0

        var total: Int { input + output + cacheRead + cacheWrite }

        /// From a `usage` object; nil when there is none or it has no
        /// input and output counts.
        init?(_ object: Any?) {
            guard let o = object as? [String: Any],
                  let input = o["input_tokens"] as? Int, let output = o["output_tokens"] as? Int else { return nil }
            self.input = input
            self.output = output
            cacheRead = o["cache_read_input_tokens"] as? Int ?? 0
            cacheWrite = o["cache_creation_input_tokens"] as? Int ?? 0
        }

        init(input: Int, output: Int, cacheRead: Int = 0, cacheWrite: Int = 0) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
        }
    }

    /// What the CLI's own report adds to its outcome.
    struct Facts: Equatable, Sendable {
        /// A short reason from a closed vocabulary: the CLI's result
        /// subtype, "exit-3", "no-cli"… Never words from the call.
        var detail: String?
        var usage: Usage?
        var turns: Int?

        init(detail: String? = nil, usage: Usage? = nil, turns: Int? = nil) {
            self.detail = detail.flatMap(Facts.token)
            self.usage = usage
            self.turns = turns
        }

        /// The facts of a stream-json result line; nil for any other line.
        static func ofResultLine(_ line: String) -> Facts? {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  obj["type"] as? String == "result" else { return nil }
            return Facts(detail: obj["subtype"] as? String, usage: Usage(obj["usage"]), turns: obj["num_turns"] as? Int)
        }

        /// `s` when it is a token of the closed vocabularies above (lower
        /// case letters, digits, "-" and "_", at most 40), else nil. A
        /// field that could carry words carries nothing instead.
        static func token(_ s: String) -> String? {
            let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
            return !s.isEmpty && s.count <= 40 && s.allSatisfy(allowed.contains) ? s : nil
        }
    }

    /// One CLI's part in a question.
    struct CLIRun: Equatable, Sendable {
        let engine: Engine
        let seconds: Double
        let end: End
        let facts: Facts

        /// "codex:gpt-6-astra:medium:answered/completed,6.2s,tokens=1312+208,cache=0+0"
        var logField: String {
            var field = "\(engine.rawValue):\(engine.model):\(engine.effort):\(end.rawValue)"
            if let d = facts.detail { field += "/\(d)" }
            field += ",\(Receipt.decimal(seconds))s"
            if let t = facts.turns { field += ",turns=\(t)" }
            if let u = facts.usage {
                field += ",tokens=\(u.input)+\(u.output),cache=\(u.cacheRead)+\(u.cacheWrite)"
            }
            return field
        }
    }

    struct Receipt: Equatable, Sendable {
        let id: String
        let kind: Kind
        let started: Date
        /// The CLI runs, in order. Empty when the question ended before a
        /// CLI's route reported (settings that cannot be read, a cancel).
        var runs: [CLIRun] = []
        var end: End = .cancelled
        var seconds: Double = 0
        /// How many windows or workspaces the answer named, and how many
        /// of those the launcher does not have.
        var named: Int?
        var dropped: Int?

        init(id: String, kind: Kind, started: Date) {
            self.id = id
            self.kind = kind
            self.started = started
        }

        var tokens: Int { runs.reduce(0) { $0 + ($1.facts.usage?.total ?? 0) } }

        /// Ends the receipt with `outcome` (or `end`, for a deadline or a
        /// cancel), `seconds` after it started.
        mutating func close(_ outcome: Outcome?, end: End? = nil, at date: Date) {
            self.end = end ?? outcome.map(End.init) ?? .cancelled
            seconds = date.timeIntervalSince(started)
            switch outcome {
            case .answered(.windows(let m, let d)): named = m.count; dropped = d
            case .answered(.workspaces(let s, let d)): named = s.count; dropped = d
            default: break
            }
        }

        /// One line of mcmonad-core.log.
        var logLine: String {
            var line = "ASK: id=\(id) kind=\(kind.rawValue) end=\(end.rawValue) seconds=\(Self.decimal(seconds))"
            if let named { line += " named=\(named)" }
            if let dropped { line += " dropped=\(dropped)" }
            for run in runs { line += " run=" + run.logField }
            return line
        }

        /// One row of the menu bar's list: "21:40  where-is  answered in
        /// 6.3 s · 1.5k tokens · 2 named · codex → claude".
        func menuLine(clock: (Date) -> String) -> String {
            var parts = ["\(end.rawValue) in \(Self.decimal(seconds)) s"]
            if tokens > 0 { parts.append(tokens >= 1000 ? "\(Self.decimal(Double(tokens) / 1000))k tokens" : "\(tokens) tokens") }
            if let named { parts.append("\(named) named") }
            if !runs.isEmpty { parts.append(runs.map(\.engine.rawValue).joined(separator: " → ")) }
            return "\(clock(started))  \(kind.rawValue)  " + parts.joined(separator: " · ")
        }

        fileprivate static func decimal(_ x: Double) -> String { String(format: "%.1f", x) }
    }

    /// What mcmonad keeps of its questions, and where. Receipts stay in
    /// this process's memory for `hours`; with `.log` each is also one line
    /// of mcmonad-core.log, readable on demand by anyone who can read the
    /// log. What a question carried (screen text, titles, the answer) is
    /// kept by nothing here: it lives in memory only for the call, and
    /// afterwards only where the launcher shows it. No setting changes that.
    struct Retention: Equatable, Sendable {
        enum Receipts: String, Sendable {
            /// In memory only, shown in the menu bar.
            case memory
            /// In memory, and one line each in the log.
            case log
        }

        var receipts: Receipts = .log
        var hours = 24

        static let hourRange = 1...168
    }
}

/// The receipts of every launcher question, under the retention policy
/// the last question's settings named.
@MainActor
final class AskLedger {
    /// The most receipts kept, whatever their age.
    static let cap = 500

    private var kept: [Ask.Receipt] = []
    private(set) var retention = Ask.Retention()
    private let write: (String) -> Void

    /// `write` takes the log lines; the daemon's is its stderr log.
    init(write: @escaping (String) -> Void = { logStderr($0 + "\n") }) {
        self.write = write
    }

    /// Keeps `receipt`. `retention` is the policy its settings named (nil
    /// when they could not be read: the last one known holds).
    func record(_ receipt: Ask.Receipt, under retention: Ask.Retention?, at date: Date = Date()) {
        if let retention { self.retention = retention }
        kept.append(receipt)
        prune(at: date)
        if self.retention.receipts == .log { write(receipt.logLine) }
    }

    /// The receipts still kept, newest first.
    func recent(at date: Date = Date()) -> [Ask.Receipt] {
        prune(at: date)
        return kept.reversed()
    }

    private func prune(at date: Date) {
        let horizon = date.addingTimeInterval(-Double(retention.hours) * 3600)
        kept.removeAll { $0.started < horizon }
        if kept.count > Self.cap { kept.removeFirst(kept.count - Self.cap) }
    }
}
