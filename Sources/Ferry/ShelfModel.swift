import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ShelfContent {
    case file(URL)
    case webURL(URL)
    case text(String)
}

/// Forma guardable de un elemento de la estantería.
struct StoredItem: Codable {
    var kind: String
    var value: String
}

/// Un archivo cortado: recuerda de dónde vino para poder devolverlo.
struct CutRecord: Codable, Identifiable {
    var id = UUID()
    var name: String
    var originalPath: String
    var stashPath: String          // dónde guarda Ferry el original cortado
    var destinationPath: String?   // copia pegada por Ferry (si se conoce)
    var date: Date
}

struct PersistedState: Codable {
    var items: [StoredItem]
    var history: [CutRecord]
}

struct ShelfItem: Identifiable {
    let id: UUID
    let content: ShelfContent

    init(id: UUID = UUID(), content: ShelfContent) {
        self.id = id
        self.content = content
    }

    var key: String {
        switch content {
        case .file(let u): return "f:" + u.standardizedFileURL.path
        case .webURL(let u): return "u:" + u.absoluteString
        case .text(let t): return "t:" + t
        }
    }

    var title: String {
        switch content {
        case .file(let u): return u.lastPathComponent
        case .webURL(let u): return u.absoluteString
        case .text(let s): return String(s.prefix(60))
        }
    }

    var icon: NSImage {
        switch content {
        case .file(let u):
            if let img = NSImage(contentsOf: u), u.isImageFile { return img }
            return NSWorkspace.shared.icon(forFile: u.path)
        case .webURL:
            return NSImage(systemSymbolName: "link", accessibilityDescription: nil) ?? NSImage()
        case .text:
            return NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil) ?? NSImage()
        }
    }

    var pasteboardWriter: NSPasteboardWriting {
        switch content {
        case .file(let u), .webURL(let u): return u as NSURL
        case .text(let t): return t as NSString
        }
    }

    var stored: StoredItem {
        switch content {
        case .file(let u): return StoredItem(kind: "file", value: u.path)
        case .webURL(let u): return StoredItem(kind: "url", value: u.absoluteString)
        case .text(let t): return StoredItem(kind: "text", value: t)
        }
    }

    init?(stored: StoredItem) {
        switch stored.kind {
        case "file":
            guard FileManager.default.fileExists(atPath: stored.value) else { return nil }
            self.init(content: .file(URL(fileURLWithPath: stored.value)))
        case "url":
            guard let u = URL(string: stored.value) else { return nil }
            self.init(content: .webURL(u))
        case "text":
            self.init(content: .text(stored.value))
        default:
            return nil
        }
    }
}

extension URL {
    var isImageFile: Bool {
        (try? resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .image) ?? false
    }
}

final class ShelfModel: ObservableObject {
    @Published var items: [ShelfItem] = [] { didSet { save() } }
    @Published var history: [CutRecord] = [] { didSet { save() } }
    @Published var selected: Set<UUID> = []
    @Published var isTargeted = false
    @Published var showHistory = false

    private var isLoading = true
    /// Originales que se están entregando (conversión en curso): no se cortan hasta terminar.
    var busyPaths: Set<String> = []

    // MARK: Preferencias
    static let moveKey = "moveOnDrop"
    static var moveMode: Bool {
        get { UserDefaults.standard.object(forKey: moveKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: moveKey) }
    }
    static let rememberKey = "rememberShelf"
    static var rememberShelf: Bool {
        get { UserDefaults.standard.object(forKey: rememberKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: rememberKey) }
    }

