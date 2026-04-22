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
        return screens.enumerated().map { index, screen in
            ScreenInfo(
                screenId: index,
                frame: screen.frame
            )
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
