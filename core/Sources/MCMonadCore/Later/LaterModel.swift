import CoreGraphics
import Foundation

// AI-generated text: model claude-opus-5-5; reasoning effort unavailable (not exposed by the harness).

// The "later" inbox: notes and windows saved from the launcher as beads
// (`bd`) issues, to be started once the work at hand is done. This file is
// the pure half: what the settings file, the CLI's JSON and the launcher's
// words mean, and what a saved bead and its start prompt say. `LaterInbox`
// runs the CLI, `LaterCapture` reads the window, `LaterController` owns the
// rest. Nothing here touches a process, a file or the screen.

// MARK: - Settings

/// Where the inbox is, as home-manager wrote it to
/// `~/.config/mcmonad/later.json` (`services.mcmonad.later`). No file means
/// the feature is off: no menu-bar item, no launcher rows, no Later mode.
struct LaterSettings: Equatable, Sendable {
    /// The inbox CLI: `bd` with the inbox database chosen for it.
    let cli: String
    /// The directory saved screenshots are written to.
    let attachments: String

    static func file(home: String) -> String { home + "/.config/mcmonad/later.json" }

    enum Load: Equatable, Sendable {
        case off
        case on(LaterSettings)
        /// The file exists but cannot be used; why, in words.
        case unusable(String)
    }

    /// `data` is nil when the file does not exist.
    static func load(_ data: Data?, file: String) -> Load {
        guard let data else { return .off }
        struct Wire: Decodable { let cli: String; let attachments: String }
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: data)
        } catch {
            return .unusable("\(file) must be {\"cli\": \"/abs/path\", \"attachments\": \"/abs/dir\"}; reading it failed: \(error)")
        }
        guard wire.cli.hasPrefix("/") else {
            return .unusable("\(file): \"cli\" must be an absolute path; it is “\(wire.cli)”")
        }
        guard wire.attachments.hasPrefix("/") else {
            return .unusable("\(file): \"attachments\" must be an absolute path; it is “\(wire.attachments)”")
        }
        return .on(LaterSettings(cli: wire.cli, attachments: wire.attachments))
    }
}

// MARK: - Beads as bd reports them

/// A bead's id exactly as bd gave it (`later-lq1`). Never made up here.
struct BeadID: Hashable, Sendable, CustomStringConvertible {
    let raw: String
    var description: String { raw }
}

/// bd's stored status. bd lets a database define its own statuses, so one
/// this version does not know is kept as it was written, not dropped.
enum BeadStatus: Equatable, Sendable {
    case open, inProgress, blocked, deferred, closed
    case other(String)

    init(wire: String) {
        switch wire {
        case "open": self = .open
        case "in_progress": self = .inProgress
        case "blocked": self = .blocked
        case "deferred": self = .deferred
        case "closed": self = .closed
        default: self = .other(wire)
        }
    }

    var label: String {
        switch self {
        case .open: return "open"
        case .inProgress: return "started"
        case .blocked: return "blocked"
        case .deferred: return "snoozed"
        case .closed: return "closed"
        case .other(let s): return s
        }
    }
}

/// Where a bead was saved from, as the capture recorded it in the bead's
/// metadata under `"mcmonad"`. A window id and pid name a window only while
/// it lives: `LaterController` checks them against the current window list
/// before acting on them.
struct BeadOrigin: Codable, Equatable, Sendable {
    let windowId: UInt32
    let pid: Int32
    let app: String
    let title: String
    let workspace: String?
    /// The saved screenshot's absolute path, when one was taken.
    let screenshot: String?
    /// ISO 8601, as written by `Later.metadata`.
    let savedAt: String
}

struct Bead: Equatable, Sendable {
    let id: BeadID
    let title: String
    let description: String
    let status: BeadStatus
    /// 0 (highest) to 4, as bd keeps it.
    let priority: Int
    let labels: [String]
    let createdAt: Date
    let deferUntil: Date?
    /// Nil for a bead not saved by the launcher (made with `later create`,
    /// or by an agent).
    let origin: BeadOrigin?
}

/// One `bd list --json` / `bd ready --json` answer. An element that is not
/// a bead (no id, no title, no status, an unreadable date) is counted rather
/// than failing the whole list, and the count is shown.
struct BeadList: Equatable, Sendable {
    let beads: [Bead]
    let unreadable: Int
}

/// Decodes one element if it can, so one bad element cannot hide the rest.
private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

private struct WireBead: Decodable {
    let id: String
    let title: String
    let description: String?
    let status: String
    let priority: Int?
    let labels: [String]?
    let created_at: String
    let defer_until: String?
    let metadata: Lossy<WireMetadata>?
}

private struct WireMetadata: Decodable {
    let mcmonad: Lossy<BeadOrigin>?
}

// MARK: - The inbox as the launcher sees it

