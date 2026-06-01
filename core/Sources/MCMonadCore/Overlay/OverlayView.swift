import AppKit
import CoreText

/// One render record per window: the snapshot entry plus the
/// SkyLight-observed actual frame at apply-time. Cached so the
/// AppKit draw cycle (which can fire at arbitrary times) does not
/// re-query macOS for every redraw.
struct OverlayRenderEntry: Sendable {
    let entry: OverlayWindowEntry
    let actualFrame: CGRect?
}

/// One full-screen overlay view, drawn per visible workspace. Flipped
/// so coordinates match the wire format (top-left origin).
@MainActor
final class OverlayView: NSView {
    /// The wire-format frame of the workspace this overlay covers, in
    /// global top-left coords. Used to translate per-window snapshot
    /// frames into view-local coords.
    var workspaceFrame: CGRect = .zero
    var workspaceTag: String = ""
    var renderEntries: [OverlayRenderEntry] = []

    override var isFlipped: Bool { true }

    /// AppKit/CoreAnimation tries to keep our view "valid" while the
    /// window is hidden; this can cause the menu bar to draw under a
    /// transparent layer. Returning true tells AppKit to skip
    /// composition tricks and treat us as a pure overlay.
    override var wantsDefaultClipping: Bool { false }

    func apply(workspaceFrame: CGRect, workspaceTag: String, entries: [OverlayRenderEntry]) {
        self.workspaceFrame = workspaceFrame
        self.workspaceTag = workspaceTag
        self.renderEntries = entries
        self.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Workspace pill in top-left of the screen
        drawWorkspacePill(ctx: ctx)

        for re in renderEntries {
            drawWindow(re, ctx: ctx)
        }
    }

    // MARK: - Workspace pill

    private func drawWorkspacePill(ctx: CGContext) {
        let label = "mcmonad · ws \"\(workspaceTag)\""
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: label, attributes: attrs)
        let textSize = str.boundingRect(
            with: NSSize(width: 9999, height: 9999),
            options: [.usesLineFragmentOrigin]
        ).size
        let pad: CGFloat = 6
        let pill = NSRect(
            x: 12, y: 12,
            width: textSize.width + pad*2, height: textSize.height + pad*2
        )
        let path = NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4)
        NSColor.black.withAlphaComponent(0.75).setFill()
        path.fill()
        NSColor.systemPurple.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 1
        path.stroke()
        let textRect = NSRect(
            x: pill.origin.x + pad, y: pill.origin.y + pad,
            width: textSize.width, height: textSize.height
        )
        str.draw(in: textRect)
        _ = ctx  // ctx kept for symmetry with drawWindow; AppKit current context is used here
    }

    // MARK: - Per-window border + label

    private func drawWindow(_ re: OverlayRenderEntry, ctx: CGContext) {
        let entry = re.entry
        let intended = entry.frame
        let actual   = re.actualFrame ?? intended

        // Border around ACTUAL (where the window really is right now).
        // The "delta" between intended and actual is what we color-code.
        let local = CGRect(
            x: actual.origin.x - workspaceFrame.origin.x,
            y: actual.origin.y - workspaceFrame.origin.y,
            width: actual.width, height: actual.height
        )

        let dx = actual.origin.x - intended.origin.x
        let dy = actual.origin.y - intended.origin.y
        let dw = actual.width    - intended.width
        let dh = actual.height   - intended.height
        let obeyed = abs(dx) < 1.5 && abs(dy) < 1.5 && abs(dw) < 1.5 && abs(dh) < 1.5

        let borderColor: NSColor
        if !obeyed {
            borderColor = NSColor.systemRed.withAlphaComponent(0.9)
        } else if entry.isFloating {
            borderColor = NSColor.systemCyan.withAlphaComponent(0.9)
        } else {
            borderColor = NSColor.systemGreen.withAlphaComponent(0.85)
        }
        let strokeWidth: CGFloat = entry.isFocused ? 4 : 2

        ctx.saveGState()
        ctx.setStrokeColor(borderColor.cgColor)
        ctx.setLineWidth(strokeWidth)
        let inset = strokeWidth / 2
        ctx.stroke(local.insetBy(dx: inset, dy: inset))
        ctx.restoreGState()

        // Label
        var lines: [String] = []
        let wsTag = entry.workspaceTag.map { "ws=\"\($0)\" " } ?? ""
        lines.append("\(wsTag)wid=\(entry.windowId) pid=\(entry.pid)")
        let app   = entry.appName ?? "?"
        let title = entry.title.map { String($0.prefix(72)) } ?? ""
        lines.append(title.isEmpty ? app : "\(app) — \(title)")
        if entry.isFloating {
            lines.append("FLOATING")
        }
        if !obeyed {
            lines.append(String(
                format: "want=(%@,%@,%@,%@)",
                fmt(intended.origin.x), fmt(intended.origin.y),
                fmt(intended.width), fmt(intended.height)
            ))
            lines.append(String(
                format: "got=(%@,%@,%@,%@) DEFIED Δ=(%@,%@,%@,%@)",
                fmt(actual.origin.x), fmt(actual.origin.y),
                fmt(actual.width), fmt(actual.height),
                fmt(dx), fmt(dy), fmt(dw), fmt(dh)
            ))
        }

        drawLabel(
            lines,
            at: CGPoint(x: local.origin.x + strokeWidth, y: local.origin.y + strokeWidth),
            isFocused: entry.isFocused,
            isDefied: !obeyed
        )
    }

    private func drawLabel(_ lines: [String], at origin: CGPoint, isFocused: Bool, isDefied: Bool) {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let color = NSColor.white
        let bg: NSColor
        if isDefied {
            bg = NSColor.systemRed.withAlphaComponent(0.85)
        } else if isFocused {
            bg = NSColor.systemBlue.withAlphaComponent(0.8)
        } else {
            bg = NSColor.black.withAlphaComponent(0.75)
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let text = lines.joined(separator: "\n")
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.boundingRect(
            with: NSSize(width: 9999, height: 9999),
            options: [.usesLineFragmentOrigin]
        ).size

        let pad: CGFloat = 4
        let bgRect = NSRect(
            x: origin.x + 2, y: origin.y + 2,
            width: size.width + pad*2, height: size.height + pad*2
        )
        // Clamp to view bounds so labels for off-screen windows don't draw outside
        let clamped = bgRect.intersection(self.bounds)
        guard !clamped.isNull else { return }

        let path = NSBezierPath(roundedRect: bgRect, xRadius: 3, yRadius: 3)
        bg.setFill()
        path.fill()

        let textRect = NSRect(
            x: bgRect.origin.x + pad, y: bgRect.origin.y + pad,
            width: size.width, height: size.height
        )
        str.draw(in: textRect)
    }

    private func fmt(_ d: CGFloat) -> String {
        let s = String(format: "%.1f", Double(d))
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }
}
