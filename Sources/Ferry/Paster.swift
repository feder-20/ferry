import AppKit
import ApplicationServices

/// "Pegar" de verdad: suelta lo de la estantería en la app o carpeta que tengas al frente.
/// - Finder: copia los archivos a la carpeta de la ventana activa (o al Escritorio).
/// - Otras apps: los pone en el portapapeles y pulsa ⌘V por ti (requiere permiso de Accesibilidad).
final class Paster {
    private let model: ShelfModel
    init(model: ShelfModel) { self.model = model }

    func pasteAll() {
        let chosen = model.selected.isEmpty ? model.items : model.items.filter { model.selected.contains($0.id) }
        guard !chosen.isEmpty else { NSSound.beep(); return }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" {
            intoFinder(chosen)
        } else {
            viaKeyboard(chosen)
        }
    }

    // MARK: Finder

    private func intoFinder(_ chosen: [ShelfItem]) {
        guard let folder = finderFolder() else { return }
        copy(chosen, into: folder)
    }

    /// "Traer de Ferry" (Acción rápida del Finder): trae la estantería a la carpeta indicada.
    /// Elementos que se traerían ahora mismo (selección, o toda la estantería).
    var bringCandidates: [ShelfItem] {
        model.selected.isEmpty ? model.items : model.items.filter { model.selected.contains($0.id) }
    }

    /// Siempre SOLO COPIA: la orden llega de una URL (`ferry://`) y nunca debe mover originales.
    /// La carpeta debe venir ya validada (`PathSafety.validateBringPath`) y confirmada por el usuario.
    func bring(into folder: URL) {
        let chosen = bringCandidates
        guard !chosen.isEmpty else {
            model.alert(L("La estantería está vacía"), L("No hay nada que traer a %@.", folder.lastPathComponent))
            return
        }
        copy(chosen, into: folder, origin: .url)
    }

    private func copy(_ chosen: [ShelfItem], into folder: URL, origin: DeliveryOrigin = .user) {
        DispatchQueue.global(qos: .userInitiated).async { [model] in
            let fm = FileManager.default
            var done: [ShelfItem] = []
            var destinations: [UUID: URL] = [:]
            var failures: [String] = []
            for item in chosen {
                do {
                    switch item.content {
                    case .file(let u):
                        let dest = ShelfModel.uniqueURL(in: folder, name: u.lastPathComponent)
                        try fm.copyItem(at: u, to: dest)
                        destinations[item.id] = dest
                    case .text(let t):
                        let dest = ShelfModel.uniqueURL(in: folder, name: "Texto.txt")
                        try t.write(to: dest, atomically: true, encoding: .utf8)
                    case .webURL(let u):
                        let dest = ShelfModel.uniqueURL(in: folder, name: "Enlace.webloc")
                        let data = try PropertyListSerialization.data(
                            fromPropertyList: ["URL": u.absoluteString], format: .xml, options: 0)
                        try data.write(to: dest)
                    }
                    done.append(item)
                } catch {
                    failures.append("\(item.title): \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                // La copia ya está hecha: el corte del original es inmediato.
                model.finishCut(done, destinations: destinations, immediate: true, origin: origin)
                if !failures.isEmpty {
                    model.alert(L("No se pudo pegar todo"), failures.joined(separator: "\n"))
                }
            }
        }
    }

    /// Carpeta de la ventana frontal del Finder (o el Escritorio si no hay ventanas).
    private func finderFolder() -> URL? {
        let source = """
        tell application "Finder"
            if (count of Finder windows) is 0 then return POSIX path of (desktop as alias)
            try
                return POSIX path of (target of front Finder window as alias)
            on error
                return ""
            end try
        end tell
        """
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            model.alert(L("No se pudo hablar con el Finder"),
                        code == -1743
                        ? L("Permite que Ferry controle el Finder en Ajustes → Privacidad y seguridad → Automatización.")
                        : "\(error[NSAppleScript.errorMessage] as? String ?? "Error \(code)")")
            return nil
        }
        guard let path = result?.stringValue, !path.isEmpty else {
            model.alert(L("Abre una carpeta"), L("La ventana activa del Finder no es una carpeta (por ejemplo, Recientes). Abre la carpeta de destino y vuelve a intentarlo."))
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    // MARK: Otras apps (⌘V)

    private func viaKeyboard(_ chosen: [ShelfItem]) {
        let pb = NSPasteboard.general
        // Respaldo sin elementos «concealed» (contraseñas de gestores).
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pb.pasteboardItems ?? [])
            .filter { PasteboardPolicy.isRestorable(types: $0.types.map(\.rawValue)) }
            .map { item in item.types.compactMap { t in item.data(forType: t).map { (t, $0) } } }

        let files: [NSURL] = chosen.compactMap { if case .file(let u) = $0.content { return u as NSURL } else { return nil } }
        pb.clearContents()
        if !files.isEmpty {
            pb.writeObjects(files)
        } else {
            let text = chosen.map { item -> String in
                switch item.content {
                case .text(let t): return t
                case .webURL(let u): return u.absoluteString
                case .file(let u): return u.path
                }
            }.joined(separator: "\n")
            pb.setString(text, forType: .string)
        }
        // Marca transitoria: los gestores de portapapeles no deben guardarlo en su historial.
        let transient = NSPasteboard.PasteboardType(PasteboardPolicy.transientType)
        pb.addTypes([transient], owner: nil)
        pb.setData(Data(), forType: transient)
        let ourChange = pb.changeCount

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            model.alert(L("Ferry necesita permiso de Accesibilidad"),
                        L("Actívalo en Ajustes → Privacidad y seguridad → Accesibilidad para que Ferry pueda pulsar ⌘V por ti.\n\nMientras tanto, los elementos ya están en el portapapeles: pulsa ⌘V tú mismo."))
            return
        }

        waitForModifiersRelease { [weak self] in
            Self.postCommandV()
            self?.model.finishCut(chosen)
            // Devolver el portapapeles anterior cuando la app ya pegó.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                // Si el usuario (u otra app) copió algo mientras tanto, no se pisa.
                guard PasteboardPolicy.shouldRestore(currentChangeCount: pb.changeCount,
                                                     ourChangeCount: ourChange) else { return }
                pb.clearContents()
                let restored = saved.map { arr -> NSPasteboardItem in
                    let i = NSPasteboardItem()
                    arr.forEach { i.setData($0.1, forType: $0.0) }
                    return i
                }
                if !restored.isEmpty { pb.writeObjects(restored) }
            }
        }
    }

    /// El atajo (⌃⌥⌘V) aún está pulsado: se espera a soltarlo para que ⌘V llegue limpio.
    private func waitForModifiersRelease(then action: @escaping () -> Void) {
        let started = Date()
        func check() {
            let held = NSEvent.modifierFlags.intersection([.control, .option, .command, .shift])
            if held.isEmpty || Date().timeIntervalSince(started) > 1.5 { action() }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: check) }
        }
        check()
    }

    private static func postCommandV() {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
