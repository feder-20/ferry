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
    /// Día de calendario D0 + n a la hora indicada.
    func day(_ d0: Date, _ n: Int, _ h: Int = 12, _ mi: Int = 0, _ s: Int = 0, c: Calendar? = nil) -> Date {
        let c = c ?? cal()
        let base = c.date(byAdding: .day, value: n, to: c.startOfDay(for: d0))!
        return c.date(bySettingHour: h, minute: mi, second: s, of: base)!
    }
    var first: Date { date(2026, 11, 13, 15) }
    func st(_ now: Date, first f: Date? = nil, seen: Date? = nil, lic: Bool = false, c: Calendar? = nil) -> TrialState {
        TrialPolicy.state(now: now, firstLaunch: f ?? first, lastSeen: seen, licensed: lic, calendar: c ?? cal())
    }

    // MARK: TrialPolicy
    func testStatesAndBoundaries() {
        XCTAssertEqual(TrialConfig.trialDays, 90)
        XCTAssertEqual(st(first), .trial(daysLeft: 90)) // día 1 = 90
        XCTAssertEqual(st(day(first, 0, 0, 0, 0)), .trial(daysLeft: 90))
        XCTAssertEqual(st(day(first, 1)), .trial(daysLeft: 89))
        XCTAssertEqual(st(day(first, 75)), .trial(daysLeft: 15))
        XCTAssertEqual(st(day(first, 76)), .lastDays(daysLeft: 14))
        XCTAssertEqual(st(day(first, 88)), .lastDays(daysLeft: 2))
        XCTAssertEqual(st(day(first, 89, 0, 0, 0)), .lastDays(daysLeft: 1)) // último día
        XCTAssertEqual(st(day(first, 89, 23, 59, 59)), .lastDays(daysLeft: 1))
        XCTAssertEqual(st(day(first, 90, 0, 0, 0)), .expired) // día 91
        XCTAssertEqual(st(day(first, 400)), .expired)
    }
    func testEndDateIsLastIncludedDay() {
        let c = cal()
        let end = TrialPolicy.endDate(firstLaunch: first, calendar: c)
        XCTAssertEqual(c.dateComponents([.year, .month, .day], from: end), DateComponents(year: 2027, month: 2, day: 10))
        let cut = TrialPolicy.trialEndDay(firstLaunch: first, calendar: c)
        XCTAssertEqual(c.dateComponents([.year, .month, .day, .hour], from: cut), DateComponents(year: 2027, month: 2, day: 11, hour: 0))
    }
    func testClockBackwardsDoesNotRevive() {
        XCTAssertEqual(st(day(first, 10), seen: day(first, 95)), .expired)
        XCTAssertEqual(st(day(first, 10), seen: day(first, 20)), .trial(daysLeft: 70))
    }
    func testFirstLaunchInTheFutureIsClamped() {
        let now = date(2026, 12, 1)
        XCTAssertEqual(st(now, first: date(2027, 12, 1)), .trial(daysLeft: 90)) // no da más de 90 días
        XCTAssertEqual(st(now, first: day(now, 1)), .trial(daysLeft: 90))
    }
    func testLicensedWinsOverExpired() {
        XCTAssertEqual(st(day(first, 2000), lic: true), .licensed)
        XCTAssertEqual(st(first, lic: true), .licensed)
    }
    func testTimeZonesAndDST() {
        for tz in ["America/Bogota", "Europe/Madrid", "America/New_York", "Pacific/Auckland", "Asia/Tokyo"] {
            let c = cal(tz); let f = date(2026, 11, 13, 15, c: c)
            XCTAssertEqual(st(day(f, 89, 23, 59, 59, c: c), first: f, c: c), .lastDays(daysLeft: 1), tz)
            XCTAssertEqual(st(day(f, 90, 0, 0, 0, c: c), first: f, c: c), .expired, tz)
            XCTAssertEqual(st(day(f, 76, 0, 0, 1, c: c), first: f, c: c), .lastDays(daysLeft: 14), tz)
            XCTAssertEqual(st(day(f, 75, 23, 59, 59, c: c), first: f, c: c), .trial(daysLeft: 15), tz)
        }
        // Cruce de DST dentro de la prueba: días de calendario, sin ±1.
        let ny = cal("America/New_York"), nyF = date(2027, 3, 1, 23, 30, c: ny) // cambio de hora el 14 mar
        XCTAssertEqual(st(date(2027, 3, 15, 0, 5, c: ny), first: nyF, c: ny), .trial(daysLeft: 76))
        XCTAssertEqual(st(day(nyF, 89, 23, 59, c: ny), first: nyF, c: ny), .lastDays(daysLeft: 1))
        XCTAssertEqual(st(day(nyF, 90, 0, 0, c: ny), first: nyF, c: ny), .expired)
        let mad = cal("Europe/Madrid"), madF = date(2026, 10, 1, 8, c: mad) // cambio de hora el 25 oct
        XCTAssertEqual(st(date(2026, 10, 24, 12, c: mad), first: madF, c: mad), .trial(daysLeft: 67))
        XCTAssertEqual(st(date(2026, 10, 26, 12, c: mad), first: madF, c: mad), .trial(daysLeft: 65))
        XCTAssertEqual(st(day(madF, 89, 23, 59, c: mad), first: madF, c: mad), .lastDays(daysLeft: 1))
        XCTAssertEqual(st(day(madF, 90, 0, 0, c: mad), first: madF, c: mad), .expired)
    }

    // MARK: Manager (reloj y almacenes inyectados; nunca se toca el disco real)
    final class Clock { var now: Date; init(_ d: Date) { now = d } }
    func manager(_ clock: Clock, store: MemoryStore = MemoryStore(), backup: MemoryStore = MemoryStore(),
                 opened: ((URL) -> Void)? = nil) -> TrialManager {
        TrialManager(store: store, backup: backup, clock: { clock.now }, calendar: cal(), openURL: opened ?? { _ in })
    }
    let fl = "trial.firstLaunch"
    func ts(_ d: Date) -> String { String(d.timeIntervalSince1970) }
    /// Manager con firstLaunch ya registrado en ambos lugares.
    func seeded(_ clock: Clock, first f: Date? = nil) -> (TrialManager, MemoryStore, MemoryStore) {
        let a = MemoryStore(), b = MemoryStore()
        a.values[fl] = ts(f ?? first); b.values[fl] = ts(f ?? first)
        return (manager(clock, store: a, backup: b), a, b)
    }

    func testFirstLaunchRecordedInBothPlacesAndStable() {
        let clock = Clock(date(2026, 11, 13)); let a = MemoryStore(), b = MemoryStore()
        let m = manager(clock, store: a, backup: b)
        XCTAssertEqual(m.state, .trial(daysLeft: 90))
        XCTAssertEqual(a.string(fl), ts(clock.now)); XCTAssertEqual(b.string(fl), ts(clock.now))
        clock.now = day(clock.now, 30)
        XCTAssertEqual(m.state, .trial(daysLeft: 60)) // no se reinicia
        XCTAssertEqual(a.string(fl), ts(date(2026, 11, 13)))
    }
    func testFirstLaunchUsesOldestAndRecreatesMissing() {
        let old = date(2026, 10, 1), recent = date(2026, 11, 1)
        let clock = Clock(date(2026, 11, 13)) // 43 días desde `old`
        // Borrar UserDefaults: se recrea desde el archivo.
        let a = MemoryStore(), b = MemoryStore(); b.values[fl] = ts(old)
        XCTAssertEqual(manager(clock, store: a, backup: b).state, .trial(daysLeft: 47))
        XCTAssertEqual(a.string(fl), ts(old))
        // Borrar el archivo: se recrea desde UserDefaults.
        let c = MemoryStore(), d = MemoryStore(); c.values[fl] = ts(old)
        XCTAssertEqual(manager(clock, store: c, backup: d).state, .trial(daysLeft: 47))
        XCTAssertEqual(d.string(fl), ts(old))
        // Dos valores distintos: gana el más antiguo y se corrige el otro.
        let e = MemoryStore(), f = MemoryStore(); e.values[fl] = ts(recent); f.values[fl] = ts(old)
        XCTAssertEqual(manager(clock, store: e, backup: f).state, .trial(daysLeft: 47))
        XCTAssertEqual(e.string(fl), ts(old))
    }
    func testManagerFirstLaunchInTheFutureUsesNow() {
        let clock = Clock(date(2026, 11, 13)); let a = MemoryStore(), b = MemoryStore()
        a.values[fl] = ts(date(2030, 1, 1)); b.values[fl] = ts(date(2030, 1, 1))
        XCTAssertEqual(manager(clock, store: a, backup: b).state, .trial(daysLeft: 90))
        XCTAssertEqual(a.string(fl), ts(clock.now)) // se corrige el valor manipulado
    }
    func testMigrationFrom150StartsFullTrialAndKeepsWelcomeSeen() {
        // Usuario de 1.5.0 (fecha fija): sin firstLaunch, con welcomeSeen y lastSeen.
        let clock = Clock(date(2026, 11, 20)); let a = MemoryStore(), b = MemoryStore()
        a.values["trial.welcomeSeen"] = "1"; a.values["trial.lastSeen"] = ts(date(2026, 11, 19))
        let m = manager(clock, store: a, backup: b)
        XCTAssertEqual(m.state, .trial(daysLeft: 90)) // 90 días completos desde actualizar
        XCTAssertEqual(a.string(fl), ts(clock.now))
        XCTAssertEqual(m.consumeLaunchNotice(), .none) // no repite la bienvenida
        clock.now = day(clock.now, 89)
        XCTAssertEqual(m.state, .lastDays(daysLeft: 1))
        clock.now = day(clock.now, 1)
        XCTAssertEqual(m.state, .expired)
    }
    func testStatusTextsMentionNinetyDaysAndPersonalDate() {
        let clock = Clock(date(2026, 11, 13)); let (m, _, _) = seeded(clock)
        XCTAssertTrue(m.statusLine!.contains("90 días de 90") || m.statusLine!.contains("quedan 90 días de 90"))
        XCTAssertFalse(m.endDateText.contains("2027") && m.endDateText.contains("9 de"))
        let f = DateFormatter(); f.dateStyle = .long; f.timeStyle = .none; f.calendar = cal(); f.timeZone = cal().timeZone
        XCTAssertEqual(m.endDateText, f.string(from: date(2027, 2, 10)))
    }
    func testManagerClockBackwards() {
        let clock = Clock(day(first, 100)); let (m, a, b) = seeded(clock)
        XCTAssertEqual(m.state, .expired)
        clock.now = day(first, 10)
        XCTAssertEqual(m.state, .expired)
        XCTAssertEqual(manager(clock, store: a, backup: b).state, .expired) // persistido
    }
    func testLaunchNoticesOncePerDay() {
        let clock = Clock(first); let (m, _, _) = seeded(clock)
        XCTAssertEqual(m.consumeLaunchNotice(), .firstRun)
        XCTAssertEqual(m.consumeLaunchNotice(), .none) // ya visto
        clock.now = day(first, 78)
        XCTAssertEqual(m.consumeLaunchNotice(), .dailyReminder(daysLeft: 12))
        XCTAssertEqual(m.consumeLaunchNotice(), .none) // máximo una vez al día
        clock.now = day(first, 79, 9)
        XCTAssertEqual(m.consumeLaunchNotice(), .dailyReminder(daysLeft: 11))
        clock.now = day(first, 90)
        XCTAssertEqual(m.consumeLaunchNotice(), .expired)
    }
    func testNudgeThrottle() {
        let clock = Clock(day(first, 120)); let (m, _, _) = seeded(clock)
        XCTAssertTrue(m.shouldNudgeActivation())
        clock.now.addTimeInterval(60)
        XCTAssertFalse(m.shouldNudgeActivation())
        clock.now.addTimeInterval(TrialConfig.nudgeInterval)
        XCTAssertTrue(m.shouldNudgeActivation())
        XCTAssertFalse(seeded(Clock(first)).0.shouldNudgeActivation()) // en prueba no molesta
    }
    func testPurchaseOpensInjectedURL() {
        var got: URL?
        manager(Clock(first), opened: { got = $0 }).openPurchase()
        XCTAssertEqual(got?.absoluteString, "https://chocolitossoft.com/premium")
    }
    func testFileStoreRoundTripInTempDir() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ferry-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fs = FileStore(url: dir.appendingPathComponent("prueba.json"))
        XCTAssertNil(fs.string(fl))
        fs.set("123", for: fl)
        XCTAssertEqual(FileStore(url: dir.appendingPathComponent("prueba.json")).string(fl), "123")
        let attrs = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("prueba.json").path)
        XCTAssertEqual((attrs?[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    // MARK: Bloqueo de la función principal
    func testExpiredRejectsMainFunctionAndTrialRuns() {
        var ran = 0
        XCTAssertFalse(seeded(Clock(day(first, 90))).0.run { ran += 1 })
        XCTAssertEqual(ran, 0)
        XCTAssertTrue(seeded(Clock(first)).0.run { ran += 1 })
        XCTAssertTrue(seeded(Clock(day(first, 89))).0.run { ran += 1 })
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
        let store = MemoryStore(); let clock = Clock(day(first, 120))
        let bk = MemoryStore(); bk.values[fl] = ts(first); store.values[fl] = ts(first)
        let m = TrialManager(store: store, backup: bk, clock: { clock.now }, calendar: cal(), verifier: { self.verify($0) })
        XCTAssertEqual(m.state, .expired)
        XCTAssertEqual(m.activate(key(app: "cabrio")), .failure(.wrongApp))
        XCTAssertEqual(m.state, .expired)
        let good = key()
        XCTAssertNotNil(try? m.activate(good).get())
        XCTAssertEqual(m.state, .licensed)
        XCTAssertTrue(m.allowsFeatures)
        XCTAssertEqual(m.activate(good), .failure(.alreadyActive))
        // se vuelve a verificar al arrancar
        XCTAssertEqual(TrialManager(store: store, backup: bk, clock: { clock.now }, calendar: cal(), verifier: { self.verify($0) }).state, .licensed)
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
                    "Versión de prueba · quedan %lld días de 90 · Premium: %@", "Último día de prueba · Premium: %@",
                    "Quedan %lld días de prueba · Premium: %@", "El periodo de prueba terminó · Premium: %@",
                    "Estás usando una versión de prueba (tester)", "Hoy es el último día de prueba", "Quedan %lld días de prueba",
                    "Ferry está en periodo de prueba: úsala gratis durante 90 días (hasta el %@) y ayúdanos a mejorarla. Después, cada app costará 10 USD (pago único). Tus archivos nunca se tocan ni se pierden.",
                    "Entendido", "Más información / Obtener premium", "El periodo de prueba terminó",
                    "Gracias por probar Ferry. Para seguir usándola, obtén la versión premium (%@, pago único).",
                    "Tus archivos de la estantería se conservan y no se tocan.", "Premium: %@ por app, pago único",
                    "Tengo una clave", "Activar", "Cerrar", "La clave no es válida. Revisa que esté completa.",
                    "Esa clave es de otra app, no de Ferry.", "Esa clave ya está activada.", "Premium activado · %@",
                    "Quitar licencia", "Tu prueba de 90 días dura hasta el %@.", "Licencia"]
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
