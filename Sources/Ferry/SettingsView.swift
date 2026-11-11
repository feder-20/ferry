import SwiftUI
import AppKit

/// Captura el siguiente atajo que pulse el usuario.
final class HotKeyRecorder: ObservableObject {
    @Published var recording = false
    @Published var label = Prefs.hotKeyLabel
    @Published var error: String?
    private var monitor: Any?

    func start() {
        stop()
        error = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            if e.keyCode == 53 { self.stop(); return nil } // Esc cancela
            let mods = Prefs.carbonModifiers(e.modifierFlags)
            guard e.modifierFlags.intersection([.command, .control, .option]).isEmpty == false else {
                self.error = L("Usa al menos ⌃, ⌥ o ⌘ junto con la tecla.")
                return nil
            }
            let key = Self.name(for: e)
            Prefs.setHotKey(code: Int(e.keyCode), modifiers: mods, key: key)
            self.label = Prefs.hotKeyLabel
            self.stop()
            return nil
        }
    }

    func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    func reset() { stop(); error = nil; Prefs.resetHotKey(); label = Prefs.hotKeyLabel }

    private static func name(for e: NSEvent) -> String {
        switch Int(e.keyCode) {
        case 49: return L("Espacio")
        case 36: return "↩"
        case 48: return "⇥"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            let c = (e.charactersIgnoringModifiers ?? "").uppercased()
            return c.isEmpty ? "#\(e.keyCode)" : c
        }
    }
}

struct SettingsView: View {
    @StateObject private var rec = HotKeyRecorder()
    @State private var autoHide = Prefs.autoHide
    @State private var placement = Prefs.placement
    @State private var sensitivity = Prefs.shakeSensitivity

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Pegar la estantería")
                    Spacer()
                    Button(rec.recording ? L("Pulsa el atajo…") : rec.label) {
                        rec.recording ? rec.stop() : rec.start()
                    }
                    .frame(minWidth: 120)
                    Button("Restablecer") { rec.reset() }
                }
                if let e = rec.error { Text(e).font(.caption).foregroundStyle(.red) }
            } header: { Text("Atajo de teclado") }

            Section {
                Picker("Recoger la estantería vacía", selection: $autoHide) {
                    Text("a los 5 segundos").tag(5.0)
                    Text("a los 10 segundos").tag(10.0)
                    Text("a los 30 segundos").tag(30.0)
                    Text("al minuto").tag(60.0)
                    Text("nunca").tag(0.0)
                }
                .onChange(of: autoHide) { Prefs.autoHide = $0 }

                Picker("Dónde aparece", selection: $placement) {
                    Text("Automático (junto al cursor al sacudir)").tag(Placement.auto)
                    Text("Siempre junto al cursor").tag(Placement.cursor)
                    Text("Borde derecho").tag(Placement.right)
                    Text("Borde izquierdo").tag(Placement.left)
                    Text("Centro de la pantalla").tag(Placement.center)
                }
                .onChange(of: placement) { Prefs.placement = $0 }
            } header: { Text("Estantería") }

            Section {
                Picker("Sensibilidad", selection: $sensitivity) {
                    Text("Baja").tag(0)
                    Text("Media").tag(1)
                    Text("Alta").tag(2)
                }
                .pickerStyle(.segmented)
                .onChange(of: sensitivity) { Prefs.shakeSensitivity = $0 }
                Text("Cuanto más alta, menos hace falta sacudir el ratón mientras arrastras.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Sacudir para abrir") }

            LicenseSettingsSection()
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 540)
        .onDisappear { rec.stop() }
    }
}

final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = L("Ajustes de Ferry")
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
