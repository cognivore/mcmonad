import AppKit
import Carbon
import ScreenCaptureKit
import os

// AI-assisted update (text history: reading only what changed, looks while the
// user works, the day's history): model claude-opus-5-5; reasoning effort
// unavailable (not exposed by the harness).

/// An in-memory index of the text on every window the WM manages — the
/// displayed ones and the ones parked on hidden workspaces — read off their
/// pixels with Vision, so the launcher can search inside windows and the
/// "where is" / "what's up" questions can cite their contents, and of what
/// they said over the last day (`TextHistory`).
///
/// Captures are `CGImage`s that die with the cycle; the index keeps text,
/// and per window only hashes of its last capture's pixel strips, in
/// memory, and never logs, persists or sends them over IPC. Cloud
/// disclosure is separate: an explicitly confirmed launcher search, or
/// explicitly enabled What's up monitoring, may send excerpts to Claude.
/// The brain only ever says whether local indexing is on or off.
///
/// Capture is ScreenCaptureKit's per-window screenshot (the window's own
/// buffer, so a covered or parked window reads just like a visible one),
/// never the `screencapture` tool (which writes a file). A window is read
/// the way ocr-predictor reads a screen (`WindowPage`): its text is
/// believed while its pixels stay the same, and only the lines whose pixels
/// changed are read again; a scroll moves the lines it carried. A look at a
/// window that did not change costs a capture and a hash, no recognition.
///
/// Windows are looked at in two ways, never more often than the user's
/// work warrants:
///   * while the user works: when the input to the focused window is
///     intense (`InputPulse`), that window is looked at, and again at most
///     once every `GlancePolicy.every` while it keeps getting it — wherever
///     it is by then;
///   * when the user steps away: after `idleAfter` without input, one pass
///     over every window (displayed first, then parked), `readsPerStep`
///     windows that changed at a time, then rest until the user has been
///     back and gone quiet again. A launcher query starting with "!" runs
///     a pass at once.
/// No window of the app holding secure input (a password is being typed) is
/// read, and nothing is read while the display sleeps unless asked with "!".
@MainActor
final class ScreenIndex {
    nonisolated private static let logger = Logger(subsystem: "com.mcmonad.core", category: "ScreenIndex")

    /// Why the index may have nothing to say. `denied` is the only state
    /// that needs the user (the launcher's hint says what to do).
    enum Availability: Equatable {
        case disabled
        case denied
        case ready
    }

    /// One window's current reading.
    struct Entry {
        let text: String
        /// `text.lowercased()`, kept because it is the hot path of search.
        let lower: String
        /// Changes when the words change; the "what's up" cache keys on it.
        let textHash: Int
    }

    static let idleAfter: TimeInterval = 180
    /// How often the input counters are sampled and due looks are taken.
    static let tick: TimeInterval = 5
    /// Windows that needed reading, per step of a pass.
    static let readsPerStep = 3
    /// Pixels one look may hand to Vision. Accurate recognition costs about
    /// 0.16 CPU-µs a pixel on this class of Mac (a 3000 × 1800 window, all
    /// of it, is 0.87 CPU-s; one changed line about 30 ms). A pass reads a
    /// window whole if it must; a look while the user works reads at most a
    /// third of a CPU-second and leaves the rest for its next look — except
    /// a window it has never read or that was resized, which it reads whole.
    nonisolated static let passBudget = 24_000_000
    nonisolated static let glanceBudget = 2_000_000
    /// How often the history forgets what is more than a day old.
    static let pruneEvery: TimeInterval = 300

