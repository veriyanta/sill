import AppKit
import Combine
import SillCore
import SwiftUI
import UniformTypeIdentifiers

typealias ViewState<Value> = SwiftUI.State<Value>

let ink = Color(red: 0.074, green: 0.093, blue: 0.099)
let panel = Color(red: 0.106, green: 0.130, blue: 0.135)
let rule = Color.white.opacity(0.09)
let mint = Color(red: 0.70, green: 0.93, blue: 0.77)
let subdued = Color(red: 0.62, green: 0.70, blue: 0.69)

struct WorkspaceView: View {
    @Bindable var model: Workspace

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            GeometryReader { geometry in
                content(width: geometry.size.width)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(panel)
        .preferredColorScheme(.dark)
        .onAppear(perform: model.refreshVolumes)
        .onChange(of: model.showBrowser) { _, _ in model.fitWindowToImage() }
        .onChange(of: model.editPanel) { _, _ in model.fitWindowToImage() }
        .onChange(of: model.inspect) { _, _ in model.fitWindowToImage() }
        .onChange(of: model.preview.map { CGSize(width: $0.width, height: $0.height) }) { _, _ in
            model.fitWindowToImage()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            model.refreshVolumes()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            model.refreshVolumes()
        }
        .tint(mint)
        .dropDestination(for: URL.self) { files, _ in
            let urls = files.filter(\.isFileURL)
            guard !urls.isEmpty else { return false }
            model.openURLs(urls)
            return true
        }
        .sheet(item: $model.exportPresentation) { presentation in
            ExportSheet(model: model, batch: presentation.batch)
        }
        .alert("Sill", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.notice ?? "") }
    }

    private func content(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            if model.showBrowser {
                browser.frame(width: model.browserWidth(for: width))
                Rectangle().fill(rule).frame(width: 1)
            }
            ZStack {
                model.displayedImage == nil ? ink : panel
                if let image = model.displayedImage {
                    ImageCanvas(image: image, zoom: model.zoom, cropping: model.cropping,
                                onCrop: { model.cropBox = $0 }, onFit: { model.fitScale = $0 },
                                onZoom: model.changeZoom, onDraw: { model.diagnostics.firstDraw() })
                        .id(model.selected?.id)
                } else if let failure = model.viewFailure {
                    VStack(spacing: 13) {
                        Image(systemName: "exclamationmark.circle").font(.system(size: 34)).foregroundStyle(mint)
                        Text(failure).font(.headline).multilineTextAlignment(.center)
                        if model.assets.count > 1 { Button("Next Image") { model.move(1) } }
                    }.padding(28)
                } else if !model.busy { welcome }
                if model.busy || model.previewBusy {
                    ProgressView().controlSize(.small).padding(12)
                        .background(panel, in: RoundedRectangle(cornerRadius: 8))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(16)
                }
            }
            if model.editPanel {
                Rectangle().fill(rule).frame(width: 1)
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        icon("xmark", "Hide edit tools", action: model.toggleEditor)
                    }.padding(.trailing, 8).frame(height: 28)
                    ScrollView { EditorTools(model: model).padding(.horizontal, 15).padding(.bottom, 15) }
                }
                .frame(width: model.inspectorWidth(for: width))
                .background(panel)
            } else if model.inspect {
                Rectangle().fill(rule).frame(width: 1)
                inspector.frame(width: model.inspectorWidth(for: width))
            }
        }
    }

    private var toolbar: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            HStack(spacing: width < 420 ? 3 : 9) {
                if model.hasOpenPanels {
                    icon("rectangle.inset.filled", "Image only", action: model.showImageOnly)
                }
                if width >= 420 {
                    icon("sidebar.left", model.showBrowser ? "Hide browser" : "Show browser", action: model.toggleBrowser)
                    icon("photo.on.rectangle", "Open Images", action: model.pickFiles)
                    icon("folder", "Open Folder") { model.pickFolder() }
                }
                if width >= 205, model.selected != nil {
                    icon("chevron.left", "Previous image") { model.move(-1) }
                    icon("chevron.right", "Next image") { model.move(1) }
                }
                if width >= 235, let selected = model.selected {
                    Text(selected.name).lineLimit(1).font(.system(size: 12, weight: .medium))
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if width >= 520, model.picture != nil {
                    Text(zoomLabel).monospacedDigit().foregroundStyle(subdued)
                    icon("slider.horizontal.3", "Edit image", action: model.toggleEditor)
                    icon("info.circle", "Image information", action: model.toggleInspector)
                }
                if width >= 400, model.exporting {
                    ProgressView(value: Double(model.exportProgress), total: Double(model.exportTotal))
                        .controlSize(.small).frame(width: 38)
                }
                moreMenu
            }
            .padding(.leading, 75).padding(.trailing, 5)
            .frame(height: geometry.size.height)
        }
        .frame(height: model.toolbarHeight)
    }

    private var moreMenu: some View {
        Menu {
            Button("Open Images…", action: model.pickFiles)
            Button("Close Image", action: model.closeImage).disabled(model.selected == nil)
            Button("Open Folder…") { model.pickFolder() }
            if model.siblingSource != nil {
                Button("Browse Siblings…") { model.pickFolder(browseSiblings: true) }
            }
            Button(model.showBrowser ? "Hide Browser" : "Show Browser", action: model.toggleBrowser)
            Button("Image Only", action: model.showImageOnly)
            Divider()
            Button("Previous Image") { model.move(-1) }
            Button("Next Image") { model.move(1) }
            if let picture = model.picture {
                Text("\(position) · \(model.displayedImage?.width ?? picture.width) × \(model.displayedImage?.height ?? picture.height) · \(zoomLabel)")
                if picture.count > 1 {
                    Button("Previous Frame or Page") { model.loadFrame((picture.index + picture.count - 1) % picture.count) }
                    Button("Next Frame or Page") { model.loadFrame((picture.index + 1) % picture.count) }
                    if picture.kind == .animation {
                        Button(model.animating ? "Pause Animation" : "Play Animation", action: model.toggleAnimation)
                            .disabled(!model.edits.isEmpty)
                    }
                }
                Divider()
                Button("Fit") { model.zoom = nil; model.fitWindowToImage() }
                Button("Actual Pixels") { model.zoom = 1 }
                Button("Zoom In") { model.changeZoom(1.25) }
                Button("Zoom Out") { model.changeZoom(0.8) }
                Button("Edit Image", action: model.toggleEditor)
                Button(model.inspect ? "Hide Image Information" : "Show Image Information", action: model.toggleInspector)
            }
            Button(model.slideshow ? "Stop Slideshow" : "Start Slideshow", action: model.toggleSlideshow)
            Divider()
            if model.exporting {
                Button("Stop Export (\(model.exportProgress)/\(model.exportTotal))") { model.exportTask?.cancel() }
            } else {
                Button("Export Image…") { model.beginExport() }.disabled(model.picture == nil || model.previewBusy)
                Button("Batch Export…") { model.beginExport(batch: true) }.disabled(model.assets.isEmpty)
            }
        } label: {
            Image(systemName: "ellipsis.circle").accessibilityLabel("Image and window controls")
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var zoomLabel: String { "\(Int(((model.zoom ?? model.fitScale) * 100).rounded()))%" }

    private var welcome: some View {
        VStack(spacing: 15) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 39, weight: .ultraLight)).foregroundStyle(mint).accessibilityHidden(true)
            Text("Open an image").font(.system(size: 28, weight: .medium))
            Text("Drop images here or browse a folder.").foregroundStyle(subdued).font(.callout)
            HStack(spacing: 10) {
                Button("Open Images…", action: model.pickFiles).buttonStyle(.borderedProminent)
                    .tint(mint).foregroundStyle(ink)
                Button("Open Folder…") { model.pickFolder() }.buttonStyle(.bordered)
            }.padding(.top, 6)
        }
        .padding(25)
    }

    private var browser: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                folderBrowser.frame(height: min(260, max(84, geometry.size.height * 0.43)))
                Divider().overlay(rule)
                imageBrowser
            }
        }
        .background(panel)
    }

    private var folderBrowser: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Folders").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                icon("xmark", "Hide browser", action: model.toggleBrowser)
                if model.folderLocation != nil {
                    Menu {
                        ForEach(model.volumeLocations) { disk in
                            Button(disk.name) { model.openFolder(disk.url, fromSidebar: true) }
                        }
                    } label: {
                        Image(systemName: "internaldrive").accessibilityLabel("Disks")
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Switch disk")
                }
                if let folder = model.folderLocation, folder.path != "/" {
                    icon("arrow.up", "Parent folder") {
                        model.openFolder(folder.deletingLastPathComponent(), fromSidebar: true)
                    }
                }
                icon("folder.badge.plus", "Choose folder") { model.pickFolder() }
            }
            .padding(.horizontal, 13).frame(height: 34)
            Toggle("Include Subfolders", isOn: Binding(get: { model.includeSubfolders }, set: model.setIncludeSubfolders))
                .toggleStyle(.checkbox)
                .font(.caption)
                .padding(.horizontal, 13).padding(.bottom, 6)
                .disabled(model.folderLocation == nil || model.busy)
                .help("Browse images recursively, up to 4,096 files")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if let folder = model.folderLocation {
                        Label(folder.path == "/" ? "Startup Disk" : folder.lastPathComponent, systemImage: "folder.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(mint)
                            .lineLimit(1).padding(.horizontal, 8).help(folder.path)
                        ForEach(model.subfolders, id: \.self) { child in
                            locationRow(child, name: child.lastPathComponent, symbol: "folder")
                        }
                        if model.folderLoading {
                            ProgressView().controlSize(.small).padding(8)
                        } else if model.sidebarIssue {
                            Button("Allow Folder Access…") { model.pickFolder(startingAt: folder) }
                                .buttonStyle(.borderless).padding(8)
                        } else if model.subfolders.isEmpty {
                            Text("No subfolders").font(.caption).foregroundStyle(subdued).padding(8)
                        }
                    } else {
                        Text("Disks").font(.caption.weight(.semibold)).foregroundStyle(subdued)
                            .padding(.horizontal, 8).padding(.top, 4)
                        ForEach(model.volumeLocations) { disk in
                            locationRow(disk.url, name: disk.name, symbol: "internaldrive")
                        }
                    }
                }
                .padding(.horizontal, 7).padding(.bottom, 7)
            }
        }
    }

    private func locationRow(_ url: URL, name: String, symbol: String) -> some View {
        Button {
            model.openFolder(url, fromSidebar: true)
        } label: {
            Label(name, systemImage: symbol).lineLimit(1)
                .font(.system(size: 12))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(model.folderLocation?.path == url.path ? mint.opacity(0.15) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(url.path)
    }

    private var imageBrowser: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Images").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(model.assets.count.formatted()).monospacedDigit().foregroundStyle(subdued)
                Menu {
                    Button("Open Enclosing Folder in Finder") { model.openEnclosingFolder() }
                } label: {
                    Image(systemName: "ellipsis").accessibilityLabel("Image browser actions")
                }
                .menuIndicator(.hidden)
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(model.selected == nil && model.folderLocation == nil)
            }
            .padding(.horizontal, 14).padding(.vertical, 13)
            if model.assets.isEmpty {
                Text(model.folderLocation == nil ? "Your opened images will appear here." : "No images in this folder.").foregroundStyle(subdued)
                    .font(.callout).padding(.horizontal, 14).padding(.top, 8)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(model.assets) { asset in
                                Button { model.select(asset) } label: {
                                    HStack(spacing: 9) {
                                        Thumbnail(asset: asset, loader: model.thumbnails)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(asset.url.deletingPathExtension().lastPathComponent)
                                                .font(.system(size: 12, weight: .medium)).lineLimit(1)
                                            Text(asset.url.pathExtension.uppercased())
                                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                                .foregroundStyle(subdued)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(5).frame(maxWidth: .infinity)
                                    .background(model.selected == asset ? mint.opacity(0.15) : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 7))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).id(asset.id)
                                .accessibilityLabel(asset.name)
                                .accessibilityAddTraits(model.selected == asset ? .isSelected : [])
                                .contextMenu {
                                    Button("Open Enclosing Folder in Finder") {
                                        model.openEnclosingFolder(for: asset)
                                    }
                                }
                            }
                        }.padding(.horizontal, 8).padding(.bottom, 8)
                    }
                    .onChange(of: model.selected) { _, asset in
                        if let asset { proxy.scrollTo(asset.id) }
                    }
                }
            }
        }
        .background(panel)
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("Image Information").font(.headline)
                Spacer(minLength: 2)
                icon("xmark", "Hide image information", action: model.toggleInspector)
            }
            if let picture = model.picture {
                Text("\(picture.width) × \(picture.height) px").font(.title3.monospacedDigit()).foregroundStyle(mint)
                Text(UTType(picture.type)?.localizedDescription ?? picture.type).foregroundStyle(subdued)
                ScrollView {
                    Text(picture.metadata).font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else { Spacer() }
        }
        .padding(15)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(panel)
    }

    private var position: String {
        guard let selected = model.selected, let index = model.assets.firstIndex(of: selected) else {
            return "No image"
        }
        return "\(index + 1) / \(model.assets.count)"
    }

    func icon(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(minWidth: 19, minHeight: 19) }
            .buttonStyle(.borderless).help(label).accessibilityLabel(label)
    }
}

struct Thumbnail: View {
    let asset: Asset
    let loader: Thumbnails
    @ViewState private var bitmap: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(ink)
            if let bitmap {
                Image(decorative: bitmap, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "photo").foregroundStyle(subdued)
            }
        }
        .frame(width: 49, height: 39).clipShape(.rect(cornerRadius: 4))
        .task(id: asset) {
            bitmap = nil
            let image = await loader.load(asset)
            if !Task.isCancelled { bitmap = image }
        }
        .onDisappear { bitmap = nil }
        .accessibilityHidden(true)
    }
}
