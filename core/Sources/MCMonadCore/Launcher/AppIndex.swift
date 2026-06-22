import AppKit
import os

/// A flat index of launchable macOS applications, used by the Spotlight
/// command runner to fuzzy-match an app name ("chrome", "librewolf") and
/// launch it.
///
/// The index is a shallow scan of the conventional application directories
/// (plus one level of nesting, to catch grouped folders like "Nix Apps" or
/// "Utilities"). It is rebuilt lazily — at most once per `ttl` — so opening
/// the launcher repeatedly does not re-walk the filesystem every time, but a
/// freshly installed app shows up within a minute.
///
/// Launching is a pure side effect (`NSWorkspace.openApplication`); the new
/// window arrives back through the normal SkyLight `window-created` path and
/// is managed like any other. Nothing about app launch touches the StackSet,
/// so — unlike window focus — it does not round-trip through Haskell.
@MainActor
final class AppIndex {
    // nonisolated so the NSWorkspace.openApplication completion (a Sendable
    // closure that runs off the main actor) can log launch failures.
    nonisolated private static let logger = Logger(
        subsystem: "com.mcmonad.core",
        category: "AppIndex"
    )

    /// One launchable application.
    struct AppEntry {
        let name: String        // display name, e.g. "Google Chrome"
        let url: URL            // bundle URL
        let bundleId: String?
        let haystack: String    // lowercased name + bundle id, for fuzzy match
    }

    private(set) var apps: [AppEntry] = []
    private var lastBuilt: Date?

    /// Directories scanned for `.app` bundles, in priority order. Earlier
    /// directories win on duplicate display names (so a user's
    /// ~/Applications copy shadows a system one).
    private static let searchDirs: [String] = [
        NSHomeDirectory() + "/Applications",
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        "/System/Library/CoreServices/Applications",
    ]

    /// Rebuild the index if it has never been built or is older than `ttl`.
    func refreshIfStale(ttl: TimeInterval = 60) {
        if let lastBuilt, Date().timeIntervalSince(lastBuilt) < ttl { return }
        rebuild()
    }

    func rebuild() {
        let fm = FileManager.default
        var result: [AppEntry] = []
        var seenNames = Set<String>()   // dedupe by lowercased display name
        var seenPaths = Set<String>()   // dedupe by resolved bundle path

        func consider(_ path: String) {
            guard path.hasSuffix(".app") else { return }
            let resolved = (path as NSString).resolvingSymlinksInPath
            guard !seenPaths.contains(resolved) else { return }
            let url = URL(fileURLWithPath: path)
            let name = fm.displayName(atPath: path)
            let key = name.lowercased()
            guard !seenNames.contains(key) else { return }
            let bundleId = Bundle(url: url)?.bundleIdentifier
            seenPaths.insert(resolved)
            seenNames.insert(key)
            let haystack = ([name, bundleId ?? ""])
                .joined(separator: " ")
                .lowercased()
            result.append(AppEntry(
                name: name, url: url, bundleId: bundleId, haystack: haystack
            ))
        }

        for dir in Self.searchDirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items {
                let full = dir + "/" + item
                if item.hasSuffix(".app") {
                    consider(full)
                } else {
                    // One level deeper: catches grouped folders (e.g.
                    // "/Applications/Nix Apps/Foo.app") without a full
                    // recursive walk of the whole tree.
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: full, isDirectory: &isDir),
                          isDir.boolValue,
                          let sub = try? fm.contentsOfDirectory(atPath: full)
                    else { continue }
                    for s in sub where s.hasSuffix(".app") {
                        consider(full + "/" + s)
                    }
                }
            }
        }

        apps = result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        lastBuilt = Date()
        Self.logger.info("AppIndex rebuilt: \(self.apps.count, privacy: .public) apps")
    }

    /// Launch an application bundle, bringing it to the foreground. The
    /// resulting window flows back through SkyLight and is managed normally.
    func launch(_ entry: AppEntry) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        // openApplication's completion fires on a background queue — capture
        // only Sendable values and mark @Sendable so the compiler doesn't
        // infer main-actor isolation (which would trap at runtime).
        let name = entry.name
        NSWorkspace.shared.openApplication(at: entry.url, configuration: cfg) { @Sendable _, err in
            if let err {
                Self.logger.error(
                    "launch failed for \(name, privacy: .public): \(err.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// Best-effort launch by free-text name (used by voice when the spoken
    /// phrase wasn't a recognised command). Returns true if something was
    /// launched.
    @discardableResult
    func launchByName(_ query: String) -> Bool {
        refreshIfStale()
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return false }
        let best = apps
            .compactMap { app -> (AppEntry, Int)? in
                FuzzyMatch.score(query: q, in: app.haystack).map { (app, $0) }
            }
            .max { $0.1 < $1.1 }?
            .0
        guard let best else { return false }
        launch(best)
        return true
    }
}
