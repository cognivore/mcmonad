import CoreGraphics
import Foundation

// AI-generated text: model claude-opus-5-5; reasoning effort unavailable (not exposed by the harness).

// The launcher's side of the "later" inbox. Everything about beads (their
// order, what a saved bead says, the prompt that starts one) is decided by
// `later`, from beads-mcmonad, which mcmonad is built with when the inbox is
// wanted. This file is what the launcher needs to ask it things and show
// its answers: the verb that starts a request, `later`'s protocol 1, the
// rows, and the scale a window is captured at. Nothing here touches a
// process, a file or the screen.

// MARK: - The verb

/// "later …", "todo …" (and dictation's "To do, …", "Later: …").
enum LaterVerb {
    static let verbs: Set<String> = ["later", "todo", "to-do"]

    /// The words after the verb, for `later` to read (an optional priority
    /// `p0`–`p4`, then the note); nil when `query` is not a later request.
    static func words(in query: String) -> String? {
        var words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count >= 2, words[0].lowercased() == "to", bare(words[1]) == "do" {
            words.replaceSubrange(0...1, with: ["todo"])
        }
        guard let first = words.first, verbs.contains(bare(first)) else { return nil }
        return words.dropFirst().joined(separator: " ")
    }

    private static func bare(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }
}

// MARK: - Protocol 1

/// The protocol version this launcher speaks; `later` refuses others, and
/// so does this.
enum LaterProtocol {
    static let version = 1
}

/// A bead's id as `later` gives it. Never made up here.
struct BeadID: Hashable, Sendable, Codable, CustomStringConvertible {
    let raw: String
    var description: String { raw }
    init(raw: String) { self.raw = raw }
    init(from decoder: Decoder) throws { raw = try decoder.singleValueContainer().decode(String.self) }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }
}

/// A window as the launcher that saw it names it.
enum LaterWindow: Equatable, Sendable, Codable {
    case mac(windowId: UInt32, pid: Int32)
    case wayland(identifier: String)

    private enum Keys: String, CodingKey { case kind, windowId, pid, identifier }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "mac": self = .mac(windowId: try c.decode(UInt32.self, forKey: .windowId), pid: try c.decode(Int32.self, forKey: .pid))
        case "wayland": self = .wayland(identifier: try c.decode(String.self, forKey: .identifier))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown window kind \(other)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .mac(let id, let pid):
            try c.encode("mac", forKey: .kind)
            try c.encode(id, forKey: .windowId)
            try c.encode(pid, forKey: .pid)
        case .wayland(let identifier):
            try c.encode("wayland", forKey: .kind)
            try c.encode(identifier, forKey: .identifier)
        }
    }
}

/// Where a bead was saved from.
struct LaterOrigin: Decodable, Equatable, Sendable {
    let window: LaterWindow
    let app: String
    let title: String
    let workspace: String?
    let screenshot: String?
    let savedAt: Date
}

enum LaterStanding: String, Decodable, Sendable {
    case started, ready, waiting
}

struct LaterBead: Decodable, Equatable, Sendable {
    let id: BeadID
    let title: String
    /// bd's status as bd writes it.
    let status: String
    let standing: LaterStanding
    let priority: Int
    let createdAt: Date
    let deferUntil: Date?
    let labels: [String]
    let origin: LaterOrigin?
    let waitsFor: [BeadID]
}

struct LaterUnreadable: Decodable, Equatable, Sendable {
    let index: Int
    let reason: String
}

/// `later snapshot`: every open bead, in the order to show them.
struct LaterSnapshot: Decodable, Equatable, Sendable {
    let `protocol`: Int
    let readAt: Date
    let unreadable: [LaterUnreadable]
    let beads: [LaterBead]

    var readyCount: Int { beads.filter { $0.standing == .ready }.count }
    var startedCount: Int { beads.filter { $0.standing == .started }.count }
    func bead(_ id: BeadID) -> LaterBead? { beads.first { $0.id == id } }
}

/// `later start`.
struct LaterStarted: Decodable, Equatable, Sendable {
    let `protocol`: Int
    let id: BeadID
    let prompt: String
    let claimed: Bool
    let origin: LaterOrigin?
}

/// `later save`.
struct LaterSaved: Decodable, Equatable, Sendable {
    let `protocol`: Int
    let id: BeadID
    let title: String
}

/// The window the launcher was opened over: what a note is about.
struct LaterSource: Equatable, Sendable, Encodable {
    let window: LaterWindow
    let app: String
    let title: String
    let workspace: String?

    var name: String { title.isEmpty ? app : "\(app) — \(title)" }
}

