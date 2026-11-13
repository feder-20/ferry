import SwiftUI
import AppKit

/// Interfaz del periodo de prueba y la licencia (la lógica vive en Trial.swift / License.swift).
enum TrialUI {
    static var trial: TrialManager { .shared }

    /// Aviso de arranque: bienvenida (una vez), recordatorio diario (últimos 14 días) o ventana de activación.
    static func showLaunchNotice() {
        switch trial.consumeLaunchNotice() {
        case .none: break
        case .firstRun: infoAlert(title: L("Estás usando una versión de prueba (tester)"), reminder: false)
        case .dailyReminder(let n):
            infoAlert(title: n <= 1 ? L("Hoy es el último día de prueba") : L("Quedan %lld días de prueba", Int64(n)), reminder: true)
        case .expired: ActivationWindow.shared.show(expired: true)
        }
    }

    private static func infoAlert(title: String, reminder: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = L("Ferry está en periodo de prueba: úsala gratis durante 90 días (hasta el %@) y ayúdanos a mejorarla. Después, cada app costará 10 USD (pago único). Tus archivos nunca se tocan ni se pierden.", trial.endDateText)
        a.addButton(withTitle: L("Entendido"))
        a.addButton(withTitle: L("Más información / Obtener premium"))
        if reminder { a.addButton(withTitle: L("Introducir clave…")) }
        switch a.runModal() {
        case .alertSecondButtonReturn: trial.openPurchase()
        case .alertThirdButtonReturn: ActivationWindow.shared.show(expired: false)
        default: break
        }
    }
}

/// Ventana de activación. Vencida: sin botón de cerrar y Esc no hace nada; la app no ejecuta sus funciones.
final class ActivationWindow: NSObject, NSWindowDelegate {
    static let shared = ActivationWindow()
    private var window: NSWindow?

    func show(expired wantExpired: Bool) {
        let expired = wantExpired || TrialManager.shared.state == .expired
        close()
        let w = NSWindow(contentViewController: NSHostingController(rootView: ActivationView(expired: expired) { [weak self] in
            self?.close()
        }))
        w.title = expired ? L("El periodo de prueba terminó") : L("Introducir clave")
        w.styleMask = expired ? [.titled] : [.titled, .closable]
        w.level = expired ? .floating : .normal
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func close() { window?.orderOut(nil); window = nil }
    var isVisible: Bool { window?.isVisible ?? false }
}

struct ActivationView: View {
    let expired: Bool
    var onDone: () -> Void
    @State private var key = ""
    @State private var error: String?
    @State private var activated: String?

    private var trial: TrialManager { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if expired {
                Text("El periodo de prueba terminó").font(.title2.bold())
                Text(L("Gracias por probar Ferry. Para seguir usándola, obtén la versión premium (%@, pago único).", TrialConfig.priceText))
                Text("Tus archivos de la estantería se conservan y no se tocan.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Obtener premium") { trial.openPurchase() }
                    .keyboardShortcut(.defaultAction)
                Divider()
            } else {
                Text(L("Premium: %@ por app, pago único", TrialConfig.priceText)).font(.headline)
                Button("Obtener premium") { trial.openPurchase() }
                Divider()
            }
            Text("Tengo una clave").font(.subheadline.bold())
            TextField("FERRY.…", text: $key)
                .textFieldStyle(.roundedBorder)
                .onSubmit(activate)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            if let activated { Text(activated).font(.caption).foregroundStyle(.green) }
            HStack {
                if expired { Button("Salir") { NSApp.terminate(nil) } }
                Spacer()
                if !expired { Button("Cerrar") { onDone() } }
                Button("Activar", action: activate).disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func activate() {
        error = nil
        switch trial.activate(key) {
        case .success(let info):
            activated = L("Premium activado · %@", info.name)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { onDone() }
        case .failure(.invalid): error = L("La clave no es válida. Revisa que esté completa.")
        case .failure(.wrongApp): error = L("Esa clave es de otra app, no de Ferry.")
        case .failure(.alreadyActive): error = L("Esa clave ya está activada.")
        }
        NotificationCenter.default.post(name: Prefs.changed, object: nil)
    }
}

/// Aviso discreto en la parte inferior de la estantería.
struct TrialFooter: View {
    var body: some View {
        if let line = TrialManager.shared.statusLine {
            let warn: Bool = { if case .lastDays = TrialManager.shared.state { return true }; return false }()
            HStack(spacing: 6) {
                Text(line).font(.caption2).lineLimit(1)
                    .foregroundStyle(warn ? Color.orange : Color.secondary)
                Spacer(minLength: 0)
                Button("Obtener premium") { TrialManager.shared.openPurchase() }
                    .buttonStyle(.link).font(.caption2)
            }
        }
    }
}

/// Sección «Licencia» de Ajustes.
struct LicenseSettingsSection: View {
    @State private var tick = 0
    private var trial: TrialManager { .shared }

    var body: some View {
        Section {
            let _ = tick
            if let info = trial.license {
                Text(L("Premium activado · %@", info.name))
                Button("Quitar licencia") { trial.removeLicense(); tick += 1
                    NotificationCenter.default.post(name: Prefs.changed, object: nil) }
            } else {
                Text(trial.statusLine ?? "")
                Text(L("Tu prueba de 90 días dura hasta el %@.", trial.endDateText)).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Obtener premium") { trial.openPurchase() }
                    Button("Introducir clave…") { ActivationWindow.shared.show(expired: false) }
                }
            }
        } header: { Text("Licencia") }
        .onReceive(NotificationCenter.default.publisher(for: Prefs.changed)) { _ in tick += 1 }
    }
}
