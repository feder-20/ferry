import AppKit
import Carbon.HIToolbox

/// Preferencias de Ferry (se guardan en UserDefaults).
enum Placement: Int, CaseIterable {
    case auto = 0, cursor, right, left, center
}

enum Prefs {
    static let changed = Notification.Name("FerryPrefsChanged")
    private static let d = UserDefaults.standard

    /// Segundos para recoger la estantería vacía; 0 = nunca.
    static var autoHide: Double {
        get { d.object(forKey: "autoHideSeconds") as? Double ?? 10 }
        set { d.set(newValue, forKey: "autoHideSeconds"); notify() }
    }

    static var placement: Placement {
        get { Placement(rawValue: d.object(forKey: "placement") as? Int ?? 0) ?? .auto }
        set { d.set(newValue.rawValue, forKey: "placement"); notify() }
    }

    /// 0 = baja, 1 = media, 2 = alta
    static var shakeSensitivity: Int {
        get { d.object(forKey: "shakeSensitivity") as? Int ?? 1 }
        set { d.set(newValue, forKey: "shakeSensitivity"); notify() }
    }

    /// (cambios de dirección necesarios, recorrido mínimo en px)
    static var shakeParams: (reversals: Int, travel: CGFloat) {
        switch shakeSensitivity {
        case 0: return (4, 35)
        case 2: return (2, 18)
        default: return (3, 25)
        }
    }

    // Atajo de pegado
    static let defaultKeyCode = 9 // V
    static let defaultModifiers = controlKey | optionKey | cmdKey
    static var hotKeyCode: Int {
        get { d.object(forKey: "hotKeyCode") as? Int ?? defaultKeyCode }
        set { d.set(newValue, forKey: "hotKeyCode") }
    }
    static var hotKeyModifiers: Int {
        get { d.object(forKey: "hotKeyModifiers") as? Int ?? defaultModifiers }
        set { d.set(newValue, forKey: "hotKeyModifiers") }
    }
    static var hotKeyKey: String {
        get { d.string(forKey: "hotKeyKey") ?? "V" }
        set { d.set(newValue, forKey: "hotKeyKey") }
    }
    static func setHotKey(code: Int, modifiers: Int, key: String) {
        hotKeyCode = code; hotKeyModifiers = modifiers; hotKeyKey = key; notify()
    }
    static func resetHotKey() {
        setHotKey(code: defaultKeyCode, modifiers: defaultModifiers, key: "V")
    }

    /// Texto del atajo, p. ej. "⌃⌥⌘V".
    static var hotKeyLabel: String {
        modifierSymbols(hotKeyModifiers) + hotKeyKey
    }

    static func modifierSymbols(_ m: Int) -> String {
        (m & controlKey != 0 ? "⌃" : "") + (m & optionKey != 0 ? "⌥" : "")
            + (m & shiftKey != 0 ? "⇧" : "") + (m & cmdKey != 0 ? "⌘" : "")
    }

    static func carbonModifiers(_ f: NSEvent.ModifierFlags) -> Int {
        (f.contains(.control) ? controlKey : 0) | (f.contains(.option) ? optionKey : 0)
            | (f.contains(.shift) ? shiftKey : 0) | (f.contains(.command) ? cmdKey : 0)
    }

    static func nsModifiers(_ m: Int) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if m & controlKey != 0 { f.insert(.control) }
        if m & optionKey != 0 { f.insert(.option) }
        if m & shiftKey != 0 { f.insert(.shift) }
        if m & cmdKey != 0 { f.insert(.command) }
        return f
    }

    private static func notify() {
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

/// Texto traducido (las claves están en español; ver en.lproj).
func L(_ key: String, _ args: CVarArg...) -> String {
    let s = NSLocalizedString(key, comment: "")
    return args.isEmpty ? s : String(format: s, arguments: args)
}
