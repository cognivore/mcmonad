import AppKit
import ScreenCaptureKit
import Vision
import os

/// An in-memory index of the text on every window the WM currently
/// displays, read off their pixels with Vision, so the launcher can search
/// inside windows and the "where is" question can cite their contents.
///
/// Privacy contract, in one place: what comes off the framebuffer stays in
/// this process's memory. Captures are `CGImage`s that die with the cycle;
/// recognised text is stored only in `entries`; nothing here is logged,
/// persisted, or sent over the IPC socket. The brain only ever says on/off.
///
/// Capture is ScreenCaptureKit's per-window screenshot (the window's own
/// buffer, so a partly covered window still reads whole), never the
/// `screencapture` tool (which writes a file). Recognition is understudy's
/// Vision setup: accurate level, language correction, reading order by line.
/// A window is re-read only when its pixels changed (byte hash), so a quiet
/// desktop costs nothing between cycles.
@MainActor
final class ScreenIndex {
    private static let logger = Logger(subsystem: "com.mcmonad.core", category: "ScreenIndex")

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

    private(set) var availability: Availability = .disabled
    private var entries: [UInt32: Entry] = [:]
    /// Windows on displayed workspaces, per the brain's latest snapshot.
    private var visible: [UInt32] = []
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

    /// The brain's view of what is displayed. Entries for windows that are
    /// gone from every workspace are dropped; the rest stay until re-read.
    func noteSnapshot(_ snapshot: OverlaySnapshot) {
        guard isEnabled else { return }
        visible = snapshot.screens.flatMap { $0.windows.map(\.windowId) }
        var all = Set(visible)
        for ws in snapshot.hiddenWorkspaces { for w in ws.windows { all.insert(w.windowId) } }
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

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            Self.logger.error("shareable content: \(error.localizedDescription, privacy: .public)")
            return
        }
        let byId = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        var changed = 0
        for id in visible {
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
                Self.logger.debug("capture wid=\(id) failed: \(error.localizedDescription, privacy: .public)")
                continue
            }
            let hash = Self.hash(image)
            if let old = entries[id], old.imageHash == hash { continue }
            let text = await Self.recognise(Sendable(image: image)).joined(separator: "\n")
            entries[id] = Entry(text: text, lower: text.lowercased(), textHash: text.hashValue, imageHash: hash)
            changed += 1
            guard isEnabled else { return }   // disabled mid-cycle: stop reading
        }
        if changed > 0 {
            Self.logger.info("screen index: re-read \(changed, privacy: .public) of \(self.visible.count, privacy: .public) displayed windows")
            onUpdated?()
        }
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
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Pixels → text (off the main actor)

    /// CGImage is not Sendable in the SDK's eyes; it is immutable, and we hand
    /// it to exactly one reader.
    private struct Sendable: @unchecked Swift.Sendable { let image: CGImage }

    private nonisolated static func recognise(_ boxed: Sendable) async -> [String] {
        await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-US"]
            request.minimumTextHeight = 0
            do {
                try VNImageRequestHandler(cgImage: boxed.image, options: [:]).perform([request])
            } catch {
                return []
            }
            let observations = (request.results ?? []).compactMap { o -> (CGRect, String)? in
                o.topCandidates(1).first.map { (o.boundingBox, $0.string) }
            }
            return TextSearch.readingOrder(observations)
        }.value
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
