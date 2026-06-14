import AppKit
import os

private let logger = Logger(subsystem: "com.mcmonad.core", category: "DisplayManager")

@MainActor
final class DisplayManager {
    var onScreensChanged: (@MainActor ([ScreenInfo]) -> Void)?

    private var observer: NSObjectProtocol?

    init() {}

    func currentScreens() -> [ScreenInfo] {
        let screens = NSScreen.screens
        // Use visibleFrame to exclude menu bar and dock
        // Convert from AppKit coords (origin bottom-left) to screen coords (origin top-left)
        let primaryHeight = screens.first?.frame.height ?? 0
        return screens.enumerated().map { index, screen in
            let visible = screen.visibleFrame
            // Flip Y: AppKit has origin at bottom-left, we need top-left
            let flippedY = primaryHeight - visible.origin.y - visible.height
            let frame = CGRect(
                x: visible.origin.x,
                y: flippedY,
                width: visible.width,
                height: visible.height
            )
            return ScreenInfo(screenId: index, frame: frame)
        }
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