    // MARK: Carpetas
    static let supportDir: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ferry", isDirectory: true)
    }()
    static var stashDir: URL { supportDir.appendingPathComponent("Cortados", isDirectory: true) }
    private static var stateURL: URL { supportDir.appendingPathComponent("estado.json") }
    static var tempRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Ferry", isDirectory: true)
    }
    static let stashDays = 7.0

    init() {
        Self.ensureSupportDirs()
        load()
        purgeOldStash()
        isLoading = false
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Carpeta de datos privada (0700).
    static func ensureSupportDirs() {
        let fm = FileManager.default
        for dir in [supportDir, stashDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
    }

    /// ¿Está `url` dentro de la carpeta de cortados de Ferry (resolviendo symlinks)?
    static func isInStash(_ url: URL) -> Bool {
        PathSafety.isInside(url.path, base: stashDir.path)
    }
    static func isValidStashEntry(_ path: String) -> Bool {
        PathSafety.isValidStashEntry(path, stashDir: stashDir.path)
    }

    // MARK: Persistencia
    private func load() {
        guard let data = try? Data(contentsOf: Self.stateURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        items = state.items.compactMap { ShelfItem(stored: $0) }
        history = state.history.compactMap { Self.sanitized($0) }
    }

    /// estado.json puede haber sido editado: descarta o corrige entradas con rutas fuera de lugar.
    static func sanitized(_ r: CutRecord) -> CutRecord? {
        guard isValidStashEntry(r.stashPath), FileManager.default.fileExists(atPath: r.stashPath),
              PathSafety.isValidOriginal(r.originalPath, name: r.name, home: home) else { return nil }
        var r = r
        if let d = r.destinationPath,
           !PathSafety.isPlausibleDestination(d, name: r.name, home: home) { r.destinationPath = nil }
        return r
    }

    func save() {
        guard !isLoading else { return }
        let state = PersistedState(items: Self.rememberShelf ? items.map(\.stored) : [], history: history)
        Self.ensureSupportDirs()
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: Self.stateURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.stateURL.path)
        }
    }

    /// Borra los temporales que ningún elemento usa (o todos, si no se recuerda la estantería).
    func cleanTemp() {
        let fm = FileManager.default
        let keep: Set<String> = Self.rememberShelf
            ? Set(items.compactMap { item -> String? in
                guard case .file(let u) = item.content, Self.isTemp(u) else { return nil }
                return u.deletingLastPathComponent().resolvingSymlinksInPath().path
            })
            : []
        let subs = (try? fm.contentsOfDirectory(at: Self.tempRoot, includingPropertiesForKeys: nil)) ?? []
        for sub in subs where !keep.contains(sub.resolvingSymlinksInPath().path) {
            try? fm.removeItem(at: sub)
        }
    }

    static func isTemp(_ url: URL) -> Bool {
        url.resolvingSymlinksInPath().path.hasPrefix(tempRoot.resolvingSymlinksInPath().path + "/")
    }

    // MARK: Elementos
    /// Añade evitando duplicados (mismo archivo / enlace / texto).
    func add(_ content: ShelfContent) {
        guard TrialManager.shared.allowsFeatures else { return } // vencida: no se añade nada (lo guardado se conserva)
        let item = ShelfItem(content: content)
        if items.contains(where: { $0.key == item.key }) { return }
        items.append(item)
    }

    func removeAll() {
        guard TrialManager.shared.allowsFeatures else { return }
        items.removeAll(); selected.removeAll()
    }
    func remove(_ item: ShelfItem) { removeItems([item.id]) }
    func removeItems(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
        selected.subtract(ids)
    }

    // MARK: Selección múltiple
    func toggleSelect(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
    var allSelected: Bool { !items.isEmpty && selected.count == items.count }
    func toggleSelectAll() {
        selected = allSelected ? [] : Set(items.map(\.id))
    }
    /// Lo que se arrastra al agarrar `item`: todo lo seleccionado, o solo él.
    func dragItems(for item: ShelfItem) -> [ShelfItem] {
        selected.contains(item.id) ? items.filter { selected.contains($0.id) } : [item]
    }

    // MARK: Cortar
    /// Termina un traslado: saca los elementos de la estantería y, en modo cortar, aparta los originales.
    func finishCut(_ done: [ShelfItem], destinations: [UUID: URL] = [:], immediate: Bool = false,
                   origin: DeliveryOrigin = .user) {
        removeItems(Set(done.map(\.id)))
        guard DeliveryPolicy.shouldCut(moveMode: Self.moveMode, origin: origin) else { return }
        for item in done {
            guard case .file(let url) = item.content else { continue }
            if immediate { cutOriginal(url, destination: destinations[item.id]) }
            else { scheduleCut(url, destination: destinations[item.id]) }
        }
    }

    /// Espera según el tamaño para que el destino termine de copiar, y luego aparta el original.
    private func scheduleCut(_ url: URL, destination: URL?) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let size = Self.totalSize(url)
            let delay = min(180, max(2, 2 + Double(size) / 15_000_000))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self?.cutOriginal(url, destination: destination)
            }
        }
    }

    /// El original se mueve a la carpeta de cortados de Ferry (7 días) para poder devolverlo.
    func cutOriginal(_ url: URL, destination: URL?) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        if busyPaths.contains(url.path) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.cutOriginal(url, destination: destination)
            }
            return
        }
        if Self.isTemp(url) { try? fm.removeItem(at: url); return } // copia temporal: sin origen
        let sub = Self.stashDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = sub.appendingPathComponent(url.lastPathComponent)
        do {
            try fm.createDirectory(at: sub, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try fm.moveItem(at: url, to: target)
            history.insert(CutRecord(name: url.lastPathComponent, originalPath: url.path,
                                     stashPath: target.path, destinationPath: destination?.path,
                                     date: Date()), at: 0)
            while history.count > 50 {
                removeStash(of: history.removeLast())
            }
        } catch {
            alert(L("No se pudo cortar el original"),
                  "\(url.lastPathComponent): \(error.localizedDescription)\n\n" + L("Es posible que macOS necesite permiso de acceso a esa carpeta (Ajustes → Privacidad y seguridad → Archivos y carpetas / Acceso total al disco)."))
        }
    }

    /// "Devolver al origen": regresa el archivo cortado a su carpeta original.
    func restore(_ record: CutRecord) {
        guard TrialManager.shared.allowsFeatures else { return }
        let fm = FileManager.default
        let stash = URL(fileURLWithPath: record.stashPath)
        guard Self.isValidStashEntry(record.stashPath),
              PathSafety.isValidOriginal(record.originalPath, name: record.name, home: Self.home) else {
            history.removeAll { $0.id == record.id }
            return
        }
        guard fm.fileExists(atPath: stash.path) else {
            history.removeAll { $0.id == record.id }
            alert(L("No se encontró el archivo"), L("%@ ya no está en la carpeta de cortados de Ferry.", record.name))
            return
        }
        let original = URL(fileURLWithPath: record.originalPath)
        let target = Self.uniqueURL(in: original.deletingLastPathComponent(), name: original.lastPathComponent)
        do {
            try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: stash, to: target)
            removeStash(of: record)
            // Si Ferry había pegado una copia en el destino, se retira a la Papelera.
            if let d = record.destinationPath, fm.fileExists(atPath: d),
               PathSafety.isPlausibleDestination(d, name: record.name, home: Self.home) {
                try? fm.trashItem(at: URL(fileURLWithPath: d), resultingItemURL: nil)
            }
            history.removeAll { $0.id == record.id }
        } catch {
            alert(L("No se pudo devolver"), "\(record.name): \(error.localizedDescription)")
        }
    }

    private func purgeOldStash() {
        let limit = Date().addingTimeInterval(-Self.stashDays * 86_400)
        let old = history.filter { $0.date < limit }
        for r in old { removeStash(of: r) }
        if !old.isEmpty { history.removeAll { $0.date < limit } }
    }

    /// Borra la carpeta `Cortados/<uuid>` de un registro, solo si de verdad está dentro del stash.
    private func removeStash(of record: CutRecord) {
        guard Self.isValidStashEntry(record.stashPath) else { return }
        try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: record.stashPath).deletingLastPathComponent())
    }

    // MARK: Utilidades
    static func uniqueURL(in folder: URL, name: String) -> URL {
        let fm = FileManager.default
        var url = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    static func totalSize(_ url: URL) -> Int {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        var total = 0
        let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        while let f = e?.nextObject() as? URL {
            total += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    func alert(_ title: String, _ text: String) {
        DispatchQueue.main.async {
            let a = NSAlert()
            a.messageText = title
            a.informativeText = text
            a.runModal()
        }
    }

    func saveImage(_ data: Data) -> URL? {
        var png = data
        if let rep = NSBitmapImageRep(data: data), let converted = rep.representation(using: .png, properties: [:]) { png = converted }
        return Self.saveTemp(png, ext: "png", name: nil)
    }

    private static func saveTemp(_ data: Data, ext: String, name: String?) -> URL? {
        let dir = tempRoot
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var base = (name as NSString?)?.deletingPathExtension ?? ""
        base = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if base.isEmpty { base = "imagen-\(UUID().uuidString.prefix(6))" }
        let sub = dir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let url = sub.appendingPathComponent("\(base).\(ext)")
        do { try data.write(to: url); return url } catch { return nil }
    }
}
