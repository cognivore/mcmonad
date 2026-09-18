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
/// order by line. A window is re-read only when its picture changed by more
/// than a cursor blink (a coarse grey thumbnail, compared cell by cell), so a
/// quiet desktop costs nothing between cycles. Displayed windows
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
        /// The coarse grey thumbnail the text was read from.
        fileprivate let thumb: [UInt8]
    }

    static let hiddenSweep: TimeInterval = 30
    static let readsPerCycle = 6
    /// Thumbnail side, and how much of it must differ before a re-read: a
    /// blinking cursor or a clock digit is a cell or two of 1024.
    nonisolated static let thumbSide = 32
    nonisolated static let changedFraction = 0.01

    private(set) var availability: Availability = .disabled
    private var entries: [UInt32: Entry] = [:]
    /// Windows on displayed workspaces, per the brain's latest snapshot.
    private var visible: [UInt32] = []
    /// Windows parked on hidden workspaces, per the same snapshot.
    private var hidden: [UInt32] = []
    /// The current sweep's remaining parked windows, drained a few per cycle.
    private var hiddenQueue: [UInt32] = []
    private var hiddenSweepStarted = Date.distantPast
    private var periodic: Timer?
    private var scheduled = false
    private var inFlight = false
    private var openedSettings = false
    private var noticedReplacement = false
    /// Consecutive cycles the preflight said "not granted". A deploy replaces
    /// and re-signs the bundle under the still-running old daemon, whose
    /// preflight then fails for a few seconds before the launcher kills it;
    /// acting on one failed check turned every deploy into a system prompt.
    private var deniedCycles = 0
    private static let deniedCyclesBeforeAsking = 3

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
        // A deploy replaced the bundle under this process: TCC no longer
        // recognises it and the launcher restarts it shortly. Nothing it
        // could ask for now would be about a grant that was lost.
        if PermissionAudit.executableReplaced {
            if !noticedReplacement {
                noticedReplacement = true
                Self.logger.info("executable replaced on disk; index paused until the restart")
            }
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            deniedCycles += 1
            if deniedCycles >= Self.deniedCyclesBeforeAsking { markDenied() }
            return
        }
        deniedCycles = 0
        if availability == .denied { availability = .ready }
        inFlight = true
        defer { inFlight = false }

        // Displayed windows every cycle. Parked ones are swept once per
        // `hiddenSweep`: the sweep queues them all and each cycle drains as
        // many as the cap leaves after the displayed ones, so every parked
        // window is examined about once per sweep and never more often.
        if hiddenQueue.isEmpty, Date().timeIntervalSince(hiddenSweepStarted) >= Self.hiddenSweep {
            hiddenSweepStarted = Date()
            hiddenQueue = hidden.filter { !visible.contains($0) }
        }
        let ids = visible + hiddenQueue
        let known = entries.mapValues(\.thumb)
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        let (readings, examined) = await Self.read(ids: ids, knownThumbs: known, scale: scale, limit: Self.readsPerCycle)
        guard isEnabled else { return }   // disabled mid-cycle: drop what was read
        hiddenQueue.removeAll { examined.contains($0) }
        for (id, r) in readings {
            entries[id] = Entry(text: r.text, lower: r.text.lowercased(), textHash: r.text.hashValue, thumb: r.thumb)
        }
        if !readings.isEmpty {
            let hiddenRead = readings.keys.filter { !visible.contains($0) }.count
            Self.logger.info("screen index: re-read \(readings.count, privacy: .public) window(s) (\(readings.count - hiddenRead, privacy: .public) of \(self.visible.count, privacy: .public) displayed, \(hiddenRead, privacy: .public) of \(self.hidden.count, privacy: .public) hidden)")
            onUpdated?()
        }
    }

    /// One window's pixels, reduced to what may leave the reading thread.
    private struct Reading: Sendable {
        let thumb: [UInt8]
        let text: String
    }

    /// Off the main actor end to end. ScreenCaptureKit's content and
    /// windows, the captured image and Vision's observations are not
    /// Sendable, so none of them come back; only readings for windows
    /// whose picture differs from `knownThumbs` do — at most `limit` of them,
    /// in the order given — plus the set of ids that were examined before
    /// the cap stopped the pass (a window not capturable counts as examined).
    private nonisolated static func read(ids: [UInt32], knownThumbs: [UInt32: [UInt8]], scale: CGFloat, limit: Int) async -> ([UInt32: Reading], Set<UInt32>) {
        let content: SCShareableContent
        do {
            // Parked windows sit 1 px on screen; ask for everything anyway.
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            logger.error("shareable content: \(error.localizedDescription, privacy: .public)")
            return ([:], [])
        }
        let byId = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [UInt32: Reading] = [:]
        var examined = Set<UInt32>()
        for id in ids {
            if out.count >= limit { return (out, examined) }
            examined.insert(id)
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
            let thumb = thumbprint(image)
            if let old = knownThumbs[id], !changed(old, thumb) { continue }
            out[id] = Reading(thumb: thumb, text: recognise(image).joined(separator: "\n"))
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

    /// The window as a `thumbSide`² grey thumbnail: cheap to make, and
    /// coarse enough that a cursor or a clock does not count as a repaint.
    private nonisolated static func thumbprint(_ image: CGImage) -> [UInt8] {
        let side = thumbSide
        var pixels = [UInt8](repeating: 0, count: side * side)
        pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return pixels
    }

    /// True when more than `changedFraction` of the cells moved noticeably.
    private nonisolated static func changed(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return true }
        var moved = 0
        for i in a.indices where abs(Int(a[i]) - Int(b[i])) > 24 { moved += 1 }
        return Double(moved) / Double(a.count) > changedFraction
    }
}
