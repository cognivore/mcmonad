import AppKit

/// geoSurge's loading spinner, drawn natively: lucide's `Loader2` — a
/// 288° arc with round caps on a 24-unit grid — turning once a second. It is
/// meant to sit *behind* text, so the default colour is a muted orange.
final class SpinnerView: NSView {
    private let color = NSColor.systemOrange.withAlphaComponent(0.14)

    private var phase: CGFloat = 0
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        isHidden = false
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.phase -= (2 * .pi) / 30    // one full turn per second, clockwise
                self.needsDisplay = true
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isHidden = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let side = min(bounds.width, bounds.height)
        guard side > 0 else { return }
        let unit = side / 24
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let path = NSBezierPath()
        path.lineWidth = 2 * unit
        path.lineCapStyle = .round
        // lucide: M21 12 a9 9 0 1 1 -6.219 -8.56 — from 3 o'clock, 288° clockwise.
        let start = phase * 180 / .pi
        path.appendArc(withCenter: center, radius: 9 * unit,
                       startAngle: start, endAngle: start - 288, clockwise: true)
        color.setStroke()
        path.stroke()
    }
}
