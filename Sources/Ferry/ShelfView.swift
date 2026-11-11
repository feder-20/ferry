import SwiftUI

enum ShelfMetrics {
    static let width: CGFloat = 360
    static let height: CGFloat = 270
}

struct ShelfView: View {
    @ObservedObject var model: ShelfModel
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            header
            if model.showHistory {
                HistoryList(model: model)
            } else if model.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.doc").font(.system(size: 28))
                    Text("Suelta aquí archivos, texto o enlaces")
                        .font(.callout).foregroundStyle(.secondary)
                    Text(L("Pegar en la app activa: %@", Prefs.hotKeyLabel))
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 10)], spacing: 10) {
                        ForEach(model.items) { item in
                            ItemCell(model: model, item: item)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: ShelfMetrics.width, height: ShelfMetrics.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(model.isTargeted ? Color.accentColor : Color.primary.opacity(0.15),
                              lineWidth: model.isTargeted ? 3 : 1)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: model.showHistory ? "arrow.uturn.backward.circle" : "tray.fill")
            Text(model.showHistory ? L("Cortes recientes")
                 : (model.items.isEmpty ? L("Estantería") : L("Estantería · %d", model.items.count)))
                .font(.headline)
            Spacer()
            if !model.showHistory && !model.items.isEmpty {
                Button { model.toggleSelectAll() } label: {
                    Image(systemName: model.allSelected ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .buttonStyle(.borderless)
                .help(model.allSelected ? L("Quitar selección") : L("Seleccionar todo"))
                Button("Vaciar") { model.removeAll() }.buttonStyle(.borderless)
            }
            Button { model.showHistory.toggle() } label: {
                Image(systemName: model.showHistory ? "tray" : "clock.arrow.circlepath")
                    .overlay(alignment: .topTrailing) {
                        if !model.showHistory && !model.history.isEmpty {
                            Circle().fill(Color.accentColor).frame(width: 7, height: 7).offset(x: 3, y: -3)
                        }
                    }
            }
            .buttonStyle(.borderless)
            .help(model.showHistory ? L("Volver a la estantería") : L("Cortes recientes (devolver al origen)"))
            Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
        }
    }
}

// MARK: - Elemento de la estantería

private struct ItemCell: View {
    @ObservedObject var model: ShelfModel
    let item: ShelfItem
    @State private var hovering = false

    private var isSelected: Bool { model.selected.contains(item.id) }

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: item.icon)
                .resizable().scaledToFit()
                .frame(width: 48, height: 48)
            Text(item.title)
                .font(.caption).lineLimit(2).multilineTextAlignment(.center)
        }
        .frame(width: 84, height: 80)
        .padding(4)
        .background(isSelected ? Color.accentColor.opacity(0.25)
                    : (hovering ? Color.primary.opacity(0.08) : .clear),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
        )
        .overlay(DragSource(model: model, item: item))
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button { model.remove(item) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help(L("Quitar de la estantería (el archivo sigue en su origen)"))
            }
        }
        .onHover { hovering = $0 }
        .help(item.title)
    }
}

// MARK: - Cortes recientes

private struct HistoryList: View {
    @ObservedObject var model: ShelfModel

    var body: some View {
        if model.history.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 26))
                Text("Aún no has cortado ningún archivo")
                    .font(.callout).foregroundStyle(.secondary)
                Text(L("Aquí podrás devolverlos a su origen durante %d días", Int(ShelfModel.stashDays)))
                    .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(model.history) { rec in
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: rec.stashPath))
                                .resizable().frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(rec.name).font(.callout).lineLimit(1)
                                Text("\(folderName(rec)) · \(relative(rec.date))")
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Button("Devolver") { model.restore(rec) }
                                .controlSize(.small)
                                .help(L("Devolver al origen: %@", rec.originalPath))
                        }
                    }
                }
            }
        }
    }

    private func folderName(_ r: CutRecord) -> String {
        URL(fileURLWithPath: r.originalPath).deletingLastPathComponent().lastPathComponent
    }
    private func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}

// MARK: - Origen de arrastre nativo

private struct DragSource: NSViewRepresentable {
    let model: ShelfModel
    let item: ShelfItem

    func makeNSView(context: Context) -> DragSourceView {
        let v = DragSourceView()
        v.model = model; v.item = item
        return v
    }
    func updateNSView(_ v: DragSourceView, context: Context) {
        v.model = model; v.item = item
    }
}

/// Un clic selecciona; arrastrar saca el elemento (o todos los seleccionados) hacia otra app.
final class DragSourceView: NSView, NSDraggingSource {
    var model: ShelfModel?
    var item: ShelfItem?
    private var group: [ShelfItem] = []
    private var downEvent: NSEvent?
    private var busy: [String] = []

    override var mouseDownCanMoveWindow: Bool { false } // arrastra el archivo, no la ventana
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { downEvent = event }

    override func mouseUp(with event: NSEvent) {
        if downEvent != nil, let item { model?.toggleSelect(item.id) }
        downEvent = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model, let item, let down = downEvent else { return }
        downEvent = nil
        group = model.dragItems(for: item)
        ImageConverter.dragChoice = nil
        let imageCount = group.filter { if case .file(let u) = $0.content { return u.isImageFile } else { return false } }.count
        var dragItems: [NSDraggingItem] = []
        busy = []
        for (i, it) in group.enumerated() {
            var writer = it.pasteboardWriter
            if ImageConverter.askOnDrop, case .file(let u) = it.content, u.isImageFile {
                let path = u.path
                model.busyPaths.insert(path)
                busy.append(path)
                writer = ImagePromiseDelegate.provider(source: u, total: imageCount) { [weak model] in
                    model?.busyPaths.remove(path)
                }
            }
            let d = NSDraggingItem(pasteboardWriter: writer)
            let off = CGFloat(min(i, 5)) * 6 // apiladas
            d.setDraggingFrame(NSRect(x: bounds.midX - 24 + off, y: bounds.midY - 24 - off, width: 48, height: 48),
                               contents: it.icon)
            dragItems.append(d)
        }
        beginDraggingSession(with: dragItems, event: down, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Siempre "copiar": así Ferry controla el corte y puede devolver el original.
        context == .outsideApplication ? [.copy] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        guard !operation.isEmpty else {
            for p in busy { model?.busyPaths.remove(p) } // soltado en ningún sitio: nada que entregar
            return
        }
        let done = group
        DispatchQueue.main.async { [weak self] in self?.model?.finishCut(done) }
    }
}