/// Where a bead stands for the person deciding what to do next.
enum BeadStanding: Equatable, Sendable {
    /// Claimed (`in_progress`): being worked on.
    case started
    /// bd says it can be started now (`bd ready`).
    case ready
    /// Snoozed, blocked, or otherwise not ready.
    case waiting
}

/// The open beads with bd's own answer to which are ready, read together.
struct LaterSnapshot: Equatable, Sendable {
    /// Every bead not closed, started first, then ready, then waiting;
    /// within each, by priority and then oldest first, so what was saved
    /// first comes up first.
    let beads: [Bead]
    let ready: Set<BeadID>
    let unreadable: Int
    let readAt: Date

    func standing(_ bead: Bead) -> BeadStanding {
        if bead.status == .inProgress { return .started }
        return ready.contains(bead.id) ? .ready : .waiting
    }

    var readyCount: Int { beads.filter { standing($0) == .ready }.count }
    var startedCount: Int { beads.filter { standing($0) == .started }.count }

    func bead(_ id: BeadID) -> Bead? { beads.first { $0.id == id } }

    init(list: BeadList, ready: BeadList, readAt: Date) {
        let readyIds = Set(ready.beads.map(\.id))
        self.ready = readyIds
        self.unreadable = list.unreadable + ready.unreadable
        self.readAt = readAt
        func rank(_ b: Bead) -> Int {
            if b.status == .inProgress { return 0 }
            return readyIds.contains(b.id) ? 1 : 2
        }
        self.beads = list.beads
            .filter { $0.status != .closed }
            .sorted { a, b in
                (rank(a), a.priority, a.createdAt, a.id.raw) < (rank(b), b.priority, b.createdAt, b.id.raw)
            }
    }
}

// MARK: - What the user types or says

/// "later <note>" or "todo <note>", with an optional priority `p0`–`p4`
/// straight after the verb: `later p1 split rageveil's two functions`.
/// The verb alone is a note with no text: save the window as it is, or
/// browse the inbox.
struct LaterNote: Equatable, Sendable {
    let text: String
    let priority: Int?

    static let verbs: Set<String> = ["later", "todo", "to-do"]

    init?(_ query: String) {
        var words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        // Dictation writes "To do, …" and "Later: …".
        if words.count >= 2, words[0].lowercased() == "to",
           Self.bare(words[1]) == "do" {
            words.replaceSubrange(0...1, with: ["todo"])
        }
        guard let first = words.first, Self.verbs.contains(Self.bare(first)) else { return nil }
        words.removeFirst()
        var priority: Int?
        if let p = words.first, let n = Self.priorityToken(p) {
            priority = n
            words.removeFirst()
        }
        self.text = words.joined(separator: " ")
        self.priority = priority
    }

    init(text: String, priority: Int?) {
        self.text = text
        self.priority = priority
    }

    private static func bare(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    private static func priorityToken(_ word: String) -> Int? {
        let w = word.lowercased()
        guard w.count == 2, w.first == "p", let d = w.last?.wholeNumberValue, (0...4).contains(d) else { return nil }
        return d
    }
}

/// The window the launcher was opened over: what the note is about.
struct LaterSource: Equatable, Sendable {
    let windowId: UInt32
    let pid: Int32
    let app: String
    let title: String
    let workspace: String?

    var name: String { title.isEmpty ? app : "\(app) — \(title)" }
}

/// What the launcher's rows do.
enum LaterAction: Equatable, Sendable {
    case save(LaterNote)
    /// Switch to the Later list.
    case browse
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

// MARK: - Composition

enum Later {
    /// The inbox CLI's name on PATH, used in text written for people and
    /// agents ("`later show later-lq1`").
    static let cliName = "later"
    /// The longest window text kept with a bead.
    static let maxText = 16_000
    /// The longest title made from a window's name.
    static let maxTitle = 120
    /// What "Snooze" passes to `bd defer --until`.
    static let snoozeUntil = "tomorrow"

    /// The bead's title: the note, or with no note the window it is about.
    /// Nil when there is neither: nothing to save.
    static func title(note: LaterNote, source: LaterSource?) -> String? {
        if !note.text.isEmpty { return note.text }
        guard let source else { return nil }
        return clip(source.name, maxTitle)
    }

    static func labels(source: LaterSource?) -> [String] {
        var out = ["mcmonad"]
        if let ws = source?.workspace, !ws.isEmpty { out.append("ws:" + labelSafe(ws)) }
        if let app = source?.app, !app.isEmpty { out.append("app:" + labelSafe(app)) }
        return out
    }

    /// bd takes labels comma-separated: no commas or spaces inside one.
    static func labelSafe(_ s: String) -> String {
        String(s.lowercased().map { $0 == "," || $0.isWhitespace ? "-" : $0 })
    }

