import Foundation

/// Periodo de prueba (tester) de Ferry. Lógica pura y testeable: sin AppKit, sin red.
enum TrialConfig {
    /// La prueba dura 90 días por persona, contados desde la primera vez que abre la app.
    static let trialDays = 90
    static let priceText = "10 USD"
    /// Única constante de la URL de compra (fácil de cambiar). Solo se abre en el navegador del usuario.
    static let purchaseURL = URL(string: "https://chocolitossoft.com/premium")!
    static let lastDaysThreshold = 14
    /// Mínimo entre dos aperturas automáticas de la ventana de activación por «sacudir» (vencida).
    static let nudgeInterval: TimeInterval = 5 * 60
}

enum TrialState: Equatable {
    case licensed
    case trial(daysLeft: Int)
    case lastDays(daysLeft: Int)
    case expired
}

enum TrialPolicy {
    /// D0 + 90 a las 00:00 locales: el primer día ya vencido.
    static func trialEndDay(firstLaunch: Date, calendar: Calendar = .current) -> Date {
        let d0 = calendar.startOfDay(for: firstLaunch)
        return calendar.date(byAdding: .day, value: TrialConfig.trialDays, to: d0)!
    }

    /// Último día incluido de la prueba (D0 + 89), para mostrar «hasta el <fecha>».
    static func endDate(firstLaunch: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: -1, to: trialEndDay(firstLaunch: firstLaunch, calendar: calendar))!
    }

    /// Un solo punto de verdad. `lastSeen` = fecha más alta vista (frena retrasar el reloj).
    /// Un `firstLaunch` en el futuro (manipulado) se recorta al reloj efectivo.
    static func state(now: Date, firstLaunch: Date, lastSeen: Date?, licensed: Bool,
                      calendar: Calendar = .current) -> TrialState {
        if licensed { return .licensed }
        let effective = max(now, lastSeen ?? now)
        let first = min(firstLaunch, effective)
        let end = trialEndDay(firstLaunch: first, calendar: calendar)
        let today = calendar.startOfDay(for: effective)
        let days = calendar.dateComponents([.day], from: today, to: end).day ?? 0
        if days <= 0 { return .expired }
        return days <= TrialConfig.lastDaysThreshold ? .lastDays(daysLeft: days) : .trial(daysLeft: days)
    }
}

/// Almacén de preferencias inyectable (UserDefaults en la app; memoria en pruebas).
protocol PrefsStore: AnyObject {
    func string(_ key: String) -> String?
    func set(_ value: String?, for key: String)
}

final class UserDefaultsStore: PrefsStore {
    private let d: UserDefaults
    init(_ d: UserDefaults = .standard) { self.d = d }
    func string(_ key: String) -> String? { d.string(forKey: key) }
    func set(_ value: String?, for key: String) {
        if let value { d.set(value, forKey: key) } else { d.removeObject(forKey: key) }
    }
}

