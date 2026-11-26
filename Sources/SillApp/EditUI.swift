import AppKit
import SillCore
import SwiftUI

extension Workspace {
    var canEdit: Bool { picture != nil && !busy && !previewBusy && !animating }
    var displayedImage: CGImage? { preview ?? picture?.image }

    func clearEdits() {
        previewTask?.cancel()
        previewRevision += 1
        previewBusy = false
        edits = []
        redo = []
        preview = nil
        cropping = false
        cropBox = .zero
    }

    func apply(_ edit: Edit) {
        guard canEdit else { return }
        edits.append(edit)
        redo.removeAll()
        cropping = false
        renderPreview()
    }

    func undoEdit() {
        guard !previewBusy, let previous = edits.popLast() else { return }
        redo.append(previous)
        renderPreview()
    }

    func redoEdit() {
        guard !previewBusy, let next = redo.popLast() else { return }
        edits.append(next)
        renderPreview()
    }

    func renderPreview() {
        previewTask?.cancel()
        previewRevision += 1
        let revision = previewRevision
        guard let picture, !edits.isEmpty else { preview = nil; previewBusy = false; return }
        let recipe = edits
        previewBusy = true
        previewTask = Task {
            defer { if revision == previewRevision { previewBusy = false } }
            do {
                let image = try await pipeline.preview(picture, edits: recipe)
                if !Task.isCancelled, revision == previewRevision { preview = image }
            } catch is CancellationError {
            } catch {
                if revision == previewRevision {
                    notice = error.localizedDescription
                    clearEdits()
                }
            }
        }
    }

    func beginExport(batch: Bool = false) {
        guard !exporting else { return }
        if batch {
            guard !assets.isEmpty else { return }
        } else {
            guard selected != nil, picture != nil, !previewBusy else { return }
        }
        if slideshow { toggleSlideshow() }
        stopAnimation()
        exportPresentation = ExportPresentation(batch: batch)
    }

    func chooseDestination() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = folderLocation ?? selected?.url.deletingLastPathComponent()
        panel.prompt = "Choose"
        panel.message = "Choose the folder where Sill should write the output."
        return panel.runModal() == .OK ? panel.url : nil
    }

    func confirmOverwrite() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Replace existing files?"
        alert.informativeText = "Files with the same name in the destination folder will be replaced. This action can’t be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Replace Files")
        return alert.runModal() == .alertSecondButtonReturn
    }

    func startExport(folder: URL, batch: Bool, stem: String, naming: BatchNaming,
                     options: ExportOptions, recipe: [Edit]) {
        let inputs = batch ? assets : selected.map { [$0] } ?? []
        let index = picture?.index ?? 0
        guard let input = inputs.first else { return }
        exportPresentation = nil
        exporting = true
        exportProgress = 0
        exportTotal = inputs.count
        exportTask = Task {
            let result = ExportSummary()
            defer {
                exporting = false
                exportTask = nil
                notice = result.message(total: inputs.count, stopped: Task.isCancelled)
            }
            do {
                if batch {
                    try await pipeline.batch(inputs, to: folder, naming: naming, edits: recipe, options: options) { event in
                        await self.report(event, to: result)
                    }
                } else {
                    let ext = options.format.filename(extensionOf: input)
                    let filename = ext.isEmpty ? stem : "\(stem).\(ext)"
                    let output = try await pipeline.export(input, to: folder, named: filename, index: index,
                                                           edits: recipe, options: options)
                    if let output {
                        report(.written(input, output), to: result)
                        result.filename = output.lastPathComponent
                        if output.standardizedFileURL == input.url.standardizedFileURL {
                            await thumbnails.clear()
                            if selected == input { loadFrame(0) }
                        }
                    } else { report(.skipped(input), to: result) }
                }
            } catch is CancellationError {
            } catch {
                result.failed += 1
                result.errors.append(error.localizedDescription)
            }
        }
    }

    private func report(_ event: BatchEvent, to result: ExportSummary) {
        switch event {
        case .written: result.written += 1
        case .skipped: result.skipped += 1
        case .failed(let input, let reason):
            result.failed += 1
            if result.errors.count < 8 { result.errors.append("\(input.name) — \(reason)") }
        }
        exportProgress += 1
    }
}

