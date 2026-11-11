import AppKit
import SwiftUI
import Combine

/// Panel flotante que no roba el foco y aparece en cualquier Space / pantalla completa.
final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class ShelfController {
    let model = ShelfModel()
    private var panel: ShelfPanel?
    private var idleTimer: Timer?
    private var cancellable: AnyCancellable?

    init() {
        // Si la estantería queda vacía, a los 10 s se recoge sola.
        NotificationCenter.default.addObserver(forName: Prefs.changed, object: nil, queue: .main) { [weak self] _ in
            self?.updateIdleTimer()
        }
        cancellable = model.$items.combineLatest(model.$showHistory)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.updateIdleTimer()
        }
    }

    private func updateIdleTimer() {
        idleTimer?.invalidate(); idleTimer = nil
        let seconds = Prefs.autoHide
        guard seconds > 0, isVisible, model.items.isEmpty, !model.showHistory else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self, self.model.items.isEmpty, !self.model.showHistory else { return }
            self.hide()
        }
    }

    private func makePanel() -> ShelfPanel {
        let p = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: ShelfMetrics.width, height: ShelfMetrics.height),
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let hosting = NSHostingView(rootView: ShelfView(model: model) { [weak self] in self?.hide() })
        hosting.frame = NSRect(x: 0, y: 0, width: ShelfMetrics.width, height: ShelfMetrics.height)
        p.contentView = DropContainerView(model: model, content: hosting)
        return p
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func showHistory() {
        model.showHistory = true
        show(nearMouse: false)
    }

    func toggle() { isVisible ? hide() : show(nearMouse: false) }

    func show(nearMouse: Bool) {
        let p = panel ?? makePanel()
        panel = p
        if nearMouse || Prefs.placement == .cursor || !p.isVisible { position(p, nearMouse: nearMouse) }
        p.orderFrontRegardless()
        updateIdleTimer()
    }

    func hide() {
        model.showHistory = false
        panel?.orderOut(nil)
        idleTimer?.invalidate(); idleTimer = nil
    }

    private func position(_ p: NSPanel, nearMouse: Bool) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        let size = p.frame.size
        var origin: NSPoint
        let v0 = screen.visibleFrame
        var mode = Prefs.placement
        if mode == .auto { mode = nearMouse ? .cursor : .right }
        switch mode {
        case .cursor, .auto:
            origin = NSPoint(x: mouse.x + 24, y: mouse.y - size.height / 2)
        case .left:
            origin = NSPoint(x: v0.minX + 20, y: v0.midY - size.height / 2)
        case .center:
            origin = NSPoint(x: v0.midX - size.width / 2, y: v0.midY - size.height / 2)
        case .right:
            origin = NSPoint(x: v0.maxX - size.width - 20, y: v0.midY - size.height / 2)
        }
        let v = screen.visibleFrame
        origin.x = min(max(origin.x, v.minX + 8), v.maxX - size.width - 8)
        origin.y = min(max(origin.y, v.minY + 8), v.maxY - size.height - 8)
        p.setFrameOrigin(origin)
    }
}
