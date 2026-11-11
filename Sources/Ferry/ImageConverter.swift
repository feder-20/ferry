import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Conversión de imágenes al soltarlas en otra app (HEIC/PNG/TIFF → JPG, → PNG, reducir tamaño).
enum ImageChoice {
    case original, jpg, png, reduced

    var ext: String? {
        switch self {
        case .original: return nil
        case .jpg, .reduced: return "jpg"
        case .png: return "png"
        }
    }
}

enum ImageConverter {
    static let askKey = "askImageOnDrop"
    static var askOnDrop: Bool {
        get { UserDefaults.standard.object(forKey: askKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: askKey) }
    }

    /// Lado mayor al "Reducir tamaño" (píxeles).
    static let reducedMaxSide = 1600

    /// Respuesta dada durante el arrastre actual (se pregunta una sola vez por arrastre).
    static var dragChoice: ImageChoice?

    /// Pregunta qué hacer con las imágenes de este arrastre. Debe llamarse desde el hilo principal.
    static func askUser(sample: String, count: Int) -> ImageChoice {
        if let c = dragChoice { return c }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = count > 1 ? L("¿Cómo quieres entregar las imágenes?") : L("¿Cómo quieres entregar la imagen?")
        a.informativeText = count > 1 ? L("%@ y otras %d. La elección se aplica a todas.", sample, count - 1)
                                      : sample
        a.addButton(withTitle: L("Original"))
        a.addButton(withTitle: L("Convertir a JPG"))
        a.addButton(withTitle: L("Convertir a PNG"))
        a.addButton(withTitle: L("Reducir tamaño (JPG, %d px)", reducedMaxSide))
        let choice: ImageChoice
        switch a.runModal() {
        case .alertSecondButtonReturn: choice = .jpg
        case .alertThirdButtonReturn: choice = .png
        case NSApplication.ModalResponse(rawValue: 1003): choice = .reduced
        default: choice = .original
        }
        dragChoice = choice
        return choice
    }

    static func outputName(for source: URL, choice: ImageChoice) -> String {
        guard let ext = choice.ext else { return source.lastPathComponent }
        return source.deletingPathExtension().lastPathComponent + "." + ext
    }

    /// Escribe la imagen (convertida o tal cual) en `dest`.
    static func write(_ source: URL, to dest: URL, choice: ImageChoice) throws {
        let fm = FileManager.default
        if choice == .original {
            try fm.copyItem(at: source, to: dest)
            return
        }
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil) else { throw ConvError.read }
        let image: CGImage?
        if choice == .reduced {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: reducedMaxSide,
            ]
            image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        } else {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 20_000, // sin reducir en la práctica
            ]
            image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }
        guard let image else { throw ConvError.read }
        let type: UTType = choice == .png ? .png : .jpeg
        guard let out = CGImageDestinationCreateWithURL(dest as CFURL, type.identifier as CFString, 1, nil)
        else { throw ConvError.write }
        var props: [CFString: Any] = [:]
        if type == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = choice == .reduced ? 0.7 : 0.9 }
        CGImageDestinationAddImage(out, image, props as CFDictionary)
        guard CGImageDestinationFinalize(out) else { throw ConvError.write }
    }

    enum ConvError: LocalizedError {
        case read, write
        var errorDescription: String? {
            switch self {
            case .read: return L("No se pudo leer la imagen.")
            case .write: return L("No se pudo guardar la imagen convertida.")
            }
        }
    }
}

/// Delegado de la promesa: al soltar, Ferry pregunta y entrega la versión elegida.
final class ImagePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    private let source: URL
    private let total: Int
    private let onFinished: () -> Void
    private var choice: ImageChoice = .original

    init(source: URL, total: Int, onFinished: @escaping () -> Void) {
        self.source = source
        self.total = total
        self.onFinished = onFinished
    }

    /// Crea la promesa; el proveedor guarda al delegado en `userInfo` para mantenerlo vivo.
    static func provider(source: URL, total: Int, onFinished: @escaping () -> Void) -> NSFilePromiseProvider {
        let d = ImagePromiseDelegate(source: source, total: total, onFinished: onFinished)
        let type = (try? source.resourceValues(forKeys: [.contentTypeKey]).contentType)?.identifier
            ?? UTType.image.identifier
        let p = NSFilePromiseProvider(fileType: type, delegate: d)
        p.userInfo = d
        return p
    }

    private lazy var queue: OperationQueue = {
        let q = OperationQueue(); q.qualityOfService = .userInitiated; return q
    }()

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }

    func filePromiseProvider(_ p: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        let src = source, n = total
        var picked = ImageChoice.original
        DispatchQueue.main.sync { picked = ImageConverter.askUser(sample: src.lastPathComponent, count: n) }
        choice = picked
        return ImageConverter.outputName(for: source, choice: picked)
    }

    func filePromiseProvider(_ p: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        defer { DispatchQueue.main.async { [onFinished] in onFinished() } }
        do {
            try? FileManager.default.removeItem(at: url)
            try ImageConverter.write(source, to: url, choice: choice)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}
