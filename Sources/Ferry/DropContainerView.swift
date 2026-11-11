import AppKit

/// Destino de arrastre a nivel AppKit: lee el pasteboard completo para recibir
/// archivos reales o "promesas de archivo" con su NOMBRE ORIGINAL.
final class DropContainerView: NSView {
    private let model: ShelfModel

    init(model: ShelfModel, content: NSView) {
        self.model = model
        super.init(frame: content.frame)
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        var types: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string, .png, .tiff]
        types += NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes(types)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard TrialManager.shared.allowsFeatures else { return [] } // prueba vencida: no acepta soltados
        model.isTargeted = true
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { model.isTargeted = false }
    override func draggingEnded(_ sender: NSDraggingInfo) { model.isTargeted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        model.isTargeted = false
        guard TrialManager.shared.allowsFeatures else { return false }
        let pb = sender.draggingPasteboard

        // 1) Archivos reales: se guarda la ruta, el nombre no cambia.
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            urls.forEach { model.add(.file($0)) }
            return true
        }
        // 2) Promesas de archivo: el origen crea el archivo con su nombre original.
        if let receivers = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !receivers.isEmpty {
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("Ferry", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            for r in receivers {
                r.receivePromisedFiles(atDestination: dest, options: [:], operationQueue: .main) { [weak self] url, error in
                    if error == nil { self?.model.add(.file(url)) }
                }
            }
            return true
        }
        // 3) Enlaces web.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            urls.forEach { model.add($0.isFileURL ? .file($0) : .webURL($0)) }
            return true
        }
        // 4) Imagen sin nombre (el origen no da archivo ni nombre).
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
           let url = model.saveImage(data) {
            model.add(.file(url))
            return true
        }
        // 5) Texto.
        if let text = pb.string(forType: .string), !text.isEmpty {
            model.add(.text(text))
            return true
        }
        return false
    }
}
