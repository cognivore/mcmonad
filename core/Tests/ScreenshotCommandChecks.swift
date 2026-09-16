// Compiled with ScreenshotCommand.swift and run by the Nix package checkPhase.
import CoreGraphics

@main
enum ScreenshotCommandChecks {
    static func main() {
        for query in ["screenshot", "scr", "scree", "  SCREENSHOT  "] {
            precondition(ScreenshotCommand(query) == .interactive, "Query: \(query)")
        }
        for query in ["3 scr", "3 screenshot", "  3\tScRe  "] {
            precondition(ScreenshotCommand(query) == .delayed(seconds: 3), "Query: \(query)")
        }
        precondition(ScreenshotCommand("0 scr") == .delayed(seconds: 0))
        precondition(ScreenshotCommand("60 screenshot") == .delayed(seconds: 60))
        for query in [
            "", "3", "s", "sc", "scroll", "screenshots", "3 chrome", "timer 3 scr",
            "scr 3", "-3 scr", "+3 scr", "3.5 scr", "NaN scr", "3s scr",
            "2147483648 scr", "9999999999999999999999 scr", "3 scr extra", "3;id scr",
        ] {
            precondition(ScreenshotCommand(query) == nil, "Query: \(query)")
        }
        // A timed capture cannot start before the user has selected a region.
        let timed = ScreenshotCommand("3 scr")!
        precondition(timed.arguments() == nil)
        precondition(timed.arguments(region: .zero) == nil)
        let rect = CGRect(x: -100, y: 200, width: 300, height: 400)
        precondition(timed.arguments(region: rect) == ["-p", "-u", "-T", "3", "-R", "-100,200,300,400"])
        precondition(ScreenshotCommand("screenshot")?.arguments() == ["-p", "-i", "-U"])
        // Secondary screens may have negative coordinates or sit above the primary.
        precondition(ScreenshotCommand.captureRegion(rect, desktopTop: 900)
                     == CGRect(x: -100, y: 300, width: 300, height: 400))
        precondition(ScreenshotCommand.captureRegion(CGRect(x: 100, y: 1000, width: 20, height: 30),
                                                     desktopTop: 900)
                     == CGRect(x: 100, y: -130, width: 20, height: 30))
        print("Screenshot aliases and chords passed")
    }
}