/// What `later save` reads on stdin.
struct LaterSaveRequest: Encodable, Equatable, Sendable {
    let `protocol` = LaterProtocol.version
    let words: String
    let source: LaterSource?
    /// A picture the launcher wrote; `later` moves it into the inbox.
    let screenshot: String?
    let text: String?
    let missing: [String]
}

/// `later`'s answer did not parse, or is of another protocol version.
struct LaterDecodeError: Error, Equatable, Sendable, CustomStringConvertible {
    let description: String
}

extension Later {
    /// Decode one of `later`'s answers, checking its protocol version.
    static func decode<T: Decodable>(_ type: T.Type, _ data: Data, version: (T) -> Int) -> Result<T, LaterDecodeError> {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            guard let date = Date.iso(s) else {
                throw DecodingError.dataCorruptedError(in: try d.singleValueContainer(), debugDescription: "not a timestamp: \(s)")
            }
            return date
        }
        let value: T
        do {
            value = try decoder.decode(T.self, from: data)
        } catch {
            let head = String(decoding: data.prefix(200), as: UTF8.self)
            return .failure(LaterDecodeError(description: "expected \(T.self); got “\(head)” (\(error))"))
        }
        guard version(value) == LaterProtocol.version else {
            return .failure(LaterDecodeError(description: "later answered protocol \(version(value)); mcmonad speaks \(LaterProtocol.version): build them together"))
        }
        return .success(value)
    }

    static func encode(_ request: LaterSaveRequest) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Strings, integers and optionals of them: encoding cannot fail.
        return (try? encoder.encode(request)) ?? Data("{}".utf8)
    }
}

// MARK: - Rows

/// What the launcher's rows do.
enum LaterAction: Equatable, Sendable {
    /// Save, with the words after the verb.
    case save(String)
    /// Switch to the Later list.
    case browse
    /// Write the inbox as a page and open it.
    case openView
    /// Show one bead's actions.
    case open(BeadID)
    case start(BeadID)
    case copyPrompt(BeadID)
    case openScreenshot(BeadID)
    case snooze(BeadID)
    case done(BeadID)
    /// A started bead goes back to waiting its turn.
    case putBack(BeadID)
}

/// A launcher row, before the launcher turns it into one of its own.
struct LaterRow: Equatable, Sendable {
    let title: String
    let detail: String?
    let action: LaterAction
    let haystack: String
    let symbol: String
}

enum Later {
    /// The CLI's name on PATH, in text for people.
    static let cliName = "later"

    static func saveRow(words: String, source: LaterSource?, snapshot: LaterSnapshot?) -> LaterRow {
        if words.isEmpty {
            guard let source else { return browseRow(snapshot: snapshot, haystack: "") }
            return LaterRow(title: "Save “\(clip(source.name, 120))” for later",
                            detail: "a screenshot and the window's text are saved with it, on this Mac",
                            action: .save(words), haystack: "", symbol: "tray.and.arrow.down")
        }
        let with = source.map { " — with \(clip($0.name, 60))" } ?? ""
        let detail = source == nil
            ? "no window was focused: the note alone is saved"
            : "a screenshot and the window's text are saved with it, on this Mac"
        return LaterRow(title: "Save for later: “\(words)”\(with)", detail: detail,
                        action: .save(words), haystack: "", symbol: "tray.and.arrow.down")
    }

    static func browseRow(snapshot: LaterSnapshot?, haystack: String = "later todo inbox beads saved") -> LaterRow {
        let title = snapshot.map { "Later — \($0.readyCount) ready, \($0.startedCount) started, \($0.beads.count) open" }
            ?? "Later — the saved-for-later inbox"
        return LaterRow(title: title, detail: nil, action: .browse, haystack: haystack, symbol: "tray.full")
    }

    static let viewRow = LaterRow(title: "Open the inbox as a page: its graph, screenshots and everything saved",
                                  detail: nil, action: .openView, haystack: "later graph view page",
                                  symbol: "point.3.connected.trianglepath.dotted")

    static func beadRows(_ snapshot: LaterSnapshot, now: Date) -> [LaterRow] {
        snapshot.beads.map { bead in
            let mark: String
            switch bead.standing {
            case .started: mark = "▸ "
            case .ready: mark = "◆ "
            case .waiting: mark = "◇ "
            }
            var bits = ["\(bead.id)", "P\(bead.priority)", standingLabel(bead, now: now)]
            if let o = bead.origin {
                bits.append(o.title.isEmpty ? o.app : "\(o.app) — \(clip(o.title, 48))")
                if let ws = o.workspace { bits.append("ws \(ws)") }
            }
            bits.append(age(from: bead.createdAt, to: now))
            let haystack = ([bead.title, bead.id.raw] + bead.labels + [bead.origin?.app ?? "", bead.origin?.title ?? ""])
                .joined(separator: " ").lowercased()
            return LaterRow(title: mark + bead.title, detail: bits.joined(separator: " · "),
                            action: .open(bead.id), haystack: haystack, symbol: "tray.full")
        }
    }