@MainActor
private final class ExportSummary {
    var written = 0
    var skipped = 0
    var failed = 0
    var errors: [String] = []
    var filename: String?

    func message(total: Int, stopped: Bool) -> String {
        let heading = stopped ? "Stopped after \(written + skipped + failed) of \(total)." : "Export finished."
        let counts = "\(written) written · \(skipped) skipped · \(failed) failed"
        let more = failed > errors.count ? ["…and \(failed - errors.count) more."] : []
        return ([heading, counts] + errors + more + (filename.map { [$0] } ?? [])).joined(separator: "\n")
    }
}

struct ExportPresentation: Identifiable {
    let id = UUID()
    let batch: Bool
}

struct EditorTools: View {
    @Bindable var model: Workspace
    @ViewState private var longEdge = ""
    @ViewState private var exposure = 0.0
    @ViewState private var contrast = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("Edit Image").font(.headline)
                Spacer()
                Button("Reset", action: model.clearEdits).buttonStyle(.borderless).disabled(model.edits.isEmpty)
            }
            HStack {
                tool("rotate.left", "Rotate left") { model.apply(.rotateLeft) }
                tool("rotate.right", "Rotate right") { model.apply(.rotateRight) }
                tool("arrow.left.and.right.righttriangle.left.righttriangle.right", "Flip horizontally") {
                    model.apply(.flipHorizontal)
                }
                tool("arrow.up.and.down.righttriangle.up.righttriangle.down", "Flip vertically") {
                    model.apply(.flipVertical)
                }
            }
            Toggle("Crop", isOn: $model.cropping).toggleStyle(.switch).controlSize(.small)
                .onChange(of: model.cropping) { _, _ in model.cropBox = .zero }
            if model.cropping {
                Text("Drag over the image to select an area.").font(.caption).foregroundStyle(subdued)
                Button("Apply Crop") { model.apply(.crop(model.cropBox)) }.disabled(model.cropBox.isEmpty)
            }
            Divider()
            Text("Resize").font(.subheadline.bold())
            HStack {
                TextField("Long edge in pixels", text: $longEdge).textFieldStyle(.roundedBorder)
                Button("Apply") {
                    if let edge = Int(longEdge) { model.apply(.resize(maxEdge: edge)) }
                }
                .disabled(!(1...32_768).contains(Int(longEdge) ?? 0))
            }
            Divider()
            Text("Adjust").font(.subheadline.bold())
            HStack { Text("Brightness"); Spacer(); Text(exposure.formatted(.number.precision(.fractionLength(2)))) }
                .font(.caption).foregroundStyle(subdued)
            Slider(value: $exposure, in: -1...1).accessibilityLabel("Brightness")
            HStack { Text("Contrast"); Spacer(); Text(contrast.formatted(.number.precision(.fractionLength(2)))) }
                .font(.caption).foregroundStyle(subdued)
            Slider(value: $contrast, in: 0.25...4).accessibilityLabel("Contrast")
            Button("Apply Adjustments") {
                var changes: [Edit] = []
                if exposure != 0 { changes.append(.brightness(exposure)) }
                if contrast != 1 { changes.append(.contrast(contrast)) }
                model.edits.append(contentsOf: changes)
                model.redo.removeAll()
                model.renderPreview()
                exposure = 0
                contrast = 1
            }.disabled(exposure == 0 && contrast == 1)
            Button("Grayscale") { model.apply(.grayscale) }
            Divider()
            HStack {
                Button("Undo", action: model.undoEdit).disabled(model.edits.isEmpty)
                Button("Redo", action: model.redoEdit).disabled(model.redo.isEmpty)
            }
        }
        .disabled(!model.canEdit)
    }

    private func tool(_ symbol: String, _ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 28, height: 24) }
            .help(name).accessibilityLabel(name)
    }
}

