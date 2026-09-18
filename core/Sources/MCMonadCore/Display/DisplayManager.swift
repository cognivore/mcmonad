import AppKit
import os

private let logger = Logger(subsystem: "com.mcmonad.core", category: "DisplayManager")

@MainActor
final class DisplayManager {
    var onScreensChanged: (@MainActor ([ScreenInfo]) -> Void)?

    private var observer: NSObjectProtocol?
    private let roles = ScreenRoles()

    init() {}

    /// The attached displays with their identity, in `NSScreen.screens`
    /// order (the main display first). Frames are the usable area in
    /// screen coordinates (origin top-left), the space the brain works in.
    func attachedDisplays() -> [AttachedDisplay] {
        let screens = NSScreen.screens
        let primaryHeight = screens.first?.frame.height ?? 0
        return screens.enumerated().map { index, screen in
            let visible = screen.visibleFrame
            // Flip Y: AppKit has origin at bottom-left, we need top-left
            let flippedY = primaryHeight - visible.origin.y - visible.height
            let frame = CGRect(x: visible.origin.x, y: flippedY, width: visible.width, height: visible.height)
            return AttachedDisplay(uuid: Self.uuid(of: screen), name: screen.localizedName,
                                   frame: frame, isMain: index == 0)
        }
    }

    /// Every display's role right now: the user's choices, then the guess.
    func currentRoles() -> [String: ScreenRole] {
        ScreenRoleMap.assign(explicit: roles.explicit, displays: attachedDisplays())
    }

    func currentScreens() -> [ScreenInfo] {
        let displays = attachedDisplays()
        let assigned = currentRoles()
        return displays.enumerated().map { index, d in
            // A display beyond the six roles is reported as primary's
            // overflow; the brain never pins anything there.
            ScreenInfo(screenId: index, frame: d.frame, uuid: d.uuid, name: d.name,
                       role: assigned[d.uuid] ?? .auxTertiary)
        }
    }

    /// The user assigned a role in the launcher: remember it and tell the
    /// brain the screens as they now stand.
    func assign(_ role: ScreenRole, to uuid: String) {
        roles.set(role, for: uuid)
        let screens = currentScreens()
        logger.info("Screen role set: \(uuid, privacy: .public) → \(role.rawValue, privacy: .public)")
        onScreensChanged?(screens)
    }

    /// The display's UUID: stable across reboots and re-plugging for a
    /// given panel, unlike the display ID or the screen index.
    private static func uuid(of screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let cfUUID = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
        else { return "screen-\(screen.localizedName)" }
        return CFUUIDCreateString(nil, cfUUID) as String
    }

    /// The screen a window currently occupies, for parking it off-screen.
    /// Prefers the screen with the largest overlap; if the window overlaps no
    /// screen (e.g. it was already parked far off-screen by an earlier hide),
    /// picks the one whose centre is nearest. All frames are in screen coords
    /// (origin top-left), matching `currentScreens()`.
    func screen(forFrame frame: CGRect) -> ScreenInfo? {
        let screens = currentScreens()
        guard !screens.isEmpty else { return nil }
        if let best = screens.max(by: { overlapArea($0.frame, frame) < overlapArea($1.frame, frame) }),
           overlapArea(best.frame, frame) > 0 {
            return best
        }
        return screens.min(by: {
            centreDistanceSquared($0.frame, frame) < centreDistanceSquared($1.frame, frame)
        })
    }

    func startObserving() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let screens = self.currentScreens()
                logger.info("Screen parameters changed: \(screens.count) screen(s)")
                self.onScreensChanged?(screens)
            }
        }
        logger.info("Display observer started")
    }

    func stopObserving() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }
}

private func overlapArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let i = a.intersection(b)
    return i.isNull ? 0 : i.width * i.height
}

private func centreDistanceSquared(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let dx = a.midX - b.midX
    let dy = a.midY - b.midY
    return dx * dx + dy * dy
}
