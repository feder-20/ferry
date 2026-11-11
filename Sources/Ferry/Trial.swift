import Foundation

/// Periodo de prueba (tester) de Ferry. Lógica pura y testeable: sin AppKit, sin red.
enum TrialConfig {
    /// Fin de la prueba: 9 de febrero de 2027, 23:59:59 (hora local).
    static let endYear = 2027, endMonth = 2, endDay = 9
    static let priceText = "10 USD"
    /// Única constante de la URL de compra (fácil de cambiar). Solo se abre en el navegador del usuario.
    static let purchaseURL = URL(string: "https://chocolitossoft.com/premium")!
    static let lastDaysThreshold = 14
    /// Mínimo entre dos aperturas automáticas de la ventana de activación por «sacudir» (vencida).
    static let nudgeInterval: TimeInterval = 5 * 60

    static func end(calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: endYear, month: endMonth, day: endDay,
                                           hour: 23, minute: 59, second: 59))!
    }
}

enum TrialState: Equatable {
    case licensed
    case trial(daysLeft: Int)
    case lastDays(daysLeft: Int)
    case expired
}

enum TrialPolicy {
    /// Un solo punto de verdad. `lastSeen` = fecha más alta vista (frena retrasar el reloj).
    static func state(now: Date, lastSeen: Date?, licensed: Bool,
                      calendar: Calendar = .current) -> TrialState {
        if licensed { return .licensed }
        let effective = max(now, lastSeen ?? now)
        let end = TrialConfig.end(calendar: calendar)
        if effective > end { return .expired }
        let today = calendar.startOfDay(for: effective)
        let endDay = calendar.startOfDay(for: end)
        let days = (calendar.dateComponents([.day], from: today, to: endDay).day ?? 0) + 1
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
        static let welcomeSeen = "trial.welcomeSeen"
        static let lastReminderDay = "trial.lastReminderDay"
        static let license = "license.key"
    }

    private let store: PrefsStore
    private let clock: () -> Date
    private let calendar: Calendar
    var openURL: (URL) -> Void
    private var lastNudge: Date?

    init(store: PrefsStore = UserDefaultsStore(),
         clock: @escaping () -> Date = Date.init,
         calendar: Calendar = .current,
         app: String = LicenseConfig.appID,
         verifier: ((String) -> Result<LicenseInfo, LicenseError>)? = nil,
         openURL: @escaping (URL) -> Void = { _ in }) {
        self.store = store; self.clock = clock; self.calendar = calendar
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

    /// Estado actual; además recuerda la fecha más alta vista.
    var state: TrialState {
        let now = clock()
        let seen = store.string(Key.lastSeen).flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
        if seen == nil || now > seen! { store.set(String(now.timeIntervalSince1970), for: Key.lastSeen) }
        return TrialPolicy.state(now: now, lastSeen: seen, licensed: license != nil, calendar: calendar)
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
        return f.string(from: TrialConfig.end(calendar: calendar))
    }

    /// Aviso permanente y discreto; nil si hay licencia.
    var statusLine: String? {
        switch state {
        case .licensed: return nil
        case .trial(let n): return L("Versión de prueba · quedan %lld días · Premium: %@", Int64(n), TrialConfig.priceText)
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
        let m = TrialManager()
        return m
    }()
}
