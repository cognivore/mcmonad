import Foundation
import ApplicationServices

/// Structured focus-event logging. Every focus-relevant operation in the
/// Swift layer (incoming command from Haskell, outgoing event to Haskell,
/// macOS-originated focus signal, internal step of focusWindow) writes
/// one line to stderr through this helper. The launcher routes stderr to
/// ~/Library/Logs/mcmonad-core.log.
///
/// Format:
///   FOCUS seq=<n> src=<source> wid=<id|-> pid=<pid|-> axTrusted=<YES|NO> [tHash=<...>] [result=<...>] [extra...]
///
/// Use `grep '^FOCUS '` on the log to extract just the focus timeline; the
/// monotonic seq lets you order events globally even when they originate
/// on different threads. `tHash` (when present) is the salted, truncated
/// SHA-256 from `TitleHash` — never a raw title.
enum FocusLog {
    enum Source: String {
        // macOS-originated focus signals (we receive these)
        case nsWorkspaceActivation     // NSWorkspace.didActivateApplicationNotification
        case skylightFrontmost         // SkyLight 1508 frontmostApplicationChanged

        // Haskell-originated focus commands (we receive these from IPC)
        case cmdFocusWindow            // CommandExecutor.executeFocusWindow entry

        // Internal steps of WindowFocus.focusWindow (we initiate these)
        case cmdFocusActivate          // NSRunningApplication.activate()
        case cmdFocusSLPS              // _SLPSSetFrontProcessWithOptions
        case cmdFocusKey               // makeKeyWindow synthetic event
        case cmdFocusRaise             // AX kAXRaiseAction

        // Outgoing events from Swift to Haskell
        case emitFrontAppChanged       // socketServer.send(.frontAppChanged(...))
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _seq: UInt64 = 0

    private static func nextSeq() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        _seq &+= 1
        return _seq
    }

    /// Emit one structured focus log line. All fields except `source` are
    /// optional; pass nil for any that don't apply at this call site.
    static func emit(
        source: Source,
        windowId: UInt32? = nil,
        pid: pid_t? = nil,
        tHash: String? = nil,
        result: String? = nil,
        extra: String? = nil
    ) {
        let seq = nextSeq()
        let trusted = AXIsProcessTrusted()
        var line = "FOCUS seq=\(seq) src=\(source.rawValue)"
        line += " wid=" + (windowId.map { String($0) } ?? "-")
        line += " pid=" + (pid.map { String($0) } ?? "-")
        line += " axTrusted=\(trusted ? "YES" : "NO")"
        if let tHash = tHash { line += " tHash=\(tHash)" }
        if let result = result { line += " result=\(result)" }
        if let extra = extra { line += " " + extra }
        fputs(line + "\n", stderr)
    }
}
