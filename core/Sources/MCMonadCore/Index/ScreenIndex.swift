import AppKit
import ScreenCaptureKit
import Vision
import os

/// An in-memory index of the text on every window the WM manages — the
/// displayed ones and the ones parked on hidden workspaces — read off their
/// pixels with Vision, so the launcher can search inside windows and the
/// "where is" / "what's up" questions can cite their contents.
///
/// Privacy contract, in one place: what comes off the framebuffer stays in
/// this process's memory. Captures are `CGImage`s that die with the cycle;
/// recognised text is stored only in `entries`; nothing here is logged,
/// persisted, or sent over the IPC socket. The brain only ever says on/off.
///
/// Capture is ScreenCaptureKit's per-window screenshot (the window's own
/// buffer, so a covered or parked window reads just like a visible one),
/// never the `screencapture` tool (which writes a file). Recognition is
/// understudy's Vision setup: accurate level, language correction, reading
/// order by line. A window is re-read only when its pixels changed (byte
/// hash), so a quiet desktop costs nothing between cycles. Displayed windows
/// are checked every cycle; hidden ones every `hiddenSweep`, displayed first,
/// at most `readsPerCycle` recognitions per cycle so a big sweep spreads out.
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

    /// One window's last reading.
    struct Entry {
        let text: String
        /// `text.lowercased()`, kept because it is the hot path of search.
        let lower: String
        /// Changes when the words change; the "what's up" cache keys on it.
        let textHash: Int
        fileprivate let imageHash: Int
    }

    static let hiddenSweep: TimeInterval = 30
    static let readsPerCycle = 6

    private(set) var availability: Availability = .disabled
    private var entries: [UInt32: Entry] = [:]
    /// Windows on displayed workspaces, per the brain's latest snapshot.
    private var visible: [UInt32] = []
    /// Windows parked on hidden workspaces, per the same snapshot.
    private var hidden: [UInt32] = []
    private var lastHiddenSweep = Date.distantPast
    private var periodic: Timer?
    private var scheduled = false
    private var inFlight = false
    private var openedSettings = false

    /// Fires after a cycle that changed at least one entry.
    var onUpdated: (() -> Void)?

    var isEnabled: Bool { availability != .disabled }

    func entry(for windowId: UInt32) -> Entry? { entries[windowId] }

    // MARK: - Control (from the brain)

    func setEnabled(_ on: Bool) {
        if on {
            guard availability == .disabled else { return }
            availability = .ready
            periodic = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.requestSoon(after: 0) }
            }
            Self.logger.info("screen index enabled")
            requestSoon(after: 0.5)
        } else {
            guard availability != .disabled else { return }
            availability = .disabled
            periodic?.invalidate()
            periodic = nil
            entries.removeAll()
            Self.logger.info("screen index disabled; memory cleared")
        }
    }

    /// The brain's view of every window it manages. Entries for windows
    /// that are gone from every workspace are dropped; the rest stay until
    /// re-read.
    func noteSnapshot(_ snapshot: OverlaySnapshot) {
        guard isEnabled else { return }
        visible = snapshot.screens.flatMap { $0.windows.map(\.windowId) }
        hidden = snapshot.hiddenWorkspaces.flatMap { $0.windows.map(\.windowId) }
        let all = Set(visible).union(hidden)
        for id in entries.keys where !all.contains(id) { entries.removeValue(forKey: id) }
        requestSoon()
    }

    /// Something visible probably changed (layout, focus): re-read soon,
    /// coalescing bursts into one cycle.
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

    // MARK: - One reading of the displayed windows

    private func cycle() async {
        guard isEnabled, !inFlight else { return }
        guard CGPreflightScreenCaptureAccess() else {
            markDenied()
            return
        }
        if availability == .denied { availability = .ready }
        inFlight = true
        defer { inFlight = false }

        // Displayed windows every cycle; the parked ones ride along every
        // `hiddenSweep`, after the displayed ones so they never delay them.
        var ids = visible
        let sweepHidden = Date().timeIntervalSince(lastHiddenSweep) >= Self.hiddenSweep
        if sweepHidden { ids += hidden.filter { !visible.contains($0) } }
        let known = entries.mapValues(\.imageHash)
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        let (readings, exhausted) = await Self.read(ids: ids, knownHashes: known, scale: scale, limit: Self.readsPerCycle)
        guard isEnabled else { return }   // disabled mid-cycle: drop what was read
        // A sweep that hit the per-cycle cap is not over: the next cycle
        // continues it instead of waiting another `hiddenSweep`.
        if sweepHidden, exhausted { lastHiddenSweep = Date() }
        for (id, r) in readings {
            entries[id] = Entry(text: r.text, lower: r.text.lowercased(), textHash: r.text.hashValue, imageHash: r.hash)
        }
        if !readings.isEmpty {
            let hiddenRead = readings.keys.filter { !visible.contains($0) }.count
            Self.logger.info("screen index: re-read \(readings.count, privacy: .public) window(s) (\(readings.count - hiddenRead, privacy: .public) of \(self.visible.count, privacy: .public) displayed, \(hiddenRead, privacy: .public) of \(self.hidden.count, privacy: .public) hidden)")
            onUpdated?()
        }
    }

    /// One window's pixels, reduced to what may leave the reading thread.
    private struct Reading: Sendable {
        let hash: Int
        let text: String
    }

    /// Off the main actor end to end. ScreenCaptureKit's content and
    /// windows, the captured image and Vision's observations are not
    /// Sendable, so none of them come back; only readings for windows
    /// whose pixels differ from `knownHashes` do — at most `limit` of them,
    /// in the order given. The flag says whether `ids` was fully examined
    /// (false: the cap stopped the pass and some ids were never captured).
    private nonisolated static func read(ids: [UInt32], knownHashes: [UInt32: Int], scale: CGFloat, limit: Int) async -> ([UInt32: Reading], Bool) {
        let content: SCShareableContent
        do {
            // Parked windows sit 1 px on screen; ask for everything anyway.
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            logger.error("shareable content: \(error.localizedDescription, privacy: .public)")
            return ([:], false)
        }
        let byId = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [UInt32: Reading] = [:]
        for id in ids {
            if out.count >= limit { return (out, false) }
            guard let window = byId[id], window.frame.width >= 8, window.frame.height >= 8 else { continue }
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
            let hash = hash(image)
            if knownHashes[id] == hash { continue }
            out[id] = Reading(hash: hash, text: recognise(image).joined(separator: "\n"))
        }
        return (out, true)
    }

    private func markDenied() {
        if availability != .denied {
            availability = .denied
            Self.logger.error("Screen index needs Screen & System Audio Recording for MCMonadCore.app (System Settings ▸ Privacy & Security).")
        }
        // On macOS 26 CGRequestScreenCaptureAccess prompts nothing; a
        // ScreenCaptureKit query is what lists the app in the pane, unticked.
        // Do that once per process and open the pane so the user can tick it.
        guard !openedSettings else { return }
        openedSettings = true
        CGRequestScreenCaptureAccess()
        Task { @MainActor in
            await Self.registerInScreenRecordingPane()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// The query is what lists the app in the pane; its result is not needed.
    private nonisolated static func registerInScreenRecordingPane() async {
        _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    // MARK: - Pixels → text (off the main actor)

    private nonisolated static func recognise(_ image: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return []
        }
        let observations = (request.results ?? []).compactMap { o -> (CGRect, String)? in
            o.topCandidates(1).first.map { (o.boundingBox, $0.string) }
        }
        return TextSearch.readingOrder(observations)
    }

    /// A cheap fingerprint of the pixels: every 61st byte plus the length.
    /// Enough to notice a repaint; far cheaper than the OCR it gates.
    private nonisolated static func hash(_ image: CGImage) -> Int {
        guard let data = image.dataProvider?.data else { return 0 }
        let count = CFDataGetLength(data)
        guard let bytes = CFDataGetBytePtr(data) else { return count }
        var hasher = Hasher()
        hasher.combine(count)
        var i = 0
        while i < count {
            hasher.combine(bytes[i])
            i += 61
        }
        return hasher.finalize()
    }
}
