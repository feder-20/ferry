import AppKit

/// Detecta "arrastrar algo + sacudir el mouse" en cualquier app.
/// Los monitores globales de mouse no necesitan permisos especiales.
final class DragShakeMonitor {
    var onShake: (() -> Void)?

    private var monitors: [Any] = []
    private var dragChangeCount = 0
    private var samples: [(t: TimeInterval, x: CGFloat)] = []
    private var fired = false

    func start() {
        let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.dragChangeCount = NSPasteboard(name: .drag).changeCount
            self?.samples.removeAll()
            self?.fired = false
        }
        let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            self?.samples.removeAll()
            self?.fired = false
        }
        let drag = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] e in
            self?.handleDrag()
        }
        monitors = [down, up, drag].compactMap { $0 }
    }

    private func handleDrag() {
        guard !fired else { return }
        // Solo si hay un arrastre real (el pasteboard de arrastre cambió).
        guard NSPasteboard(name: .drag).changeCount != dragChangeCount else { return }

        let now = ProcessInfo.processInfo.systemUptime
        samples.append((now, NSEvent.mouseLocation.x))
        samples.removeAll { now - $0.t > 0.7 }

        let params = Prefs.shakeParams
        // Contar cambios de dirección con recorrido mínimo.
        var reversals = 0
        var lastDir: CGFloat = 0
        var anchor = samples.first?.x ?? 0
        for s in samples.dropFirst() {
            let delta = s.x - anchor
            if abs(delta) > params.travel {
                let dir: CGFloat = delta > 0 ? 1 : -1
                if lastDir != 0 && dir != lastDir { reversals += 1 }
                lastDir = dir
                anchor = s.x
            }
        }
        if reversals >= params.reversals {
            fired = true
            samples.removeAll()
            DispatchQueue.main.async { [weak self] in self?.onShake?() }
        }
    }

    deinit { monitors.forEach { NSEvent.removeMonitor($0) } }
}
