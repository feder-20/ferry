import XCTest
import CryptoKit
@testable import Ferry

final class TrialTests: XCTestCase {
    func cal(_ tz: String = "America/Bogota") -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: tz)!; return c
    }
    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0, _ s: Int = 0, c: Calendar? = nil) -> Date {
        let c = c ?? cal()
        return c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi, second: s))!
    }
    func st(_ now: Date, seen: Date? = nil, lic: Bool = false, c: Calendar? = nil) -> TrialState {
        TrialPolicy.state(now: now, lastSeen: seen, licensed: lic, calendar: c ?? cal())
    }

    // MARK: TrialPolicy
    func testStatesAndBoundaries() {
        XCTAssertEqual(st(date(2026, 11, 11)), .trial(daysLeft: 91))
        XCTAssertEqual(st(date(2027, 1, 26)), .trial(daysLeft: 15))
        XCTAssertEqual(st(date(2027, 1, 27)), .lastDays(daysLeft: 14))
        XCTAssertEqual(st(date(2027, 2, 8)), .lastDays(daysLeft: 2))
        XCTAssertEqual(st(date(2027, 2, 9, 0, 0, 0)), .lastDays(daysLeft: 1))
        XCTAssertEqual(st(date(2027, 2, 9, 23, 59, 59)), .lastDays(daysLeft: 1))
        XCTAssertEqual(st(date(2027, 2, 10, 0, 0, 0)), .expired)
        XCTAssertEqual(st(date(2028, 1, 1)), .expired)
    }
    func testClockBackwardsDoesNotRevive() {
        XCTAssertEqual(st(date(2026, 12, 1), seen: date(2027, 2, 12)), .expired)
        XCTAssertEqual(st(date(2026, 12, 1), seen: date(2026, 11, 1)), .trial(daysLeft: 71))
    }
    func testLicensedWinsOverExpired() {
        XCTAssertEqual(st(date(2030, 1, 1), lic: true), .licensed)
        XCTAssertEqual(st(date(2026, 11, 11), lic: true), .licensed)
    }
    func testTimeZonesAndDST() {
        for tz in ["America/Bogota", "Europe/Madrid", "America/New_York", "Pacific/Auckland", "Asia/Tokyo"] {
            let c = cal(tz)
            XCTAssertEqual(st(date(2027, 2, 9, 23, 59, 59, c: c), c: c), .lastDays(daysLeft: 1), tz)
            XCTAssertEqual(st(date(2027, 2, 10, 0, 0, 0, c: c), c: c), .expired, tz)
            XCTAssertEqual(st(date(2027, 1, 27, 0, 0, 1, c: c), c: c), .lastDays(daysLeft: 14), tz)
            XCTAssertEqual(st(date(2027, 1, 26, 23, 59, 59, c: c), c: c), .trial(daysLeft: 15), tz)
        }
        // Cruce de DST (EE. UU. 14 mar 2027, Europa 28 mar 2027): días de calendario, sin ±1.
        let ny = cal("America/New_York")
        XCTAssertEqual(st(date(2027, 3, 1, c: ny), c: ny), .expired)
        let mad = cal("Europe/Madrid")
        XCTAssertEqual(st(date(2026, 10, 24, 12, c: mad), c: mad), .trial(daysLeft: 109)) // antes del cambio de hora (25 oct)
        XCTAssertEqual(st(date(2026, 10, 26, 12, c: mad), c: mad), .trial(daysLeft: 107))
    }

    // MARK: Manager (reloj, almacén y URL inyectados)
    final class Clock { var now: Date; init(_ d: Date) { now = d } }
    func manager(_ clock: Clock, store: MemoryStore = MemoryStore(), opened: ((URL) -> Void)? = nil) -> TrialManager {
        TrialManager(store: store, clock: { clock.now }, calendar: cal(), openURL: opened ?? { _ in })
    }
    func testManagerClockBackwards() {
        let clock = Clock(date(2027, 2, 12)); let store = MemoryStore()
        let m = manager(clock, store: store)
        XCTAssertEqual(m.state, .expired)
        clock.now = date(2026, 12, 1)
        XCTAssertEqual(m.state, .expired)
        XCTAssertEqual(manager(clock, store: store).state, .expired) // persistido
    }
    func testLaunchNoticesOncePerDay() {
        let clock = Clock(date(2026, 11, 11)); let m = manager(clock)
        XCTAssertEqual(m.consumeLaunchNotice(), .firstRun)
        XCTAssertEqual(m.consumeLaunchNotice(), .none) // ya visto
        clock.now = date(2027, 1, 30)
        XCTAssertEqual(m.consumeLaunchNotice(), .dailyReminder(daysLeft: 11))
        XCTAssertEqual(m.consumeLaunchNotice(), .none) // máximo una vez al día
        clock.now = date(2027, 1, 31, 9)
        XCTAssertEqual(m.consumeLaunchNotice(), .dailyReminder(daysLeft: 10))
        clock.now = date(2027, 2, 10)
        XCTAssertEqual(m.consumeLaunchNotice(), .expired)
    }
    func testNudgeThrottle() {
        let clock = Clock(date(2027, 3, 1)); let m = manager(clock)
        XCTAssertTrue(m.shouldNudgeActivation())
        clock.now.addTimeInterval(60)
        XCTAssertFalse(m.shouldNudgeActivation())
        clock.now.addTimeInterval(TrialConfig.nudgeInterval)
        XCTAssertTrue(m.shouldNudgeActivation())
        let t = Clock(date(2026, 11, 11))
        XCTAssertFalse(manager(t).shouldNudgeActivation()) // en prueba no molesta
    }
    func testPurchaseOpensInjectedURL() {
        var got: URL?
        manager(Clock(date(2026, 11, 11)), opened: { got = $0 }).openPurchase()
        XCTAssertEqual(got?.absoluteString, "https://chocolitossoft.com/premium")
    }

    // MARK: Bloqueo de la función principal
    func testExpiredRejectsMainFunctionAndTrialRuns() {
        var ran = 0
        XCTAssertFalse(manager(Clock(date(2027, 2, 10))).run { ran += 1 })
        XCTAssertEqual(ran, 0)
        XCTAssertTrue(manager(Clock(date(2026, 11, 11))).run { ran += 1 })
        XCTAssertTrue(manager(Clock(date(2027, 2, 1))).run { ran += 1 })
        XCTAssertEqual(ran, 2)
    }

    // MARK: Licencias (con un par de claves de prueba; no la privada real)
    let priv = P256.Signing.PrivateKey()
    func b64(_ d: Data, pad: Bool = false) -> String {
        var s = d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        if !pad { s = s.replacingOccurrences(of: "=", with: "") }
        return s
    }
    func key(app: String = "ferry", prefix: String? = nil, name: String = "Ana", signer: P256.Signing.PrivateKey? = nil, pad: Bool = false) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: ["app": app, "name": name, "issued": "2026-11-11T00:00:00Z"], options: [.sortedKeys])
        let sig = try! (signer ?? priv).signature(for: payload).rawRepresentation
        return "\(prefix ?? app.uppercased()).\(b64(payload, pad: pad)).\(b64(sig, pad: pad))"
    }
    func verify(_ k: String) -> Result<LicenseInfo, LicenseError> {
        LicenseVerifier.verify(k, app: "ferry", publicKey: priv.publicKey)
    }

    func testLicenseValid() {
        XCTAssertEqual(try? verify(key()).get().name, "Ana")
        XCTAssertEqual(try? verify(key(app: "all")).get().app, "all")
    }
    func testLicenseWrongApp() {
        XCTAssertEqual(verify(key(app: "cabrio")), .failure(.wrongApp))
        XCTAssertEqual(verify(key(app: "convoy")), .failure(.wrongApp))
    }
    func testLicenseTampering() {
        let k = key(); let p = k.split(separator: ".").map(String.init)
        let other = try! JSONSerialization.data(withJSONObject: ["app": "ferry", "name": "Eve", "issued": "x"])
        XCTAssertEqual(verify("\(p[0]).\(b64(other)).\(p[2])"), .failure(.invalid)) // payload alterado
        var sig = Data(base64Encoded: p[2].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "==")!
        sig[0] ^= 0xFF
        XCTAssertEqual(verify("\(p[0]).\(p[1]).\(b64(sig))"), .failure(.invalid)) // firma alterada
        XCTAssertEqual(verify(key(prefix: "CABRIO")), .failure(.invalid)) // prefijo no coincide
        XCTAssertEqual(verify(key(prefix: "ALL")), .failure(.invalid))
    }
    func testLicenseGarbage() {
        let k = key()
        for bad in ["", "   ", "basura", "FERRY", "FERRY..", "FERRY.a.b", String(k.dropLast(10)), "ferry.\(k.split(separator: ".")[1])", "\u{0}.\u{0}.\u{0}"] {
            XCTAssertEqual(verify(bad), .failure(.invalid), bad)
        }
    }
    func testLicenseWhitespaceAndPadding() {
        let k = key()
        let wrapped = "  " + String(k.prefix(20)) + "\n" + String(k.dropFirst(20)) + " \r\n"
        XCTAssertNotNil(try? verify(wrapped).get())
        XCTAssertNotNil(try? verify(key(pad: true)).get()) // con relleno
        XCTAssertNotNil(try? verify(key(pad: false)).get())
    }
    func testLicenseDifferentPublicKey() {
        XCTAssertEqual(verify(key(signer: P256.Signing.PrivateKey())), .failure(.invalid))
    }

    func testManagerActivationLifecycle() {
        let store = MemoryStore(); let clock = Clock(date(2027, 3, 1))
        let m = TrialManager(store: store, clock: { clock.now }, calendar: cal(), verifier: { self.verify($0) })
        XCTAssertEqual(m.state, .expired)
        XCTAssertEqual(m.activate(key(app: "cabrio")), .failure(.wrongApp))
        XCTAssertEqual(m.state, .expired)
        let good = key()
        XCTAssertNotNil(try? m.activate(good).get())
        XCTAssertEqual(m.state, .licensed)
        XCTAssertTrue(m.allowsFeatures)
        XCTAssertEqual(m.activate(good), .failure(.alreadyActive))
        // se vuelve a verificar al arrancar
        XCTAssertEqual(TrialManager(store: store, clock: { clock.now }, calendar: cal(), verifier: { self.verify($0) }).state, .licensed)
        m.removeLicense()
        XCTAssertEqual(m.state, .expired)
    }

    // MARK: Extremo a extremo con la clave pública incrustada
    func testEmbeddedPublicKeyAndIssuedKey() throws {
        XCTAssertNotNil(LicenseConfig.publicKey)
        // Emite claves con la herramienta local (solo se ejecuta; no se lee la privada). Se omite si no existe.
        let tool = "/Users/federicotrujillo/DesarrollosRECA/ChocolitosLicense/issue-license.swift"
        guard FileManager.default.isExecutableFile(atPath: tool) else { throw XCTSkip("Sin issue-license.swift") }
        func issue(_ app: String) throws -> String {
            let p = Process(); let out = Pipe()
            p.executableURL = URL(fileURLWithPath: tool); p.arguments = [app, "Prueba"]; p.standardOutput = out
            try p.run(); p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let ferry = try issue("ferry"), cabrio = try issue("cabrio")
        XCTAssertEqual(try LicenseVerifier.verify(ferry).get().name, "Prueba")
        XCTAssertEqual(LicenseVerifier.verify(cabrio), .failure(.wrongApp))
    }

    // MARK: Localización
    func testNewStringsAreLocalizedWithMatchingPlaceholders() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let en = try String(contentsOf: root.appendingPathComponent("Resources/en.lproj/Localizable.strings"), encoding: .utf8)
        var dict: [String: String] = [:]
        for line in en.split(separator: "\n") {
            let parts = line.components(separatedBy: "\" = \"")
            if parts.count == 2, line.hasPrefix("\"") {
                dict[String(parts[0].dropFirst())] = String(parts[1].dropLast(2))
            }
        }
        let keys = ["Obtener premium…", "Obtener premium", "Introducir clave…", "Introducir clave",
                    "Versión de prueba · quedan %lld días · Premium: %@", "Último día de prueba · Premium: %@",
                    "Quedan %lld días de prueba · Premium: %@", "El periodo de prueba terminó · Premium: %@",
                    "Estás usando una versión de prueba (tester)", "Hoy es el último día de prueba", "Quedan %lld días de prueba",
                    "Ferry está en periodo de prueba hasta el %@. Es gratis durante este periodo y nos ayudas a mejorarla. Después, cada app costará 10 USD (pago único). Tus archivos nunca se tocan ni se pierden.",
                    "Entendido", "Más información / Obtener premium", "El periodo de prueba terminó",
                    "Gracias por probar Ferry. Para seguir usándola, obtén la versión premium (%@, pago único).",
                    "Tus archivos de la estantería se conservan y no se tocan.", "Premium: %@ por app, pago único",
                    "Tengo una clave", "Activar", "Cerrar", "La clave no es válida. Revisa que esté completa.",
                    "Esa clave es de otra app, no de Ferry.", "Esa clave ya está activada.", "Premium activado · %@",
                    "Quitar licencia", "La prueba termina el %@.", "Licencia"]
        func marks(_ s: String) -> [String] {
            (try! NSRegularExpression(pattern: "%(lld|@|d)")).matches(in: s, range: NSRange(s.startIndex..., in: s))
                .map { String(s[Range($0.range, in: s)!]) }
        }
        for k in keys {
            let v = try XCTUnwrap(dict[k], "Falta en inglés: \(k)")
            XCTAssertEqual(marks(k), marks(v), k)
            XCTAssertNotEqual(k, v)
        }
    }
}