    private(set) var availability: Availability = .disabled
    private var pages: [UInt32: WindowPage] = [:]
    private var entries: [UInt32: Entry] = [:]
    private(set) var history = TextHistory()
    private var pulse = InputPulse()
    private var policy = GlancePolicy()
    /// Windows on displayed workspaces, per the brain's latest snapshot.
    private var visible: [UInt32] = []
    /// Windows parked on hidden workspaces, per the same snapshot.
    private var hidden: [UInt32] = []
    private var focused: UInt32?
    /// Each managed window's process, to know which belong to the app that
    /// holds secure input.
    private var pids: [UInt32: Int32] = [:]
    /// The running pass: windows not yet looked at, displayed first.
    private var pass: [UInt32] = []
    private var forced = false
    /// The user's last input as of the pass that ran last; the next idle
    /// pass waits for input after it.
    private var passInputMark: Date?
    private(set) var lastPassEnded: Date?
    private(set) var lastGlance: Date?
    private var lastPrune = Date.distantPast
    private var periodic: Timer?
    private var scheduled = false
    private var inFlight = false
    private var openedSettings = false
    private var noticedReplacement = false
    /// Since when the preflight has said "not granted", without a break. A
    /// deploy replaces and re-signs the bundle under the still-running old
    /// daemon, whose preflight then fails for a while before the launcher
    /// kills it; acting on one failed check turned every deploy into a
    /// system prompt. Cycles now come every few seconds, so the grace is a
    /// time, not a count.
    private var deniedSince: Date?
    private static let deniedFor: TimeInterval = 90

    /// Fires after a cycle that changed at least one entry, and after every
    /// step of a forced pass so the launcher can show it moving.
    var onUpdated: (() -> Void)?
    /// Fires when a pass has looked at every window; true for a forced one.
    var onPassEnded: ((Bool) -> Void)?

    var isEnabled: Bool { availability != .disabled }
    /// Windows the running pass has still to look at.
    var passRemaining: Int { pass.count }

    func entry(for windowId: UInt32) -> Entry? { entries[windowId] }

    /// One line for the menubar.
    var status: String {
        switch availability {
        case .disabled: return "off"
        case .denied: return "needs Screen Recording"
        case .ready:
            let last = [lastGlance, lastPassEnded].compactMap { $0 }.max().map { "last read \(Self.hhmm($0))" } ?? "nothing read yet"
            return "\(entries.count) windows · \(history.lineCount) lines from the last day · \(last) · reads a window you work in at most every \(Int(GlancePolicy.every / 60)) min, all after \(Int(Self.idleAfter / 60)) min without input"
        }
    }

