import AppKit
import ApplicationServices
import AVFoundation
import Security
import Speech

/// The daemon's own view of its grants and identity, for the menubar's
/// "Permissions" section and the log. Every line is a read; nothing here
/// prompts, so opening the menu can never itself cause a permission dialog.
///
/// The one fact macOS never shows is the one that explains most phantom
/// prompts: a deploy replaces MCMonadCore.app on disk while the old daemon
/// is still running, and TCC stops recognising that process until the
/// launcher restarts it. `executableReplaced` says so directly.
@MainActor
enum PermissionAudit {
    struct Line: Sendable {
        let label: String
        let value: String
        /// nil for facts that are neither good nor bad.
        let ok: Bool?
    }

    /// The executable as it was on disk when this process started.
    struct ExecutableStamp: Equatable, Sendable {
        let path: String
        let inode: UInt64
        let size: UInt64
        let modified: Date
    }

    private static var launchStamp: ExecutableStamp?
    private static let launchedAt = Date()

    /// Call once, early, so a later `executableReplaced` has something to
    /// compare against.
    static func rememberLaunch() {
        launchStamp = currentStamp()
    }

    /// True when the executable on disk is no longer the one this process
    /// was launched from: a deploy has replaced the bundle and this daemon
    /// is a leftover that the launcher will restart shortly.
    static var executableReplaced: Bool {
        guard let launched = launchStamp, let now = currentStamp() else { return false }
        return launched != now
    }

    static func currentStamp() -> ExecutableStamp? {
        guard let path = Bundle.main.executablePath,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        else { return nil }
        return ExecutableStamp(
            path: path,
            inode: (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            size: (attrs[.size] as? NSNumber)?.uint64Value ?? 0,
            modified: (attrs[.modificationDate] as? Date) ?? .distantPast
        )
    }

    static var anyMissing: Bool {
        take().contains { $0.ok == false }
    }

    static func take() -> [Line] {
        let ax = AXIsProcessTrusted()
        let screen = CGPreflightScreenCaptureAccess()
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let speech = SFSpeechRecognizer.authorizationStatus()
        let (identifier, team) = signingIdentity()
        let replaced = executableReplaced
        let time = DateFormatter()
        time.dateFormat = "HH:mm:ss"
        return [
            Line(label: "Accessibility", value: ax ? "granted" : "NOT granted", ok: ax),
            Line(label: "Screen Recording", value: screen ? "granted" : "NOT granted", ok: screen),
            Line(label: "Microphone", value: describe(mic), ok: mic == .authorized),
            Line(label: "Speech Recognition", value: describe(speech), ok: speech == .authorized),
            Line(label: "Signed as", value: "\(identifier) · team \(team)", ok: nil),
            Line(label: "Bundle", value: Bundle.main.bundlePath, ok: nil),
            Line(label: "Executable on disk",
                 value: replaced ? "REPLACED since launch — a deploy; this daemon restarts shortly"
                                 : "unchanged since launch",
                 ok: !replaced),
            Line(label: "Process", value: "pid \(getpid()), launched \(time.string(from: launchedAt))", ok: nil),
        ]
    }

    static func report() -> String {
        take().map { "\($0.label): \($0.value)" }.joined(separator: "\n")
    }

    private static func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "DENIED"
        case .restricted: return "restricted"
        case .notDetermined: return "not determined (never asked)"
        @unknown default: return "unknown"
        }
    }

    private static func describe(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "DENIED"
        case .restricted: return "restricted"
        case .notDetermined: return "not determined (never asked)"
        @unknown default: return "unknown"
        }
    }

    /// The identifier and team the running code is signed with — what TCC
    /// keys every grant to.
    private static func signingIdentity() -> (String, String) {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return ("?", "?") }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else { return ("?", "?") }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any]
        else { return ("?", "?") }
        let identifier = dict[kSecCodeInfoIdentifier as String] as? String ?? "unsigned"
        let team = dict[kSecCodeInfoTeamIdentifier as String] as? String ?? "none (ad hoc)"
        return (identifier, team)
    }
}
