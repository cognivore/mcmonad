import AppKit

/// Select a rectangle without taking an image, so the countdown can start
/// after selection. Actual capture and timing are left to screencapture.
@MainActor
final class ScreenshotRegionPicker {
    private var panel: KeyablePanel?
    private var monitor: Any?
    private var start: NSPoint?
    private let shade = CAShapeLayer()
    private var completion: ((CGRect) -> Void)?
    private var restoreTarget: (windowId: UInt32, pid: pid_t)?
    private var desktopTop: CGFloat = 0

    func select(restoring target: (windowId: UInt32, pid: pid_t)?,
                completion: @escaping (CGRect) -> Void) {
        dismiss()
        let screens = NSScreen.screens
        guard let primary = screens.first else { return }
        desktopTop = primary.frame.maxY
        let desktop = screens.reduce(CGRect.null) { $0.union($1.frame) }
        restoreTarget = target
        self.completion = completion

        let panel = KeyablePanel(contentRect: desktop,
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NSView(frame: CGRect(origin: .zero, size: desktop.size))
        view.wantsLayer = true
        shade.fillColor = NSColor.black.withAlphaComponent(0.25).cgColor
        shade.fillRule = .evenOdd
        shade.strokeColor = NSColor.white.cgColor
        shade.lineWidth = 1
        view.layer?.addSublayer(shade)
        panel.contentView = view
        self.panel = panel
        updateSelection(.zero)

        let screen = screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? primary
        let hint = NSTextField(labelWithString: "Drag a region · release to start timer · Esc cancel")
        hint.font = .systemFont(ofSize: 16, weight: .medium)
        hint.textColor = .white
        hint.sizeToFit()
        hint.setFrameOrigin(NSPoint(x: screen.frame.midX - desktop.minX - hint.frame.width / 2,
                                    y: screen.visibleFrame.maxY - desktop.minY - 48))
        view.addSubview(hint)

        let windowNumber = panel.windowNumber
        // Keep the ObjC event callback nonisolated, just like the launcher;
        // hop to the main actor before touching the picker state.
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]
        ) { @Sendable [weak self] event in
            guard event.windowNumber == windowNumber else { return event }
            let type = event.type
            let point = event.locationInWindow
            let escape = type == .keyDown && event.keyCode == 53
            if type == .keyDown && !escape { return event }
            DispatchQueue.main.async { [weak self] in
                self?.handle(type, point: point, escape: escape)
            }
            return nil
        }
        NSCursor.crosshair.push()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func handle(_ type: NSEvent.EventType, point: NSPoint, escape: Bool) {
        if escape { dismiss(); return }
        guard let panel else { return }
        if type == .leftMouseDown { start = point }
        guard let start else { return }
        let rect = CGRect(x: start.x, y: start.y,
                          width: point.x - start.x, height: point.y - start.y)
            .standardized.intersection(panel.contentView!.bounds)
        updateSelection(rect)
        if type == .leftMouseUp, !rect.isEmpty {
            let global = rect.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
            let region = ScreenshotCommand.captureRegion(global, desktopTop: desktopTop)
            let selected = completion
            dismiss()
            selected?(region)
        }
    }

    private func updateSelection(_ rect: CGRect) {
        guard let bounds = panel?.contentView?.bounds else { return }
        let path = CGMutablePath()
        path.addRect(bounds)
        if !rect.isEmpty { path.addRect(rect) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shade.path = path
        CATransaction.commit()
    }

    private func dismiss() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if panel != nil { NSCursor.pop() }
        panel?.orderOut(nil)
        panel = nil
        shade.removeFromSuperlayer()
        start = nil
        completion = nil
        if let target = restoreTarget {
            WindowFocus.focus(windowId: target.windowId, pid: target.pid)
        }
        restoreTarget = nil
    }
}