    /// The `--metadata` JSON: `{"mcmonad": origin}`.
    static func metadata(_ origin: BeadOrigin) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding a struct of strings and integers cannot fail.
        let data = (try? encoder.encode(["mcmonad": origin])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// The bead's description. `screenText` is what the window said when
    /// it was saved; `missing` explains anything the capture could not get.
    static func description(source: LaterSource?, screenshot: String?, screenText: String?,
                            missing: [String], savedAt: Date, timeZone: TimeZone = .current) -> String {
        var parts: [String] = []
        let when = stamp(savedAt, timeZone: timeZone)
        if let source {
            let ws = source.workspace.map { " on workspace \($0)" } ?? ""
            let title = source.title.isEmpty ? "" : " — “\(source.title)”"
            parts.append("Saved for later from \(source.app)\(title)\(ws), \(when).")
        } else {
            parts.append("Saved for later from the mcmonad launcher, \(when); no window was focused.")
        }
        if let screenshot {
            parts.append("Screenshot of the window: \(screenshot)")
        }
        for why in missing { parts.append(why) }
        if let text = screenText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let kept = clip(text, maxText)
            let f = fence(for: kept)
            parts.append("Text read off the window when it was saved (on-device OCR; expect misreadings):\n\n\(f)text\n\(kept)\n\(f)")
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    /// What "Start" puts on the clipboard: the note, and where to find the
    /// rest. It names the bead so whoever does the work can close it.
    static func prompt(for bead: Bead, timeZone: TimeZone = .current) -> String {
        var context: [String] = ["Saved for later as \(bead.id)"]
        if let o = bead.origin {
            let when = Date.iso(o.savedAt).map { stamp($0, timeZone: timeZone) } ?? o.savedAt
            let title = o.title.isEmpty ? o.app : "\(o.app) — “\(o.title)”"
            context[0] += " on \(when) from \(title)"
            if let shot = o.screenshot { context.append("Screenshot of that window: \(shot)") }
        }
        context.append("`\(cliName) show \(bead.id)` prints everything saved with it; `\(cliName) close \(bead.id) --reason \"…\"` closes it once this is done.")
        return bead.title + "\n\n(" + context.joined(separator: ". ") + ")"
    }

    // MARK: Launcher rows

    static func saveRow(note: LaterNote, source: LaterSource?, snapshot: LaterSnapshot?) -> LaterRow {
        let p = note.priority.map { " · P\($0)" } ?? ""
        guard let title = title(note: note, source: source) else {
            return browseRow(snapshot: snapshot, haystack: "")
        }
        let with = source.map { " — with \($0.name)" } ?? ""
        let what = note.text.isEmpty ? "Save “\(title)” for later" : "Save for later: “\(title)”\(with)"
        let detail = source == nil
            ? "no window was focused: the note alone is saved"
            : "a screenshot and the window's text are saved with it, on this Mac\(p)"
        return LaterRow(title: what, detail: detail, action: .save(note), haystack: "", symbol: "tray.and.arrow.down")
    }

    static func browseRow(snapshot: LaterSnapshot?, haystack: String = "later todo inbox beads saved") -> LaterRow {
        let title: String
        if let s = snapshot {
            title = "Later — \(s.readyCount) ready, \(s.startedCount) started, \(s.beads.count) open"
        } else {
            title = "Later — the saved-for-later inbox"
        }
        return LaterRow(title: title, detail: nil, action: .browse, haystack: haystack, symbol: "tray.full")
    }

    static func beadRows(_ snapshot: LaterSnapshot, now: Date) -> [LaterRow] {
        snapshot.beads.map { bead in
            let standing = snapshot.standing(bead)
            let mark: String
            switch standing {
            case .started: mark = "▸ "
            case .ready: mark = "◆ "
            case .waiting: mark = "◇ "
            }
            var bits = ["\(bead.id)", "P\(bead.priority)", standingLabel(bead, standing, now: now)]
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
    static func actionRows(_ bead: Bead, standing: BeadStanding, originAlive: Bool) -> [LaterRow] {
        var rows: [LaterRow] = []
        let goTo: String
        if let o = bead.origin {
            goTo = originAlive ? ", and go back to \(o.title.isEmpty ? o.app : clip(o.title, 60))"
                : (o.workspace.map { ", and go to workspace \($0) (its window has closed)" } ?? "")
        } else { goTo = "" }
        let verb = standing == .started ? "Continue" : "Start"
        rows.append(LaterRow(title: "\(verb): copy the prompt\(goTo)",
                             detail: "marks \(bead.id) started; paste the prompt where the work is done",
                             action: .start(bead.id), haystack: "", symbol: "play.circle"))
        rows.append(LaterRow(title: "Copy the prompt only", detail: nil,
                             action: .copyPrompt(bead.id), haystack: "", symbol: "doc.on.clipboard"))
        if bead.origin?.screenshot != nil {
            rows.append(LaterRow(title: "Open the screenshot", detail: nil,
                                 action: .openScreenshot(bead.id), haystack: "", symbol: "photo"))
        }
        if standing == .started {
            rows.append(LaterRow(title: "Put it back: not started after all", detail: nil,
                                 action: .putBack(bead.id), haystack: "", symbol: "arrow.uturn.backward"))
        }
        rows.append(LaterRow(title: "Snooze until \(snoozeUntil)", detail: "hidden from ready until then",
                             action: .snooze(bead.id), haystack: "", symbol: "moon.zzz"))
        rows.append(LaterRow(title: "Done: close \(bead.id)", detail: nil,
                             action: .done(bead.id), haystack: "", symbol: "checkmark.circle"))
        return rows
    }

    // MARK: Parsing bd's answers

    /// Parse a `bd list --json` or `bd ready --json` answer: a JSON array
    /// of beads. Anything else fails with a reason.
    static func parseList(_ data: Data) -> Result<BeadList, LaterParseError> {
        let wires: [Lossy<WireBead>]
        do {
            wires = try JSONDecoder().decode([Lossy<WireBead>].self, from: data)
        } catch {
            return .failure(LaterParseError(what: "a JSON array of beads", got: preview(data), cause: "\(error)"))
        }
        var beads: [Bead] = []
        var unreadable = 0
        for w in wires {
            guard let w = w.value, let bead = bead(w) else { unreadable += 1; continue }
            beads.append(bead)
        }
        return .success(BeadList(beads: beads, unreadable: unreadable))
    }

    /// Parse a `bd create --json` answer: one bead.
    static func parseOne(_ data: Data) -> Result<Bead, LaterParseError> {
        let wire: WireBead
        do {
            wire = try JSONDecoder().decode(WireBead.self, from: data)
        } catch {
            return .failure(LaterParseError(what: "one bead as JSON", got: preview(data), cause: "\(error)"))
        }
        guard let b = bead(wire) else {
            return .failure(LaterParseError(what: "a bead with an id, a title and readable dates", got: preview(data), cause: "a field was empty or a date unreadable"))
        }
        return .success(b)
    }

    private static func bead(_ w: WireBead) -> Bead? {
        guard !w.id.isEmpty, let created = Date.iso(w.created_at) else { return nil }
        var deferUntil: Date?
        if let d = w.defer_until {
            guard let parsed = Date.iso(d) else { return nil }
            deferUntil = parsed
        }
        return Bead(id: BeadID(raw: w.id), title: w.title, description: w.description ?? "",
                    status: BeadStatus(wire: w.status), priority: w.priority ?? 2,
                    labels: w.labels ?? [], createdAt: created, deferUntil: deferUntil,
                    origin: w.metadata?.value?.mcmonad?.value)
    }

    /// The start of an answer that did not parse: enough to recognise it,
    /// not the whole of what may be a long description.
    private static func preview(_ data: Data) -> String {
        clip(String(decoding: data.prefix(400), as: UTF8.self), 200)
    }

    // MARK: Small pure helpers

    static func clip(_ s: String, _ limit: Int) -> String {
        s.count <= limit ? s : String(s.prefix(limit)) + "…"
    }

    /// A tilde fence longer than any run of tildes in `text`, so the text
    /// cannot close it early. (Backticks inside cannot close a tilde fence.)
    static func fence(for text: String) -> String {
        var longest = 0, run = 0
        for c in text {
            if c == "~" { run += 1; longest = max(longest, run) } else { run = 0 }
        }
        return String(repeating: "~", count: max(3, longest + 1))
    }

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

    /// A screenshot's file name, without the extension: when, then which
    /// window, so a directory listing reads in the order things were saved.
    static func screenshotName(at date: Date, windowId: UInt32, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "\(f.string(from: date))-w\(windowId)"
    }

    static func stamp(_ date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
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

    private static func standingLabel(_ bead: Bead, _ standing: BeadStanding, now: Date) -> String {
        switch standing {
        case .started: return "started"
        case .ready: return "ready"
        case .waiting:
            if let until = bead.deferUntil, until > now { return "snoozed, back in " + span(from: now, to: until) }
            return bead.status.label
        }
    }
}

/// bd answered with something that is not what was asked for.
struct LaterParseError: Error, Equatable, Sendable, CustomStringConvertible {
    let what: String
    let got: String
    let cause: String
    var description: String { "expected \(what); got “\(got)” (\(cause))" }
}

extension Date {
    /// bd writes RFC 3339 with or without fractional seconds.
    static func iso(_ s: String) -> Date? {
        if let d = try? Date(s, strategy: .iso8601) { return d }
        return try? Date(s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    var iso: String { formatted(.iso8601) }
}
