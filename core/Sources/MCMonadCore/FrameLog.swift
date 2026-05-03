import Foundation
import CoreGraphics

/// Structured frame-event logging. Counterpart to FocusLog but for the
/// window-positioning path: every set-frames command, every individual
/// AX position/size write, and every SkyLight-observed move/resize.
///
/// Format:
///   FRAME seq=<n> src=<source> wid=<id|-> pid=<pid|-> rect=<(x,y,w,h)|-> [result=<...>] [extra...]
///
/// The seq is monotonic across the process and independent from FocusLog's
/// seq, so a join on (timestamp, wid) is the way to correlate the two
/// streams.
///
/// **NEVER include window titles in log output.** The user's window titles
/// commonly contain sensitive identifiers (contract names, document
/// content, internal project names). If a future call site needs per-window
/// disambiguation beyond (windowId, pid), add a stable hash here — do not
/// log raw text.
enum FrameLog {
    enum Source: String {
        // Inbound command from Haskell
        case cmdSetFramesBegin       // entry to executeSetFrames

        // Per-assignment AX writes (every assignment emits 3: size/pos/size
        // across the three phases that mirror executeSetFrames)
        case cmdAxSize               // AXUIElementSetAttributeValue(kAXSize)
        case cmdAxPos                // AXUIElementSetAttributeValue(kAXPosition)

        // Per-assignment AX element resolution failure (window not findable)
        case cmdAxResolveFail

        // Outcome from the SkyLight observer — ground truth for what
        // actually happened on screen, post-coalesce
        case observed                // windowMoved/windowResized fired
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
