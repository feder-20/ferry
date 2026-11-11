import Foundation

/// Lógica pura (sin AppKit) para validar rutas y decidir qué se puede hacer con ellas.
enum PathSafety {
    enum BringError: Error, Equatable {
        case notAbsolute, notFound, notDirectory, notWritable, forbidden
    }

    /// Carpetas del sistema cuyo contenido (y subcarpetas) nunca puede ser destino.
    static let systemRoots = ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin",
                              "/etc", "/private", "/var", "/dev", "/opt", "/cores"]
    /// Carpetas que se rechazan solo si son exactamente ellas (sus subcarpetas sí valen).
    static let exactOnly = ["/", "/Volumes", "/Users"]

    /// Ruta estandarizada con symlinks resueltos (realpath). Si el final no existe, se resuelve
    /// el ancestro existente más profundo y se añade el resto. (No se usa `resolvingSymlinksInPath`
    /// porque Foundation recorta `/private`, y /tmp se vería distinto de /private/tmp.)
    static func resolve(_ path: String) -> String {
        var current = URL(fileURLWithPath: path).standardizedFileURL.path
        var rest: [String] = []
        while true {
            if let rp = realpath(current, nil) {
                defer { free(rp) }
                let base = String(cString: rp)
                return rest.reversed().reduce(base) { $0 == "/" ? "/" + $1 : $0 + "/" + $1 }
            }
            if current == "/" { return current }
            rest.append((current as NSString).lastPathComponent)
            current = (current as NSString).deletingLastPathComponent
        }
    }

    /// `path` (resuelto) está estrictamente dentro de `base` (resuelto): prefijo `base + "/"`.
    static func isInside(_ path: String, base: String) -> Bool {
        let p = resolve(path), b = resolve(base)
        return p != b && p.hasPrefix(b == "/" ? "/" : b + "/")
    }

    /// ¿Ruta protegida? (comprueba la forma literal y la resuelta de cada raíz)
    static func isForbidden(_ path: String, home: URL, systemRoots roots: [String] = systemRoots) -> Bool {
        let p = resolve(path)
        let h = resolve(home.path)
        let protected = roots + [h + "/Library", h + "/.ssh"]
        for r in protected {
            for cand in Set([r, resolve(r)]) where p == cand || p.hasPrefix(cand + "/") { return true }
        }
        if exactOnly.contains(p) { return true }
        // Cualquier carpeta oculta (configuración: .ssh, .config, .zshrc.d…)
        if p.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return true }
        return false
    }

    /// Valida la carpeta destino de `ferry://bring`. Devuelve la URL ya resuelta.
    static func validateBringPath(_ raw: String,
                                  home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                  systemRoots roots: [String] = systemRoots) -> Result<URL, BringError> {
        guard raw.hasPrefix("/"), !raw.contains("\0") else { return .failure(.notAbsolute) }
        let resolved = resolve(raw)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir) else { return .failure(.notFound) }
        guard isDir.boolValue else { return .failure(.notDirectory) }
        if isForbidden(resolved, home: home, systemRoots: roots) { return .failure(.forbidden) }
        guard FileManager.default.isWritableFile(atPath: resolved) else { return .failure(.notWritable) }
        return .success(URL(fileURLWithPath: resolved, isDirectory: true))
    }

    /// Extrae `path` de `ferry://bring?path=…`; nil si no es esa URL.
    static func bringPath(from url: URL) -> String? {
        guard url.scheme == "ferry", url.host == "bring" else { return nil }
        let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "path" })?.value
        guard let v, !v.isEmpty else { return nil }
        return v
    }

    // MARK: Historial de cortes (estado.json no es de fiar)

    /// El elemento cortado vive en `Cortados/<uuid>/<archivo>`: dentro de la carpeta y con carpeta propia.
    static func isValidStashEntry(_ stashPath: String, stashDir: String) -> Bool {
        let parent = (stashPath as NSString).deletingLastPathComponent
        return isInside(stashPath, base: stashDir) && isInside(parent, base: stashDir)
    }

    /// El destino pegado debe parecerse a una copia del elemento (mismo nombre, quizá con « N») y no ser ruta protegida.
    static func isPlausibleDestination(_ dest: String, name: String, home: URL,
                                       systemRoots roots: [String] = systemRoots) -> Bool {
        guard dest.hasPrefix("/"), !isForbidden(dest, home: home, systemRoots: roots) else { return false }
        let leaf = (dest as NSString).lastPathComponent
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        if leaf == name { return true }
        let suffix = ext.isEmpty ? "" : "." + ext
        guard leaf.hasPrefix(base + " "), leaf.hasSuffix(suffix) else { return false }
        let mid = leaf.dropFirst(base.count + 1).dropLast(suffix.count)
        return !mid.isEmpty && mid.allSatisfy(\.isNumber)
    }

    static func isValidOriginal(_ original: String, name: String, home: URL,
                                systemRoots roots: [String] = systemRoots) -> Bool {
        original.hasPrefix("/") && (original as NSString).lastPathComponent == name
            && !isForbidden(original, home: home, systemRoots: roots)
    }
}

/// Origen de una entrega: las que llegan por URL (`ferry://`) son solo copia.
enum DeliveryOrigin { case user, url }

enum DeliveryPolicy {
    static func shouldCut(moveMode: Bool, origin: DeliveryOrigin) -> Bool {
        origin == .user && moveMode
    }
}

/// Reglas del portapapeles (⌘V automático).
enum PasteboardPolicy {
    static let transientType = "org.nspasteboard.TransientType"
    static let concealedType = "org.nspasteboard.ConcealedType"

    /// Los elementos «concealed» (contraseñas de gestores) no se copian al respaldo.
    static func isRestorable(types: [String]) -> Bool { !types.contains(concealedType) }

    /// Solo se restaura si nadie más ha escrito en el portapapeles desde que Ferry lo hizo.
    static func shouldRestore(currentChangeCount: Int, ourChangeCount: Int) -> Bool {
        currentChangeCount == ourChangeCount
    }
}
