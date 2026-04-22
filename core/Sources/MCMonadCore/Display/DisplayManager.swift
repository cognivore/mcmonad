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