    nonisolated static func hhmm(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute())
    }

    /// Seconds since the user last touched keyboard or mouse.
    nonisolated static func secondsSinceInput() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// Windows that may not be read now: those of the app holding secure
    /// input (a password is being typed), as the session names it; every
    /// window when secure input is on and no app is named.
    private func guardedWindows() -> Set<UInt32> {
        guard IsSecureEventInputEnabled() else { return [] }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        guard let pid = (session?["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value, pid > 0 else {
            return Set(visible).union(hidden)
        }
        return Set(pids.filter { $0.value == pid }.keys)
    }

    /// The HID system's running counts of keys, clicks and scroll steps.
    nonisolated static func inputCounts() -> InputPulse.Counts {
        func n(_ t: CGEventType) -> UInt32 { CGEventSource.counterForEventType(.hidSystemState, eventType: t) }
        return InputPulse.Counts(keys: n(.keyDown),
                                 clicks: n(.leftMouseDown) &+ n(.rightMouseDown) &+ n(.otherMouseDown),
                                 scrolls: n(.scrollWheel))
    }

    // MARK: - Control (from the brain and the launcher)

    func setEnabled(_ on: Bool) {
        if on {
            guard availability == .disabled else { return }
            availability = .ready
            periodic = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tickInput() }
            }
            Self.logger.info("screen index enabled")
            requestSoon(after: 0.5)
        } else {
            guard availability != .disabled else { return }
            availability = .disabled
            periodic?.invalidate()
            periodic = nil
            pages.removeAll()
            entries.removeAll()
            history.removeAll()
            policy = GlancePolicy()
            pulse = InputPulse()
            pass.removeAll()
            forced = false
            Self.logger.info("screen index disabled; memory cleared")
        }
    }

    /// The brain's view of every window it manages. Pages for windows gone
    /// from every workspace are dropped (their history stays, as closed, for
    /// a day); the rest stay until re-read. Titles go into the history.
    func noteSnapshot(_ snapshot: OverlaySnapshot) {
        guard isEnabled else { return }
        visible = snapshot.screens.flatMap { $0.windows.map(\.windowId) }
        hidden = snapshot.hiddenWorkspaces.flatMap { $0.windows.map(\.windowId) }
        focused = snapshot.screens.lazy.flatMap(\.windows).first { $0.isFocused }?.windowId
        pids = Dictionary((snapshot.screens.flatMap(\.windows) + snapshot.hiddenWorkspaces.flatMap(\.windows))
            .map { ($0.windowId, $0.pid) }, uniquingKeysWith: { a, _ in a })
        var present: [(id: UInt32, app: String, title: String, tag: String?)] = []
        for s in snapshot.screens { for w in s.windows { present.append((w.windowId, w.appName ?? "?", w.title ?? "", s.workspaceTag)) } }
        for ws in snapshot.hiddenWorkspaces { for w in ws.windows { present.append((w.windowId, w.appName ?? "?", w.title ?? "", ws.tag)) } }
        history.noteWindows(present, at: Date())
        let all = Set(visible).union(hidden)
        for id in pages.keys where !all.contains(id) { pages.removeValue(forKey: id) }
        for id in entries.keys where !all.contains(id) { entries.removeValue(forKey: id) }
        policy.keep(only: all)
        pass.removeAll { !all.contains($0) }
    }

    /// A "!" query: look at every window now, whatever the user is doing.
    func reindexNow() {
        guard isEnabled else { return }
        pass = visible + hidden.filter { !visible.contains($0) }
        forced = true
        passInputMark = Date()
        requestSoon(after: 0)
    }

    /// Run a cycle soon, coalescing bursts into one.
    func requestSoon(after delay: TimeInterval = 0.8) {
        guard isEnabled, !scheduled else { return }
        scheduled = true
        Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self else { return }
            self.scheduled = false
            await self.cycle()
        }
    }

    /// Every `tick`: how hard the user is working, and in which window.
    /// Counts only; then a cycle, which looks at whatever is due.
    private func tickInput() {
        guard isEnabled else { return }
        let now = Date()
        let score = pulse.note(Self.inputCounts(), at: now)
        if let f = focused {
            if Self.secondsSinceInput() < Self.tick { history.noteInput(f, at: now) }
            if InputPulse.isIntense(score) { policy.noteIntense(f, at: now) }
        }
        if now.timeIntervalSince(lastPrune) >= Self.pruneEvery {
            lastPrune = now
            history.prune(now: now)
        }
        requestSoon(after: 0)
    }

    /// What the history says about `windows` for a question with `terms`.
    func evidence(windows: [UInt32], terms: [String], budget: Int) -> (windows: [UInt32: HistoryEvidence.ForWindow], closed: [HistoryEvidence.Closed]) {
        let onScreen: (UInt32) -> Set<String> = { [pages] id in
            Set((pages[id]?.rows ?? []).map(TextHistory.key))
        }
        return HistoryEvidence.select(history, windows: windows, onScreen: onScreen, terms: terms,
                                      budget: budget, clock: Self.hhmm)
    }

    // MARK: - One step

    private func cycle() async {
        guard isEnabled, !inFlight else { return }
        let idle = Self.secondsSinceInput()
        let lastInput = Date(timeIntervalSinceNow: -idle)
        let awake = CGDisplayIsAsleep(CGMainDisplayID()) == 0
        if forced, pass.isEmpty { endPass(); return }
        if pass.isEmpty, !forced, awake, idle >= Self.idleAfter,
           passInputMark.map({ lastInput.timeIntervalSince($0) > 1 }) ?? true {
            // An idle pass starts once the user has been quiet for
            // `idleAfter` and has been back since the last pass began. The
            // last-input instant is recomputed each tick from a running
            // idle counter, so it drifts by milliseconds; a second's
            // tolerance keeps that drift from counting as a return.
            passInputMark = lastInput
            pass = visible + hidden.filter { !visible.contains($0) }
            if !pass.isEmpty {
                Self.logger.info("screen index: idle pass over \(self.pass.count, privacy: .public) windows")
            }
        }
        // A pass goes on while the user stays away and the display is awake
        // (or at once for "!"); otherwise the window they work in, if it is
        // due. No window of the app holding secure input is read either way.
        let guarded = guardedWindows()
        let inPass = !pass.isEmpty && (forced || (idle >= Self.idleAfter && awake))
        if inPass, !guarded.isEmpty {
            pass.removeAll { guarded.contains($0) }
            if pass.isEmpty { endPass(); return }
        }
        let due = inPass || !awake ? nil : policy.due(at: Date(), preferring: focused, skip: guarded)
        guard inPass || due != nil else { return }

        // Only now, with something to read, ask whether reading is allowed.
        // A deploy replaced the bundle under this process: TCC no longer
        // recognises it and the launcher restarts it shortly. Nothing it
        // could ask for now would be about a grant that was lost.
        if PermissionAudit.executableReplaced {
            if !noticedReplacement {
                noticedReplacement = true
                Self.logger.info("executable replaced on disk; index paused until the restart")
            }
            if forced { endPass(completed: false) }
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            let since = deniedSince ?? Date()
            deniedSince = since
            if Date().timeIntervalSince(since) >= Self.deniedFor { markDenied() }
            if forced { endPass(completed: false) }
            return
        }
        deniedSince = nil
        if availability == .denied { availability = .ready }

        if inPass {
            await step(ids: pass, budget: Self.passBudget, limit: Self.readsPerStep, inPass: true)
        } else if let due {
            await step(ids: [due], budget: Self.glanceBudget, limit: 1, inPass: false)
        }
    }

    /// Looks at `ids` in order until `limit` of them needed reading, and
    /// folds what was read into the pages, the entries and the history.
    private func step(ids: [UInt32], budget: Int, limit: Int, inPass: Bool) async {
        inFlight = true
        defer { inFlight = false }
        let started = Date()
        let (looked, examined) = await Self.look(ids: ids, pages: pages, displays: Self.attachedDisplays(),
                                                 budget: budget, limit: limit)
        guard isEnabled else { return }   // disabled mid-cycle: drop what was read
        let now = Date()
        let known = Set(visible).union(hidden)
        var changed = 0, read = 0, pixels = 0
        for (id, result) in looked where known.contains(id) {
            let (page, work) = result
            pages[id] = page
            policy.noteGlanced(id, at: now)
            if work.reads > 0 { read += 1; pixels += work.readPixels }
            history.record(id, rows: work.newRows, replaced: work.replacedRows, at: now)
            history.touch(id, rows: page.rows, at: now)
            let text = page.text
            if entries[id]?.text != text {
                entries[id] = Entry(text: text, lower: text.lowercased(), textHash: text.hashValue)
                changed += 1
            }
            if let fault = work.fault {
                Self.logger.error("screen index: recognition failed: \(fault.reason, privacy: .public)")
            }
        }
        // A window looked for and not captured (gone from ScreenCaptureKit's
        // list, excluded from capture, a failed query) waits its turn like
        // one that was read: else it is due again every tick, and while it
        // is focused no other owed window is ever looked at.
        for id in (inPass ? Array(examined) : ids) where looked[id] == nil { policy.noteGlanced(id, at: now) }
        if !inPass, !looked.isEmpty { lastGlance = now }
        if inPass {
            // Nothing examined means the window list itself failed: end the
            // pass rather than spin on it.
            if examined.isEmpty { endPass(completed: false); return }
            pass.removeAll { examined.contains($0) }
        }
        if read > 0 {
            let ms = Int(now.timeIntervalSince(started) * 1000)
            Self.logger.info("screen index: \(inPass ? "pass" : "look", privacy: .public) read \(read, privacy: .public) of \(looked.count, privacy: .public) window(s), \(pixels, privacy: .public) px in \(ms, privacy: .public) ms, \(self.pass.count, privacy: .public) left in pass")
        }
        if changed > 0 || (inPass && forced) { onUpdated?() }
        guard inPass else { return }
        if pass.isEmpty {
            endPass()
        } else {
            requestSoon(after: forced ? 0 : 1)   // finish the pass without waiting for the tick
        }
    }

    private func endPass(completed: Bool = true) {
        let wasForced = forced
        forced = false
        pass.removeAll()
        if completed { lastPassEnded = Date() }
        Self.logger.info("screen index: \(wasForced ? "forced" : "idle", privacy: .public) pass \(completed ? "done" : "unavailable", privacy: .public)")
        onPassEnded?(wasForced)
    }

    // MARK: - Pixels → text (off the main actor)

    /// Off the main actor end to end. ScreenCaptureKit's content and
    /// windows, the captured image and Vision's observations are not
    /// Sendable, so none of them come back: each looked-at window's page,
    /// updated, and what reading it cost. Windows are looked at in order
    /// until `limit` of them needed reading; `examined` is every id looked
    /// at (a window that cannot be captured counts as examined).
    private nonisolated static func look(ids: [UInt32], pages: [UInt32: WindowPage], displays: [Later.Display],
                                         budget: Int, limit: Int) async
        -> ([UInt32: (WindowPage, GlanceWork)], Set<UInt32>) {
        let content: SCShareableContent
        do {
            // Parked windows sit 1 px on screen; ask for everything anyway.
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            logger.error("shareable content: \(error.localizedDescription, privacy: .public)")
            return ([:], [])
        }
        let byId = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [UInt32: (WindowPage, GlanceWork)] = [:]
        var examined = Set<UInt32>()
        var readCount = 0
        for id in ids {
            if readCount >= limit { break }
            examined.insert(id)
            guard let window = byId[id], window.frame.width >= 8, window.frame.height >= 8 else { continue }
            // At the scale of the display holding most of the window: asked
            // for more, ScreenCaptureKit pads a 1× window instead of
            // enlarging it, and Vision finds nothing in the padding.
            let scale = Later.scale(for: window.frame, displays: displays)
            let cfg = SCStreamConfiguration()
            cfg.width = Int(window.frame.width * scale)
            cfg.height = Int(window.frame.height * scale)
            cfg.showsCursor = false
            let image: CGImage
            do {
                image = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(desktopIndependentWindow: window),
                    configuration: cfg
                )
            } catch {
                logger.debug("capture wid=\(id) failed: \(error.localizedDescription, privacy: .public)")
                continue
            }
            guard let tiles = VisionReader.tiles(of: image) else { continue }
            var page = pages[id] ?? WindowPage()
            // A first look, or a window resized (every re-tile does that), has
            // no lines to go on from: it is read whole, once, or its text
            // would be a third of itself until two more looks.
            let fresh = page.observe(tiles, at: Date()) == nil
            let work = page.read(budget: fresh ? max(budget, passBudget) : budget, at: Date()) { sample in
                VisionReader.recognise(image, in: sample)
            }
            if work.reads > 0 { readCount += 1 }
            out[id] = (page, work)
        }
        return (out, examined)
    }

    private func markDenied() {
        if availability != .denied {
            availability = .denied
            Self.logger.error("Screen index needs Screen & System Audio Recording for MCMonadCore.app (System Settings ▸ Privacy & Security).")
        }
        // Sustained denial: list the app in the pane (a ScreenCaptureKit
        // query does that) and open the pane, once per process. No
        // CGRequestScreenCaptureAccess: its dialog is what a deploy's
        // dying old daemon used to pop.
        guard !openedSettings else { return }
        openedSettings = true
        Task { @MainActor in
            await Self.registerInScreenRecordingPane()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// The attached displays, with where they are and their backing scale,
    /// read on the main actor the way `LaterController` reads them.
    private static func attachedDisplays() -> [Later.Display] {
        NSScreen.screens.compactMap { screen -> Later.Display? in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return Later.Display(bounds: CGDisplayBounds(n.uint32Value), scale: screen.backingScaleFactor)
        }
    }

    /// The query is what lists the app in the pane; its result is not needed.
    private nonisolated static func registerInScreenRecordingPane() async {
        _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    // MARK: - A whole picture's text

    /// Every line Vision reads off `image`, in reading order. The index
    /// itself reads only what changed (`WindowPage`); this reads a window
    /// saved for later (`LaterCapture`) whole.
    nonisolated static func recognise(_ image: CGImage) -> [String] {
        let whole = PixelRect(x: 0, y: 0, w: image.width, h: image.height)
        guard case .success(let lines) = VisionReader.recognise(image, in: whole) else { return [] }
        let w = Double(image.width), h = Double(image.height)
        // Back to Vision's normalised bottom-left boxes, which the reading
        // order is defined on.
        return TextSearch.readingOrder(lines.map { line in
            (CGRect(x: Double(line.rect.x) / w, y: 1 - Double(line.rect.bottom) / h,
                    width: Double(line.rect.w) / w, height: Double(line.rect.h) / h), line.text)
        })
    }
}
