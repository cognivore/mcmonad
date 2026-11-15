import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

// AI-generated text: model claude-opus-5-5; reasoning effort unavailable (not exposed by the harness).

/// What saving a window for later keeps of it: its picture as a PNG and the
/// text read off that picture, both at the moment it was saved. Unlike the
/// screen index, which never writes what it reads, this writes both on
/// purpose: the user asked for this window to be kept. Both stay on this
/// Mac, in the inbox and its attachments directory.
enum LaterCapture {
    struct Taken: Sendable {
        /// The PNG's absolute path, when one was written.
        let screenshot: String?
        let text: String?
        /// Why the screenshot or the text is missing, in words.
        let missing: [String]
    }

    /// Off the main actor. `scale` is the display's backing scale.
    static func take(windowId: UInt32, into directory: String, at date: Date, scale: CGFloat) async -> Taken {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            return Taken(screenshot: nil, text: nil, missing: [denied(error)])
        }
        guard let window = content.windows.first(where: { $0.windowID == windowId }),
              window.frame.width >= 8, window.frame.height >= 8 else {
            return Taken(screenshot: nil, text: nil, missing: ["No screenshot: the window had closed before it could be captured."])
        }
        let cfg = SCStreamConfiguration()
        cfg.width = Int(window.frame.width * scale)
        cfg.height = Int(window.frame.height * scale)
        cfg.showsCursor = false
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window),
                configuration: cfg
            )
        } catch {
            return Taken(screenshot: nil, text: nil, missing: [denied(error)])
        }
        // The text is read from this picture, so the two always agree.
        let text = ScreenIndex.recognise(image).joined(separator: "\n")
        var missing: [String] = []
        let path: String?
        switch write(image, into: directory, name: Later.screenshotName(at: date, windowId: windowId, timeZone: .current)) {
        case .success(let p): path = p
        case .failure(let why): path = nil; missing.append("No screenshot: \(why)")
        }
        if text.isEmpty { missing.append("No text could be read off the window.") }
        return Taken(screenshot: path, text: text.isEmpty ? nil : text, missing: missing)
    }

    private static func denied(_ error: Error) -> String {
        if let e = error as? SCStreamError, e.code == .userDeclined {
            return "No screenshot: MCMonadCore.app does not have Screen & System Audio Recording (System Settings ▸ Privacy & Security)."
        }
        return "No screenshot: capturing the window failed (\(error.localizedDescription))."
    }

    /// Write `image` as `<directory>/<name>.png` (or `<name>-2.png`, … if
    /// taken), creating the directory private to this user.
    private static func write(_ image: CGImage, into directory: String, name: String) -> Result<String, CaptureWriteError> {
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            return .failure(CaptureWriteError("could not create \(directory): \(error.localizedDescription)"))
        }
        var path = "\(directory)/\(name).png"
        var n = 2
        while FileManager.default.fileExists(atPath: path) {
            path = "\(directory)/\(name)-\(n).png"
            n += 1
        }
        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil) else {
            return .failure(CaptureWriteError("could not open \(path) for writing"))
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            return .failure(CaptureWriteError("writing \(path) failed"))
        }
        return .success(path)
    }

    struct CaptureWriteError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }
}