struct ExportSheet: View {
    let model: Workspace
    let batch: Bool
    @Environment(\.dismiss) private var dismiss
    @ViewState private var format: ExportFormat = .png
    @ViewState private var quality = 0.9
    @ViewState private var metadata = false
    @ViewState private var collision: Collision = .keepBoth
    @ViewState private var allImages = false
    @ViewState private var filename = ""
    @ViewState private var prefix = "Sill-"
    @ViewState private var numbered = false
    @ViewState private var useEdits = false
    @ViewState private var resize = ""
    @ViewState private var folder: URL?

    private var recipes: [Edit] {
        var edits = !batch || useEdits ? model.edits : []
        if batch, let edge = Int(resize) { edits.append(.resize(maxEdge: edge)) }
        return edits
    }

    private var invalid: Bool {
        folder == nil || (!batch && filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            || (batch && format != .original && !resize.isEmpty && !(1...32_768).contains(Int(resize) ?? 0))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(batch ? "Batch Export" : "Export Image").font(.title2.bold())
            if batch { Text("\(model.assets.count) images in browser order").foregroundStyle(subdued) }
            Grid(alignment: .leading, horizontalSpacing: 15, verticalSpacing: 12) {
                if batch {
                    GridRow { Text("Prefix"); TextField("Optional", text: $prefix) }
                    GridRow { Text("Naming"); Toggle("Number sequentially from 1", isOn: $numbered) }
                    if format != .original {
                        GridRow { Text("Long edge"); TextField("Keep original size", text: $resize) }
                        if !model.edits.isEmpty {
                            GridRow { Text("Edits"); Toggle("Apply current edits to each image", isOn: $useEdits) }
                        }
                    }
                } else { GridRow { Text("Name"); TextField("File name without extension", text: $filename) } }
                GridRow {
                    Text("Format")
                    Picker("Format", selection: $format) {
                        ForEach(ExportFormat.allCases.filter(\.available)) { Text($0.label).tag($0) }
                    }.labelsHidden()
                }
                if format == .jpeg || format == .heic {
                    GridRow {
                        Text("Quality")
                        HStack {
                            Slider(value: $quality, in: 0...1).accessibilityLabel("Quality")
                            Text(quality.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                        }
                    }
                }
                if format != .original {
                    GridRow { Text("Metadata"); Toggle("Keep supported camera fields and GPS", isOn: $metadata) }
                    if batch || (model.picture?.count ?? 0) > 1 {
                        GridRow { Text("Sequence"); Toggle(batch ? "Export every frame or page" : "Export all frames or pages",
                                                           isOn: $allImages) }
                    }
                } else if !recipes.isEmpty {
                    GridRow { Text(""); Text("Exact copies use the source bytes and omit pending edits.").foregroundStyle(subdued) }
                }
                GridRow {
                    Text("Existing files")
                    Picker("Existing files", selection: $collision) {
                        ForEach(Collision.allCases) { Text($0.label).tag($0) }
                    }.labelsHidden()
                }
                GridRow {
                    Text("Destination")
                    HStack {
                        if let folder { Text(folder.lastPathComponent).lineLimit(1).foregroundStyle(subdued) }
                        Button("Choose Folder…") { if let choice = model.chooseDestination() { folder = choice } }
                    }
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export") {
                    guard let folder, collision != .overwrite || model.confirmOverwrite() else { return }
                    model.startExport(folder: folder, batch: batch, stem: filename,
                                      naming: BatchNaming(prefix: prefix, sequential: numbered),
                                      options: ExportOptions(format: format, quality: quality, preserveMetadata: metadata,
                                                             collision: collision, allImages: allImages),
                                      recipe: format == .original ? [] : recipes)
                }.keyboardShortcut(.defaultAction).disabled(invalid)
            }
        }
        .padding(24).frame(width: 520)
        .onAppear {
            if let asset = model.selected { filename = asset.url.deletingPathExtension().lastPathComponent + "-copy" }
        }
    }
}