    /// The actions on one bead. `originAlive`: its window is still open.
    static func actionRows(_ bead: LaterBead, originAlive: Bool) -> [LaterRow] {
        var rows: [LaterRow] = []
        let goTo: String
        if let o = bead.origin {
            goTo = originAlive ? ", and go back to \(o.title.isEmpty ? o.app : clip(o.title, 60))"
                : (o.workspace.map { ", and go to workspace \($0) (its window has closed)" } ?? "")
        } else { goTo = "" }
        let verb = bead.standing == .started ? "Continue" : "Start"
        rows.append(LaterRow(title: "\(verb): copy the prompt\(goTo)",
                             detail: "marks \(bead.id) started; paste the prompt where the work is done",
                             action: .start(bead.id), haystack: "", symbol: "play.circle"))
        rows.append(LaterRow(title: "Copy the prompt only", detail: nil,
                             action: .copyPrompt(bead.id), haystack: "", symbol: "doc.on.clipboard"))
        if bead.origin?.screenshot != nil {
            rows.append(LaterRow(title: "Open the screenshot", detail: nil,
                                 action: .openScreenshot(bead.id), haystack: "", symbol: "photo"))
        }
        if bead.standing == .started {
            rows.append(LaterRow(title: "Put it back: not started after all", detail: nil,
                                 action: .putBack(bead.id), haystack: "", symbol: "arrow.uturn.backward"))
        }
        rows.append(LaterRow(title: "Snooze until tomorrow", detail: "hidden from ready until then",
                             action: .snooze(bead.id), haystack: "", symbol: "moon.zzz"))
        rows.append(LaterRow(title: "Done: close \(bead.id)", detail: nil,
                             action: .done(bead.id), haystack: "", symbol: "checkmark.circle"))
        return rows
    }

    private static func standingLabel(_ bead: LaterBead, now: Date) -> String {
        switch bead.standing {
        case .started: return "started"
        case .ready: return "ready"
        case .waiting:
            if let until = bead.deferUntil, until > now { return "snoozed, back in " + span(from: now, to: until) }
            return bead.waitsFor.isEmpty ? bead.status : "blocked"
        }
    }

    // MARK: Capture scale

    /// A display as the capture needs it: where it is in global display
    /// coordinates (top-left origin, as window frames are) and its backing
    /// scale.
    struct Display: Equatable, Sendable {
        let bounds: CGRect
        let scale: CGFloat
    }

    /// The backing scale a window is drawn at: that of the display holding
    /// most of it. ScreenCaptureKit pads a capture asked for at a larger
    /// scale rather than enlarging it, which leaves a 1× window's text a
    /// sliver in one corner that OCR cannot read. A window on no display
    /// (none known) is taken at 1×.
    static func scale(for frame: CGRect, displays: [Display]) -> CGFloat {
        let best = displays
            .map { d -> (CGFloat, CGFloat) in
                let i = d.bounds.intersection(frame)
                return (i.isNull ? 0 : i.width * i.height, d.scale)
            }
            .max { $0.0 < $1.0 }
        guard let best, best.0 > 0 else { return 1 }
        return best.1
    }

    // MARK: Small pure helpers

    static func clip(_ s: String, _ limit: Int) -> String {
        s.count <= limit ? s : String(s.prefix(limit)) + "…"
    }

    static func age(from: Date, to now: Date) -> String {
        now.timeIntervalSince(from) < 60 ? "just now" : span(from: from, to: now) + " ago"
    }

    /// A duration in the largest whole unit, at least a minute.
    static func span(from: Date, to: Date) -> String {
        let s = max(60, Int(to.timeIntervalSince(from)))
        switch s {
        case ..<3600: return "\(s / 60) min"
        case ..<86_400: return "\(s / 3600) h"
        default: return "\(s / 86_400) d"
        }
    }
}

extension Date {
    /// RFC 3339, with or without fractional seconds, as `later` writes it.
    static func iso(_ s: String) -> Date? {
        if let d = try? Date(s, strategy: .iso8601) { return d }
        return try? Date(s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}
