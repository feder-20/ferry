import AppKit
import ServiceManagement
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private let shelf = ShelfController()
    private let monitor = DragShakeMonitor()
    private lazy var paster = Paster(model: shelf.model)
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        TrialManager.shared.openURL = { NSWorkspace.shared.open($0) }
        shelf.model.cleanTemp() // restos de ejecuciones anteriores (cierres bruscos)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "ferry.fill",
                                           accessibilityDescription: "Ferry")

        menu = NSMenu()
        let status = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        status.tag = 20; status.isEnabled = false
        let buy = menu.addItem(withTitle: L("Obtener premium…"), action: #selector(openPurchase), keyEquivalent: "")
        buy.target = self; buy.tag = 21
        let enterKey = menu.addItem(withTitle: L("Introducir clave…"), action: #selector(showActivation), keyEquivalent: "")
        enterKey.target = self; enterKey.tag = 22
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Acerca de Ferry"), action: #selector(showAbout), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Mostrar / ocultar estantería"), action: #selector(toggle), keyEquivalent: "")
            .target = self
        let paste = menu.addItem(withTitle: L("Pegar en la app activa"), action: #selector(pasteNow), keyEquivalent: "v")
        paste.target = self; paste.tag = 7
        updatePasteItem()
        menu.addItem(withTitle: L("Cortes recientes (devolver al origen)…"), action: #selector(showHistory), keyEquivalent: "")
            .target = self
        let qa = menu.addItem(withTitle: L("Instalar «Traer de Ferry» en el Finder"), action: #selector(toggleQuickAction), keyEquivalent: "")
        qa.target = self; qa.tag = 5
        menu.addItem(withTitle: L("Vaciar estantería"), action: #selector(clear), keyEquivalent: "")
            .target = self
        let modeItem = NSMenuItem(title: L("Al soltar el archivo"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let cut = sub.addItem(withTitle: L("Cortar (mover el original)"), action: #selector(setCut), keyEquivalent: "")
        cut.target = self; cut.tag = 1
        let copy = sub.addItem(withTitle: L("Copiar (dejar el original)"), action: #selector(setCopy), keyEquivalent: "")
        copy.target = self; copy.tag = 2
        modeItem.submenu = sub
        menu.addItem(modeItem)
        let ask = menu.addItem(withTitle: L("Preguntar al soltar imágenes (convertir)"), action: #selector(toggleAskImages), keyEquivalent: "")
        ask.target = self; ask.tag = 6
        let login = menu.addItem(withTitle: L("Abrir al iniciar sesión"), action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self; login.tag = 3
        let remember = menu.addItem(withTitle: L("Recordar archivos al cerrar"), action: #selector(toggleRemember), keyEquivalent: "")
        remember.target = self; remember.tag = 4
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Ajustes…"), action: #selector(showSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Salir"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        // Doble clic: abre/cierra la bandeja. Clic derecho: menú.
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // Al sacudir el mouse mientras arrastras algo, aparece la estantería.
        monitor.onShake = { [weak self] in self?.handleShake() }
        monitor.start()

        // Atajo global (por defecto ⌃⌥⌘V): pega la estantería en la app o carpeta activa.
        // (⌥⌘V ya lo usa el Finder para "Mover aquí", por eso se añade ⌃.)
        registerHotKey()
        // Avisos de la prueba (bienvenida una vez, recordatorio diario, vencida), con la app ya arrancada.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { TrialUI.showLaunchNotice() }
        NotificationCenter.default.addObserver(forName: Prefs.changed, object: nil, queue: .main) { [weak self] _ in
            self?.registerHotKey()
        }
    }

    private func registerHotKey() {
        hotKey = nil // libera el anterior
        hotKey = HotKey(keyCode: Prefs.hotKeyCode, modifiers: Prefs.hotKeyModifiers) { [weak self] in
            self?.paster.pasteAll()
        }
        if hotKey == nil {
            shelf.model.alert(L("Atajo no disponible"),
                              L("Ese atajo ya lo usa el sistema u otra app. Se ha restablecido el atajo por defecto."))
            
            if Prefs.hotKeyCode != Prefs.defaultKeyCode || Prefs.hotKeyModifiers != Prefs.defaultModifiers {
                Prefs.resetHotKey() // vuelve a llamar a registerHotKey
            }
            return
        }
        updatePasteItem()
    }

    private func updatePasteItem() {
        guard let item = menu?.item(withTag: 7) else { return }
        let k = Prefs.hotKeyKey
        item.keyEquivalent = k.count == 1 ? k.lowercased() : ""
        item.keyEquivalentModifierMask = Prefs.nsModifiers(Prefs.hotKeyModifiers)
    }

    @objc private func showSettings() { SettingsWindow.shared.show() }

    func applicationWillTerminate(_ notification: Notification) {
        // Los archivos reales siguen en su origen (solo se cortan al soltarlos en el destino).
        shelf.model.save()
        shelf.model.cleanTemp()
    }

    @objc private func statusClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            if let sub = menu.items.first(where: { $0.submenu != nil })?.submenu {
                sub.item(withTag: 1)?.state = ShelfModel.moveMode ? .on : .off
                sub.item(withTag: 2)?.state = ShelfModel.moveMode ? .off : .on
            }
            let qaInstalled = FileManager.default.fileExists(atPath: Self.quickActionURL.path)
            menu.item(withTag: 5)?.title = qaInstalled ? L("Quitar «Traer de Ferry» del Finder") : L("Instalar «Traer de Ferry» en el Finder")
            menu.item(withTag: 6)?.state = ImageConverter.askOnDrop ? .on : .off
            menu.item(withTag: 4)?.state = ShelfModel.rememberShelf ? .on : .off
            menu.item(withTag: 3)?.state = SMAppService.mainApp.status == .enabled ? .on : .off
            refreshTrialItems()
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else if event.clickCount >= 2 {
            toggle()
        }
    }

    /// Sacudir: con prueba vencida no abre la estantería; abre la activación como mucho cada pocos minutos.
    private func handleShake() {
        if TrialManager.shared.allowsFeatures { shelf.show(nearMouse: true) }
        else if TrialManager.shared.shouldNudgeActivation() { ActivationWindow.shared.show(expired: true) }
    }

    private func refreshTrialItems() {
        let t = TrialManager.shared
        if let info = t.license {
            menu.item(withTag: 20)?.title = L("Premium activado · %@", info.name)
            menu.item(withTag: 21)?.isHidden = true
            menu.item(withTag: 22)?.isHidden = true
        } else {
            menu.item(withTag: 20)?.title = t.statusLine ?? ""
            menu.item(withTag: 21)?.isHidden = false
            menu.item(withTag: 22)?.isHidden = false
        }
    }

    @objc private func openPurchase() { TrialManager.shared.openPurchase() }
    @objc private func showActivation() {
        ActivationWindow.shared.show(expired: TrialManager.shared.state == .expired)
    }

    @objc private func toggle() {
        guard TrialManager.shared.allowsFeatures else { showActivation(); return }
        shelf.toggle()
    }
    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            let a = NSAlert()
            a.messageText = L("No se pudo cambiar el inicio automático")
            a.informativeText = "\(error.localizedDescription)\n\n" + L("Copia la app a Aplicaciones y vuelve a intentarlo.")
            a.runModal()
        }
        if svc.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    /// Logo de Ferry: barco negro sobre fondo blanco.
    private func makeLogo(size: CGFloat = 256) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let tile = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.04, dy: size * 0.04),
                                    xRadius: size * 0.22, yRadius: size * 0.22)
            NSColor.white.setFill()
            tile.fill()
            NSColor(white: 0, alpha: 0.12).setStroke()
            tile.lineWidth = 2
            tile.stroke()
            let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.5, weight: .semibold)
            if let base = NSImage(systemSymbolName: "ferry.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg) {
                let white = NSImage(size: base.size, flipped: false) { r in
                    base.draw(in: r)
                    NSColor.black.set()
                    r.fill(using: .sourceIn)
                    return true
                }
                let r = NSRect(x: (size - white.size.width) / 2, y: (size - white.size.height) / 2,
                               width: white.size.width, height: white.size.height)
                white.draw(in: r)
            }
            return true
        }
    }

    @objc private func showAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.1"
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Ferry",
            .applicationIcon: makeLogo(),
            .applicationVersion: version,
            .version: "",
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"):
                L("© 2026 ChocolitosSoft. Todos los derechos reservados.")
        ])
    }

    // MARK: «Traer de Ferry» (Acción rápida del Finder)

    static var quickActionURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Services/Traer de Ferry.workflow", isDirectory: true)
    }

    @objc private func toggleQuickAction() {
        let fm = FileManager.default
        let dest = Self.quickActionURL
        if fm.fileExists(atPath: dest.path) {
            try? fm.removeItem(at: dest)
            shelf.model.alert(L("Acción quitada"), L("«Traer de Ferry» ya no aparece en el menú del Finder."))
            return
        }
        guard let src = Bundle.main.url(forResource: "Traer de Ferry", withExtension: "workflow") else {
            shelf.model.alert(L("No se encontró la acción"), L("Esta copia de Ferry no incluye la Acción rápida."))
            return
        }
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: src, to: dest)
            let pbs = Process()
            pbs.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/pbs")
            pbs.arguments = ["-update"]
            try? pbs.run()
            shelf.model.alert(L("Acción instalada"),
                              L("Haz clic derecho sobre una carpeta (o en el fondo de una carpeta) del Finder → Acciones rápidas → «Traer de Ferry».\n\nSi no aparece, actívala en Ajustes del Sistema → Teclado → Atajos de teclado → Servicios → Archivos y carpetas."))
        } catch {
            shelf.model.alert(L("No se pudo instalar"), error.localizedDescription)
        }
    }

    /// ferry://bring?path=/ruta/de/la/carpeta  (lo lanza la Acción rápida)
    /// Cualquier web o app puede lanzar esta URL: se valida la ruta, se pide confirmación SIEMPRE
    /// y la entrega es solo copia (nunca corta originales).
    private var bringDialogOpen = false

    func application(_ application: NSApplication, open urls: [URL]) {
        // Solo la primera orden válida; el resto se ignora (antiabuso).
        guard TrialManager.shared.allowsFeatures else { showActivation(); return }
        guard let path = urls.lazy.compactMap({ PathSafety.bringPath(from: $0) }).first else { return }
        // Un momento para que la app termine de arrancar si la acción la lanzó.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.confirmAndBring(path: path)
        }
    }

    private func confirmAndBring(path: String) {
        guard !bringDialogOpen else { return } // ya hay un diálogo abierto: se ignora
        bringDialogOpen = true
        defer { bringDialogOpen = false }
        NSApp.activate(ignoringOtherApps: true)

        let folder: URL
        switch PathSafety.validateBringPath(path) {
        case .failure(let err):
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = L("No se puede traer a esa carpeta")
            switch err {
            case .forbidden: a.informativeText = L("Ferry no entrega archivos en carpetas del sistema, de biblioteca u ocultas.")
            default: a.informativeText = L("La ruta no es una carpeta existente y con permiso de escritura.")
            }
            a.runModal()
            return
        case .success(let url): folder = url
        }

        let count = paster.bringCandidates.count
        guard count > 0 else {
            shelf.model.alert(L("La estantería está vacía"), L("No hay nada que traer a %@.", folder.lastPathComponent))
            return
        }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = L("¿Traer %lld elementos a «%@»?", Int64(count), folder.path)
        a.informativeText = L("Se copiarán los elementos a esa carpeta. Los originales no se moverán. Si no has pedido esto tú, cancela.")
        let cancel = a.addButton(withTitle: L("Cancelar")) // botón por defecto: Intro cancela
        cancel.keyEquivalent = "\r"
        a.addButton(withTitle: L("Traer")).keyEquivalent = ""
        guard a.runModal() == .alertSecondButtonReturn else { return }
        paster.bring(into: folder)
    }

    @objc private func toggleAskImages() { ImageConverter.askOnDrop.toggle() }
    @objc private func toggleRemember() {
        ShelfModel.rememberShelf.toggle()
        shelf.model.save()
    }
    @objc private func showHistory() {
        guard TrialManager.shared.allowsFeatures else { showActivation(); return }
        shelf.showHistory()
    }
    @objc private func pasteNow() {
        // Deja que el menú se cierre y que la app activa recupere el foco.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.paster.pasteAll() }
    }

    @objc private func setCut() { ShelfModel.moveMode = true }
    @objc private func setCopy() { ShelfModel.moveMode = false }
    @objc private func clear() { shelf.model.removeAll() }
}