/// Segundo lugar, independiente de UserDefaults: un JSON pequeño (0600) en una carpeta (0700).
final class FileStore: PrefsStore {
    private let url: URL
    init(url: URL) { self.url = url }
    private func load() -> [String: String] {
        guard let d = try? Data(contentsOf: url),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { return [:] }
        return o
    }
    func string(_ key: String) -> String? { load()[key] }
    func set(_ value: String?, for key: String) {
        var o = load()
        if let value { o[key] = value } else { o.removeValue(forKey: key) }
        guard let d = try? JSONSerialization.data(withJSONObject: o) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? d.write(to: url, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

final class MemoryStore: PrefsStore {
    var values: [String: String] = [:]
    func string(_ key: String) -> String? { values[key] }
    func set(_ value: String?, for key: String) { values[key] = value }
}

/// Qué aviso toca mostrar al abrir la app.
enum LaunchNotice: Equatable {
    case none
    case firstRun
    case dailyReminder(daysLeft: Int)
    case expired
}

/// Coordina estado, licencia, avisos y bloqueo de funciones. Reloj, almacén y abridor de URL son inyectables.
final class TrialManager {
    private enum Key {
        static let lastSeen = "trial.lastSeen"
        static let firstLaunch = "trial.firstLaunch"
        static let welcomeSeen = "trial.welcomeSeen"
        static let lastReminderDay = "trial.lastReminderDay"
        static let license = "license.key"
    }

    private let store: PrefsStore
    /// Segundo registro de `firstLaunch` (archivo en Application Support en la app; memoria en pruebas).
    private let backup: PrefsStore
    private let clock: () -> Date
    private let calendar: Calendar
    var openURL: (URL) -> Void
    private var lastNudge: Date?

    init(store: PrefsStore = UserDefaultsStore(),
         backup: PrefsStore = MemoryStore(),
         clock: @escaping () -> Date = Date.init,
         calendar: Calendar = .current,
         app: String = LicenseConfig.appID,
         verifier: ((String) -> Result<LicenseInfo, LicenseError>)? = nil,
         openURL: @escaping (URL) -> Void = { _ in }) {
        self.store = store; self.backup = backup; self.clock = clock; self.calendar = calendar
        self.verifier = verifier ?? { LicenseVerifier.verify($0, app: app) }
        self.openURL = openURL
    }
    private let verifier: (String) -> Result<LicenseInfo, LicenseError>

    // MARK: Licencia

    /// Licencia guardada, re-verificada en cada consulta (nunca caduca por fecha).
    var license: LicenseInfo? {
        guard let key = store.string(Key.license), case .success(let info) = verifier(key) else { return nil }
        return info
    }

    func activate(_ rawKey: String) -> Result<LicenseInfo, LicenseError> {
        let clean = rawKey.filter { !$0.isWhitespace }
        if license != nil, store.string(Key.license) == clean { return .failure(.alreadyActive) }
        let result = verifier(clean)
        if case .success = result { store.set(clean, for: Key.license) }
        return result
    }

    func removeLicense() { store.set(nil, for: Key.license) }

    // MARK: Estado

    private func lastSeenDate() -> Date? {
        store.string(Key.lastSeen).flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
    }

    /// Reloj efectivo: nunca va hacia atrás respecto a la fecha más alta vista.
    private var effectiveNow: Date { max(clock(), lastSeenDate() ?? clock()) }

    /// Primer uso: se guarda en dos lugares y se usa el más antiguo; si falta uno se recrea desde el otro.
    /// Sin registro (instalación nueva o migración desde 1.5.0 de fecha fija) = ahora. En el futuro = ahora.
    var firstLaunch: Date {
        let now = effectiveNow
        func read(_ s: PrefsStore) -> Date? {
            s.string(Key.firstLaunch).flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
        }
        let found = [read(store), read(backup)].compactMap { $0 }
        let first = min(found.min() ?? now, now)
        let text = String(first.timeIntervalSince1970)
        if read(store) != first { store.set(text, for: Key.firstLaunch) }
        if read(backup) != first { backup.set(text, for: Key.firstLaunch) }
        return first
    }

    /// Estado actual; además recuerda la fecha más alta vista.
    var state: TrialState {
        let now = clock()
        let seen = lastSeenDate()
        let first = firstLaunch
        if seen == nil || now > seen! { store.set(String(now.timeIntervalSince1970), for: Key.lastSeen) }
        return TrialPolicy.state(now: now, firstLaunch: first, lastSeen: seen, licensed: license != nil, calendar: calendar)
    }

    /// Las funciones (aceptar, entregar, pegar) solo funcionan si no está vencida.
    var allowsFeatures: Bool { state != .expired }

    /// Ejecuta la función principal solo si el estado lo permite. Devuelve si se ejecutó.
    @discardableResult
    func run(_ action: () -> Void) -> Bool {
        guard allowsFeatures else { return false }
        action()
        return true
    }

    // MARK: Avisos

    private var todayKey: String {
        let c = calendar.dateComponents([.year, .month, .day], from: clock())
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Decide (y registra como visto) el aviso de arranque. Bienvenida una sola vez; recordatorio una vez al día.
    func consumeLaunchNotice() -> LaunchNotice {
        let s = state
        switch s {
        case .licensed: return .none
        case .expired: return .expired
        case .trial, .lastDays:
            if store.string(Key.welcomeSeen) == nil {
                store.set("1", for: Key.welcomeSeen)
                if case .lastDays = s { store.set(todayKey, for: Key.lastReminderDay) }
                return .firstRun
            }
            if case .lastDays(let n) = s, store.string(Key.lastReminderDay) != todayKey {
                store.set(todayKey, for: Key.lastReminderDay)
                return .dailyReminder(daysLeft: n)
            }
            return .none
        }
    }

    /// Vencida: ¿toca abrir la ventana de activación por un «sacudir»? Como mucho una vez cada pocos minutos.
    func shouldNudgeActivation() -> Bool {
        guard state == .expired else { return false }
        let now = clock()
        if let last = lastNudge, now.timeIntervalSince(last) < TrialConfig.nudgeInterval { return false }
        lastNudge = now
        return true
    }

    // MARK: Compra

    func openPurchase() { openURL(TrialConfig.purchaseURL) }

    // MARK: Textos de estado (claves en español; se traducen con L())

    var endDateText: String {
        let f = DateFormatter()
        f.dateStyle = .long; f.timeStyle = .none
        f.calendar = calendar; f.timeZone = calendar.timeZone
        return f.string(from: TrialPolicy.endDate(firstLaunch: firstLaunch, calendar: calendar))
    }

    /// Aviso permanente y discreto; nil si hay licencia.
    var statusLine: String? {
        switch state {
        case .licensed: return nil
        case .trial(let n): return L("Versión de prueba · quedan %lld días de 90 · Premium: %@", Int64(n), TrialConfig.priceText)
        case .lastDays(let n):
            return n <= 1 ? L("Último día de prueba · Premium: %@", TrialConfig.priceText)
                          : L("Quedan %lld días de prueba · Premium: %@", Int64(n), TrialConfig.priceText)
        case .expired: return L("El periodo de prueba terminó · Premium: %@", TrialConfig.priceText)
        }
    }
}

/// Instancia compartida de la app (UserDefaults reales; solo se usa desde la capa de UI).
extension TrialManager {
    static let shared: TrialManager = {
        let dir = ShelfModel.supportDir
        return TrialManager(backup: FileStore(url: dir.appendingPathComponent("prueba.json")))
    }()
}
