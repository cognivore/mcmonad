import Foundation
import CoreGraphics

/// Structured frame-event logging. Counterpart to FocusLog but for the
/// window-positioning path: every set-frames command, every individual
/// AX position/size write, and every SkyLight-observed move/resize.
///
/// Format:
///   FRAME seq=<n> src=<source> wid=<id|-> pid=<pid|-> rect=<(x,y,w,h)|-> [tHash=<...>] [result=<...>] [extra...]
///
/// The seq is monotonic across the process and independent from FocusLog's
/// seq, so a join on (timestamp, wid) is the way to correlate the two
/// streams.
///
/// **NEVER include raw window titles in log output.** The user's window
/// titles commonly contain sensitive identifiers (contract names, document
/// content, internal project names). For per-window disambiguation beyond
/// (windowId, pid), pass `tHash:` — the salted, truncated SHA-256 from
/// `TitleHash.hash(...)`. Do not log raw title text.
enum FrameLog {
    enum Source: String {
        // Inbound command from Haskell
        case cmdSetFramesBegin       // entry to executeSetFrames

        // Per-assignment SkyLight read BEFORE we issue any AX writes
        // for this set-frames. Lets us see if the window was already
        // pinned somewhere unexpected (e.g. hide-position 5128) before
        // we even started, vs. a position that this set-frames is
        // about to bump it to.
        case preMove

        // Per-assignment AX writes (every assignment emits 3: size/pos/size
        // across the three phases that mirror executeSetFrames)
        case cmdAxSize               // AXUIElementSetAttributeValue(kAXSize)
        case cmdAxPos                // AXUIElementSetAttributeValue(kAXPosition)

        // Per-assignment AX element resolution failure (window not findable)
        case cmdAxResolveFail

        // Per-window invocation of AXWindowService.setFrame from
        // executeHideWindows. Tags the move that parks a window off-screen
        // so we can correlate "wid X was hidden at seq=A" with "wid X
        // appears pinned at the hide position from seq=A onward".
        case cmdHideMove

        // Outcome from the SkyLight observer — ground truth for what
        // actually happened on screen, post-coalesce. Often silent for
        // self-initiated moves because of disableUpdate brackets and
        // observer coalescing — use 'verified' instead for self-moves.
        case observed                // windowMoved/windowResized fired

        // Deterministic per-window readback at the end of executeSetFrames:
        // queries SkyLight directly for the window's actual bounds and
        // compares to commanded. Independent of the observer, so it
        // survives disableUpdate and tells us per-assignment whether
        // each window obeyed the move.
        case verified
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _seq: UInt64 = 0

    private static func nextSeq() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        _seq &+= 1
        return _seq
    }

    static func emit(
        source: Source,
        windowId: UInt32? = nil,
        pid: Int32? = nil,
        rect: CGRect? = nil,
        tHash: String? = nil,
        result: String? = nil,
        extra: String? = nil
    ) {
        let seq = nextSeq()
        var line = "FRAME seq=\(seq) src=\(source.rawValue)"
        line += " wid=" + (windowId.map { String($0) } ?? "-")
        line += " pid=" + (pid.map { String($0) } ?? "-")
        if let r = rect {
            line += " rect=(\(fmt(r.origin.x)),\(fmt(r.origin.y)),\(fmt(r.width)),\(fmt(r.height)))"
        } else {
            line += " rect=-"
        }
        if let tHash = tHash { line += " tHash=\(tHash)" }
        if let result = result { line += " result=\(result)" }
        if let extra = extra { line += " " + extra }
        fputs(line + "\n", stderr)
    }

    private static func fmt(_ d: CGFloat) -> String {
        // Trim trailing zeros so "1146.0" → "1146", but keep "705.5" intact.
        // Greppability matters more than precision in this log.
        let s = String(format: "%.1f", Double(d))
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }
}
