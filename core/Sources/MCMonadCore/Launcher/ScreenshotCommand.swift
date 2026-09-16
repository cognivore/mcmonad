import Foundation
import CoreGraphics
import os

/// Screenshot aliases and a seconds-prefix chord, backed by macOS screencapture.
enum ScreenshotCommand: Equatable {
    case interactive
    case delayed(seconds: Int32)

    init?(_ text: String) {
        let tokens = text.lowercased().split(whereSeparator: \.isWhitespace)
        guard (1...2).contains(tokens.count), let name = tokens.last,
              name.count >= 3, "screenshot".hasPrefix(name)
        else { return nil }

        if tokens.count == 1 {
            self = .interactive
        } else {
            guard tokens[0].allSatisfy({ $0.isASCII && $0.isNumber }),
                  let seconds = Int32(tokens[0]), seconds >= 0
            else { return nil }
            self = .delayed(seconds: seconds)
        }
    }

    var title: String {
        switch self {
        case .interactive:
            return "Screenshot — open capture tools"
        case .delayed(let seconds):
            let unit = seconds == 1 ? "second" : "seconds"
            return "Screenshot — select region, then capture in \(seconds) \(unit)"
        }
    }

    func arguments(region: CGRect? = nil) -> [String]? {
        switch self {
        case .interactive:
            return ["-p", "-i", "-U"]
        case .delayed(let seconds):
            guard let region, !region.isEmpty, !region.isInfinite, !region.isNull else { return nil }
            let rect = region.integral
            let bounds = [rect.minX, rect.minY, rect.width, rect.height]
                .map { String(format: "%.0f", Double($0)) }.joined(separator: ",")
            // -p supplies the configured destination; -T starts only after
            // selection has finished; -R captures the selected rectangle.
            return ["-p", "-u", "-T", String(seconds), "-R", bounds]
        }
    }

    /// Convert an AppKit desktop rectangle to screencapture's top-left coordinates.
    static func captureRegion(_ rect: CGRect, desktopTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: desktopTop - rect.maxY, width: rect.width, height: rect.height)
    }

    func run(region: CGRect? = nil) {
        guard let arguments = arguments(region: region) else { return }
        // Request under the signed daemon's identity. A grant to the Haskell
        // process (mcmonad-aarch64-darwin) does not cover this process.
        if case .delayed = self,
           !CGPreflightScreenCaptureAccess(), !CGRequestScreenCaptureAccess() {
            Logger(subsystem: "com.mcmonad.core", category: "Screenshot").error(
                "Enable Screen & System Audio Recording for MCMonadCore.app, then retry the screenshot."
            )
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments
        do {
            // The native timer runs in its own process, leaving the WM responsive.
            try process.run()
        } catch {
            Logger(subsystem: "com.mcmonad.core", category: "Screenshot").error(
                "Could not start screenshot: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
