import Foundation

/// "What's up" answers, cached per workspace and kept current by what the
/// window manager reports — told, never asked. Every snapshot the brain
/// pushes and every screen-index re-read is folded into a per-workspace
/// fingerprint; only workspaces whose fingerprint moved are ever sent back
/// to the model, batched into one call:
///
///   * a change to a workspace's *window set* (windows added, removed,
///     moved) refreshes in the background after a short quiet period, never
///     more than one call per `minGap`;
///   * a change to titles or recognised text only marks the workspace stale;
///     it is refreshed when the user opens "what's up", which shows the
///     cached rows at once and swaps in the fresh ones when the call lands.
///
/// So opening "what's up" is instant, and a workspace that did not change
/// costs nothing — no call, no tokens.
@MainActor
final class WhatsUpCache {
    struct Fingerprint: Equatable {
        /// Window ids and their apps.
        let structure: Int
        /// Titles and recognised text.
        let text: Int
    }

    enum Staleness: Equatable {
        case fresh
        case textChanged
        case structureChanged
    }

    struct Entry: Equatable {
        var summary: WhatsUp.Summary?
        var fingerprint: Fingerprint
        var staleness: Staleness
    }

    struct Row: Equatable {
        let tag: String
        let summary: WhatsUp.Summary?
        /// A call for this workspace is in flight.
        let refreshing: Bool
    }

    static let quietPeriod: TimeInterval = 3
    static let minGap: TimeInterval = 20

    private(set) var entries: [String: Entry] = [:]
    /// Workspaces with windows, on-screen first — the manifold's order.
    private(set) var order: [String] = []
    private var snapshot: OverlaySnapshot?
    private let text: (UInt32) -> String?
    private let textHash: (UInt32) -> Int?
    private let runner = AskRunner()
    private var inFlight: [String: Fingerprint] = [:]
    private var pendingGeneration = 0
    private var lastCallEnded = Date.distantPast

    /// Fires whenever rows may have changed (a call started or landed).
    var onUpdated: (() -> Void)?
    var isRefreshing: Bool { !inFlight.isEmpty }

    init(text: @escaping (UInt32) -> String?, textHash: @escaping (UInt32) -> Int?) {
        self.text = text
        self.textHash = textHash
        runner.onFinished = { [weak self] outcome in self?.finished(outcome) }
    }

    // MARK: - Told by the window manager

    func noteSnapshot(_ snap: OverlaySnapshot) {
        snapshot = snap
        refingerprint()
        scheduleBackgroundRefresh()
    }

    func noteTextChanged() {
        refingerprint()
        scheduleBackgroundRefresh()
    }

    /// The user opened "what's up": everything stale is worth a call now.
    func refreshNow() {
        refreshDue(userAsked: true)
    }

    var rows: [Row] {
        order.map { Row(tag: $0, summary: entries[$0]?.summary, refreshing: inFlight[$0] != nil) }
    }

    // MARK: - Fingerprints

    private func refingerprint() {
        guard let snap = snapshot else { return }
        var present: [(String, [OverlayWindowEntry])] = []
        for s in snap.screens where !s.windows.isEmpty { present.append((s.workspaceTag, s.windows)) }
        for w in snap.hiddenWorkspaces where !w.windows.isEmpty { present.append((w.tag, w.windows)) }
        order = present.map(\.0)
        var next: [String: Entry] = [:]
        for (tag, windows) in present {
            let fp = Self.fingerprint(windows, textHash: textHash)
            if var e = entries[tag] {
                if e.fingerprint.structure != fp.structure {
                    e.staleness = .structureChanged
                } else if e.fingerprint.text != fp.text, e.staleness == .fresh {
                    e.staleness = .textChanged
                }
                e.fingerprint = fp
                next[tag] = e
            } else {
                next[tag] = Entry(summary: nil, fingerprint: fp, staleness: .structureChanged)
            }
        }
        entries = next
    }

    static func fingerprint(_ windows: [OverlayWindowEntry], textHash: (UInt32) -> Int?) -> Fingerprint {
        var s = Hasher(), t = Hasher()
        for w in windows.sorted(by: { $0.windowId < $1.windowId }) {
            s.combine(w.windowId)
            s.combine(w.appName)
            t.combine(w.windowId)
            t.combine(w.title)
            t.combine(textHash(w.windowId))
        }
        return Fingerprint(structure: s.finalize(), text: t.finalize())
    }

    /// Workspaces worth a call: window-set changes always, text changes
    /// only when the user asked.
    func due(userAsked: Bool) -> Set<String> {
        Set(entries.compactMap { tag, e in
            guard inFlight[tag] == nil else { return nil }
            switch e.staleness {
            case .fresh: return nil
            case .structureChanged: return tag
            case .textChanged: return userAsked ? tag : nil
            }
        })
    }

    // MARK: - Calls

    /// Trailing debounce: the last event in a burst wins.
    private func scheduleBackgroundRefresh() {
        pendingGeneration += 1
        let generation = pendingGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.quietPeriod))
            guard let self, self.pendingGeneration == generation else { return }
            self.refreshDue(userAsked: false)
        }
    }

    private func refreshDue(userAsked: Bool) {
        guard !isRefreshing, let snap = snapshot else { return }
        let tags = due(userAsked: userAsked)
        guard !tags.isEmpty else { return }
        if !userAsked {
            let wait = Self.minGap - Date().timeIntervalSince(lastCallEnded)
            if wait > 0 {
                pendingGeneration += 1
                let generation = pendingGeneration
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(wait))
                    guard let self, self.pendingGeneration == generation else { return }
                    self.refreshDue(userAsked: false)
                }
                return
            }
        }
        let manifold = Ask.manifold(question: WhatsUp.question, snapshot: snap, text: text, only: tags)
        for tag in tags { inFlight[tag] = entries[tag]?.fingerprint }
        let known = manifold.tags
        runner.start(prompt: Ask.prompt(for: manifold), arguments: WhatsUp.arguments) {
            WhatsUp.parseLine($0, knownTags: known)
        }
        onUpdated?()
    }

    private func finished(_ outcome: Ask.Outcome) {
        lastCallEnded = Date()
        let asked = inFlight
        inFlight = [:]
        if case .answered(.workspaces(let summaries, _)) = outcome {
            apply(summaries, asked: asked)
        }
        // On any failure the entries stay stale; the next report retries.
        onUpdated?()
        if !due(userAsked: false).isEmpty { scheduleBackgroundRefresh() }
    }

    /// Fold an answer in. A workspace whose fingerprint moved during the
    /// call keeps its new summary but stays stale, so it is asked again.
    func apply(_ summaries: [WhatsUp.Summary], asked: [String: Fingerprint]) {
        for s in summaries {
            guard var e = entries[s.tag] else { continue }
            e.summary = s
            if asked[s.tag] == e.fingerprint { e.staleness = .fresh }
            entries[s.tag] = e
        }
    }
}
