import AppKit
import SillCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class OpenRouter: NSObject, NSApplicationDelegate {
    weak var model: Workspace?
    private var pending: [URL] = []
    private var viewerKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        viewerKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let model = self?.model, model.handleViewerKey(event) else { return event }
            return nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let viewerKeyMonitor { NSEvent.removeMonitor(viewerKeyMonitor) }
    }

    func connect(_ model: Workspace) {
        self.model = model
        if !pending.isEmpty {
            model.openURLs(pending)
            pending.removeAll()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let model { model.openURLs(urls) } else { pending.append(contentsOf: urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct SillApp: App {
    @NSApplicationDelegateAdaptor(OpenRouter.self) private var delegate
    @ViewState private var model = Workspace()

    var body: some Scene {
        Window("", id: "workspace") {
            WorkspaceView(model: model)
                .frame(minWidth: Workspace.minimumWindow.width, minHeight: Workspace.minimumWindow.height)
                .background(WindowProbe { model.attachWindow($0) })
                .onAppear { delegate.connect(model) }
        }
        .defaultSize(width: 1160, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…", action: model.pickFiles).keyboardShortcut("o")
                Button("Close Image", action: model.closeImage).disabled(model.selected == nil)
                Menu("Open Recent") {
                    ForEach(model.recents) { recent in
                        Button(recent.name) { model.openRecent(recent) }.help(recent.displayPath)
                    }
                    Divider()
                    Button("Clear Menu", action: model.clearRecents)
                }.disabled(model.recents.isEmpty)
                Button("Open Folder…", action: { model.pickFolder() }).keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Reopen Remembered Folder", action: model.reopenFolder)
                    .disabled(!model.hasBookmark)
                Button("Browse Siblings…") { model.pickFolder(browseSiblings: true) }
                    .disabled(model.siblingSource == nil)
                Button("Forget Remembered Folder", action: model.forgetFolder)
                    .disabled(!model.hasBookmark)
            }
            CommandGroup(after: .saveItem) {
                Button("Export Image…") { model.beginExport() }.keyboardShortcut("e")
                    .disabled(model.picture == nil || model.exporting || model.previewBusy)
                Button("Batch Export…") { model.beginExport(batch: true) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.assets.isEmpty || model.exporting)
            }
            CommandGroup(replacing: .printItem) {
                Button("Print Image…", action: model.printImage).keyboardShortcut("p")
                    .disabled(model.displayedImage == nil)
            }
            CommandGroup(after: .pasteboard) {
                Button("Copy Image", action: model.copyImage).keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(model.displayedImage == nil)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo Image Edit", action: model.undoEdit).keyboardShortcut("z")
                    .disabled(model.edits.isEmpty || model.previewBusy)
                Button("Redo Image Edit", action: model.redoEdit)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(model.redo.isEmpty || model.previewBusy)
            }
            CommandGroup(after: .toolbar) {
                Button(model.showBrowser ? "Hide Browser" : "Show Browser", action: model.toggleBrowser)
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Button(model.inspect ? "Hide Image Information" : "Show Image Information", action: model.toggleInspector)
                    .keyboardShortcut("i")
                Button("Image Only", action: model.showImageOnly)
                    .keyboardShortcut("0", modifiers: [.command, .shift])
                Divider()
                Button("Viewer Diagnostics", action: model.showDiagnostics)
            }
            CommandMenu("Image") {
                Button("Previous Image") { model.move(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("Next Image") { model.move(1) }.keyboardShortcut(.rightArrow, modifiers: [])
                Divider()
                Button("Enter or Exit Full Screen", action: model.toggleFullScreen)
                    .keyboardShortcut("f", modifiers: [.control, .command])
                Button("Fit to Window") { model.zoom = nil; model.fitWindowToImage() }.keyboardShortcut("0")
                Button("Actual Pixels") { model.zoom = 1 }.keyboardShortcut("1")
                Button("Zoom In") { model.changeZoom(1.25) }.keyboardShortcut("+")
                Button("Zoom Out") { model.changeZoom(0.8) }.keyboardShortcut("-")
                Divider()
                Button("Rotate Left") { model.apply(.rotateLeft) }.keyboardShortcut("[")
                    .disabled(!model.canEdit)
                Button("Rotate Right") { model.apply(.rotateRight) }.keyboardShortcut("]")
                    .disabled(!model.canEdit)
                Button(model.editPanel ? "Hide Edit Tools" : "Show Edit Tools", action: model.toggleEditor)
                Button("Reveal in Finder", action: model.reveal).disabled(model.selected == nil)
                Divider()
                Button("Slideshow", action: model.toggleSlideshow).keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
    }
}

@MainActor @Observable
final class Workspace {
    static let minimumWindow = CGSize(width: 120, height: 62)
    var toolbarHeight: CGFloat = 32
    let pipeline = Pipeline()
    let thumbnails = Thumbnails()
    var assets: [Asset] = []
    var selected: Asset?
    var picture: SillCore.Picture?
    var zoom: Double?
    var fitScale = 1.0
    var busy = false
    var notice: String?
    var inspect = false
    var showBrowser = true
    var singleFile: Asset?
    private(set) var siblingSource: Asset?
    var viewFailure: String?
    var recents = RecentFiles.load()
    let diagnostics = ViewerDiagnostics()
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var hasFittedWindow = false
    var hasBookmark = UserDefaults.standard.data(forKey: "folderBookmark") != nil
    var animating = false
    var slideshow = false
    var editPanel = false
    var edits: [Edit] = []
    var redo: [Edit] = []
    var preview: CGImage?
    var previewBusy = false
    var previewRevision = 0
    var previewTask: Task<Void, Never>?
    var cropping = false
    var cropBox = CGRect.zero
    var exportPresentation: ExportPresentation?
    var exporting = false
    var exportProgress = 0
    var exportTotal = 0
    var exportTask: Task<Void, Never>?
    let folderIndex = FolderIndex()
    var volumeLocations: [DiskLocation] = []
    var folderLocation: URL?
    private(set) var includeSubfolders = false
    var subfolders: [URL] = []
    var folderLoading = false
    var sidebarIssue = false
    private var grantedFolders: [URL] = []
    private var siblingTask: Task<Void, Never>?
    private var siblingOffset = 0
    private var siblingNeedsAccess = false
    private var directoryTask: Task<Void, Never>?
    private var generation = 0
    private var load: Task<Void, Never>?
    private var playback: Task<Void, Never>?
    private var show: Task<Void, Never>?

    func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.directoryURL = selected?.url.deletingLastPathComponent()
        panel.allowsMultipleSelection = true
        panel.message = "Choose images to open in Sill."
        if panel.runModal() == .OK { openFiles(panel.urls) }
    }

    func pickFolder(browseSiblings: Bool = false, startingAt: URL? = nil, offset: Int = 0) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Browse"
        panel.directoryURL = startingAt ?? folderLocation ?? selected?.url.deletingLastPathComponent()
        let focus = browseSiblings ? selected?.url : nil
        if browseSiblings, let focus {
            panel.directoryURL = focus.deletingLastPathComponent()
            panel.message = "Select the folder to browse images alongside \(focus.lastPathComponent)."
        }
        let remember = NSButton(checkboxWithTitle: "Remember this folder", target: nil, action: nil)
        remember.sizeToFit()
        panel.accessoryView = remember
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        if remember.state == .on {
            do {
                let data = try withAccess(folder) {
                    try folder.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                            includingResourceValuesForKeys: nil, relativeTo: nil)
                }
                UserDefaults.standard.set(data, forKey: "folderBookmark")
                hasBookmark = true
            } catch { notice = "Couldn’t remember the folder. \(error.localizedDescription)" }
        }
        registerFolder(folder)
        openFolder(folder, focus: focus, offset: offset)
    }

    func reopenFolder() {
        do {
            guard let folder = try resolveRememberedFolder() else { return }
            registerFolder(folder)
            openFolder(folder)
        } catch { notice = error.localizedDescription }
    }

    private func resolveRememberedFolder() throws -> URL? {
        guard let data = UserDefaults.standard.data(forKey: "folderBookmark") else { return nil }
        var stale = false
        let folder = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                             relativeTo: nil, bookmarkDataIsStale: &stale)
        if stale, let refreshed = try? withAccess(folder, {
            try folder.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                    includingResourceValuesForKeys: nil, relativeTo: nil)
        }) {
            UserDefaults.standard.set(refreshed, forKey: "folderBookmark")
        }
        return folder
    }

    func forgetFolder() {
        UserDefaults.standard.removeObject(forKey: "folderBookmark")
        hasBookmark = false
    }

    func openURLs(_ urls: [URL]) {
        if urls.count == 1, let url = urls.first,
           url.hasDirectoryPath || withAccess(url, {
               (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
           }) {
            registerFolder(url)
            openFolder(url)
        } else {
            openFiles(urls)
        }
    }

    func openFiles(_ urls: [URL]) {
        includeSubfolders = false
        resetSiblingSearch()
        updateDirectory(nil)
        var seen = Set<URL>()
        let files = urls.filter { $0.isFileURL && seen.insert($0).inserted }.map { Asset($0) }
        singleFile = files.count == 1 ? files.first : nil
        siblingSource = files.first.flatMap { first in
            let parent = first.url.deletingLastPathComponent().standardizedFileURL.path
            return files.allSatisfy { $0.url.deletingLastPathComponent().standardizedFileURL.path == parent }
                ? first : nil
        }
        if singleFile != nil {
            showBrowser = false
            editPanel = false
            inspect = false
        }
        diagnostics.reset()
        replaceLibrary(files)
        if let siblingSource { findSiblings(of: siblingSource) }
    }

    func setIncludeSubfolders(_ include: Bool) {
        guard let folderLocation, include != includeSubfolders, !busy else { return }
        openFolder(folderLocation, focus: selected?.url, includingSubfolders: include)
    }

    func openFolder(_ folder: URL, focus: URL? = nil, offset: Int = 0, fromSidebar: Bool = false,
                    includingSubfolders: Bool? = nil) {
        let recursive = includingSubfolders ?? includeSubfolders
        resetSiblingSearch()
        let grant = accessForFolder(folder)
        stopAnimation()
        if slideshow { toggleSlideshow() }
        diagnostics.start()
        load?.cancel()
        generation += 1
        let token = generation
        busy = true
        load = Task {
            do {
                let items = try await folderIndex.images(folder, access: grant, includingSubfolders: recursive)
                guard !Task.isCancelled, token == generation else { return }
                includeSubfolders = recursive
                singleFile = nil
                siblingSource = nil
                diagnostics.enumerated(items.count)
                updateDirectory(folder)
                replaceLibrary(items, focus: focus, offset: offset)
            } catch {
                guard token == generation else { return }
                diagnostics.reset()
                busy = false
                if fromSidebar && FolderIndex.permissionDenied(error) { pickFolder(startingAt: folder) }
                else { notice = error.localizedDescription }
            }
        }
    }

    private func replaceLibrary(_ items: [Asset], focus: URL? = nil, offset: Int = 0) {
        if slideshow { toggleSlideshow() }
        assets = items
        if let focus, let index = items.firstIndex(where: { $0.url.path == focus.path }) {
            let next = items[wrappedIndex(index, offset: offset, count: items.count)]
            if next.id == selected?.id, picture != nil {
                selected = next
                busy = false
            } else {
                select(next)
            }
        } else {
            select(items.first)
        }
    }

    func select(_ asset: Asset?) {
        selected = asset
        picture = nil
        viewFailure = nil
        zoom = nil
        loadFrame(0, autoplay: true)
    }

    func closeImage() {
        guard selected != nil else { return }
        if slideshow { toggleSlideshow() }
        resetSiblingSearch()
        select(nil)
    }

    func handleViewerKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty,
              let window, event.window === window, window.attachedSheet == nil,
              NSApp.modalWindow == nil, !(window.firstResponder is NSTextView) else { return false }
        switch event.charactersIgnoringModifiers {
        case " " where !assets.isEmpty:
            move(1)
        case "\u{1B}":
            window.performClose(nil)
        default:
            return false
        }
        return true
    }

    func move(_ offset: Int) {
        if siblingTask != nil {
            siblingOffset += offset
            return
        }
        if siblingNeedsAccess, siblingSource != nil {
            pickFolder(browseSiblings: true, offset: offset)
            return
        }
        guard !assets.isEmpty else { return }
        guard let selected, let index = assets.firstIndex(where: { $0.id == selected.id }) else { select(assets.first); return }
        guard assets.count > 1 else { return }
        select(assets[wrappedIndex(index, offset: offset, count: assets.count)])
    }

    private func wrappedIndex(_ index: Int, offset: Int, count: Int) -> Int {
        (index + offset % count + count) % count
    }

    private func resetSiblingSearch() {
        siblingTask?.cancel()
        siblingTask = nil
        siblingOffset = 0
        siblingNeedsAccess = false
    }

    private func findSiblings(of file: Asset) {
        let folder = file.url.deletingLastPathComponent()
        let grant = accessForFolder(folder)
        let directFiles = Dictionary(assets.map { ($0.url.standardizedFileURL.path, $0) },
                                     uniquingKeysWith: { first, _ in first })
        siblingTask = Task {
            do {
                let items = try await folderIndex.siblings(of: file, in: folder, access: grant)
                guard !Task.isCancelled else { return }
                let offset = siblingOffset
                resetSiblingSearch()
                updateDirectory(folder)
                guard items.contains(where: { $0.url.standardizedFileURL.path == file.url.standardizedFileURL.path }) else {
                    siblingNeedsAccess = true
                    if offset != 0 { pickFolder(browseSiblings: true, offset: offset) }
                    return
                }
                assets = items.map { directFiles[$0.url.standardizedFileURL.path] ?? $0 }
                if offset != 0 { move(offset) }
            } catch {
                guard !Task.isCancelled else { return }
                let offset = siblingOffset
                resetSiblingSearch()
                siblingNeedsAccess = true
                if offset != 0 { pickFolder(browseSiblings: true, offset: offset) }
            }
        }
    }

    func refreshVolumes() {
        Task { volumeLocations = await folderIndex.volumes() }
    }

    private func updateDirectory(_ folder: URL?) {
        directoryTask?.cancel()
        folderLocation = folder
        subfolders = []
        sidebarIssue = false
        folderLoading = folder != nil
        guard let folder else { return }
        let grant = accessForFolder(folder)
        directoryTask = Task {
            do {
                let directories = try await folderIndex.directories(folder, access: grant)
                guard !Task.isCancelled else { return }
                subfolders = directories
            } catch {
                guard !Task.isCancelled else { return }
                sidebarIssue = true
            }
            folderLoading = false
        }
    }

    private func registerFolder(_ folder: URL) {
        grantedFolders.removeAll { $0.standardizedFileURL.path == folder.standardizedFileURL.path }
        grantedFolders.append(folder)
    }

    private func accessForFolder(_ folder: URL) -> URL? {
        let path = folder.standardizedFileURL.pathComponents
        if let granted = grantedFolders.filter({ path.starts(with: $0.standardizedFileURL.pathComponents) })
            .max(by: { $0.pathComponents.count < $1.pathComponents.count }) {
            return granted
        }
        guard hasBookmark, let remembered = try? resolveRememberedFolder(),
              path.starts(with: remembered.standardizedFileURL.pathComponents) else { return nil }
        return remembered
    }

    func loadFrame(_ index: Int, autoplay: Bool = false) {
        stopAnimation()
        clearEdits()
        viewFailure = nil
        load?.cancel()
        generation += 1
        let token = generation
        guard let selected else { busy = false; return }
        busy = true
        load = Task {
            defer { if token == generation { busy = false } }
            do {
                let result = try await pipeline.view(selected, index: index)
                guard !Task.isCancelled, token == generation else { return }
                picture = result
                if autoplay && index == 0 {
                    if selected.id == singleFile?.id || selected.folder == nil { rememberOpenedFile(selected) }
                    fitWindowToImage()
                }
                if autoplay, result.kind == .animation { toggleAnimation() }
            } catch is CancellationError {
            } catch {
                if token == generation {
                    picture = nil
                    viewFailure = error.localizedDescription
                }
            }
        }
    }

    func attachWindow(_ newWindow: NSWindow) {
        if window !== newWindow { hasFittedWindow = false }
        window = newWindow
        newWindow.titlebarAppearsTransparent = true
        newWindow.styleMask.insert(.fullSizeContentView)
        if let close = newWindow.standardWindowButton(.closeButton) {
            let center = newWindow.frame.height - close.convert(close.bounds, to: nil).midY
            if (12...26).contains(center) { toolbarHeight = (center * 2).rounded() }
        }
        fitWindowToImage()
    }

    func toggleFullScreen() { window?.toggleFullScreen(nil) }

    func fitWindowToImage() {
        guard let image = displayedImage, zoom == nil, let window, !window.styleMask.contains(.fullScreen),
              let screen = window.screen ?? NSScreen.main else { return }
        let backing = window.backingScaleFactor
        let imageSize = CGSize(width: CGFloat(image.width) / backing, height: CGFloat(image.height) / backing)
        let visible = screen.visibleFrame
        let minimumWidth = max(Self.minimumWindow.width, sidePanelWidth(for: 0) + 24)
        let anchor: CGPoint?
        if hasFittedWindow {
            // Use the current corner so a deliberate window drag establishes a new anchor.
            anchor = CGPoint(
                x: max(visible.minX, min(window.frame.minX, visible.maxX - minimumWidth)),
                y: min(visible.maxY, max(window.frame.maxY, visible.minY + Self.minimumWindow.height))
            )
        } else {
            anchor = nil
        }

        let availableWidth = anchor.map { visible.maxX - $0.x } ?? visible.width
        let availableHeight = anchor.map { $0.y - visible.minY } ?? visible.height
        let heightScale = (availableHeight - toolbarHeight) / imageSize.height
        let regularWidth = imageSize.width * min(1, heightScale) + sidePanelWidth(for: 800)
        let sideWidth = sidePanelWidth(for: min(availableWidth, regularWidth))
        let minimumScale = max((Self.minimumWindow.width - sideWidth) / imageSize.width,
                               (Self.minimumWindow.height - toolbarHeight) / imageSize.height)
        let maximumScale = min((availableWidth - sideWidth) / imageSize.width, heightScale)
        let scale = min(maximumScale, max(1, minimumScale))
        let size = CGSize(
            width: min(availableWidth, max(Self.minimumWindow.width, (imageSize.width * scale + sideWidth).rounded())),
            height: min(availableHeight, max(Self.minimumWindow.height, (imageSize.height * scale + toolbarHeight).rounded()))
        )
        let origin = if let anchor {
            CGPoint(x: anchor.x, y: anchor.y - size.height)
        } else {
            CGPoint(x: max(visible.minX, min(window.frame.midX - size.width / 2, visible.maxX - size.width)),
                    y: max(visible.minY, min(window.frame.midY - size.height / 2, visible.maxY - size.height)))
        }
        let frame = CGRect(origin: origin, size: size)
        hasFittedWindow = true
        if window.frame != frame { window.setFrame(frame, display: true) }
    }

    func browserWidth(for width: CGFloat) -> CGFloat { width < 800 ? 170 : 225 }

    func inspectorWidth(for width: CGFloat) -> CGFloat {
        if editPanel { return width < 800 && showBrowser ? 205 : 260 }
        return width < 800 && showBrowser ? 180 : 255
    }

    private func sidePanelWidth(for width: CGFloat) -> CGFloat {
        (showBrowser ? browserWidth(for: width) + 1 : 0) + (editPanel || inspect ? inspectorWidth(for: width) + 1 : 0)
    }

    var hasOpenPanels: Bool { showBrowser || inspect || editPanel }

    func toggleBrowser() { showBrowser.toggle() }

    func toggleInspector() {
        let show = !inspect
        editPanel = false
        inspect = show
    }

    func toggleEditor() {
        let show = !editPanel
        inspect = false
        editPanel = show
        if show && animating { stopAnimation() }
    }

    func showImageOnly() {
        showBrowser = false
        inspect = false
        editPanel = false
        cropping = false
        zoom = nil
        fitWindowToImage()
    }

    func showDiagnostics() { notice = diagnostics.report() }

    func changeZoom(_ factor: Double) {
        zoom = min(16, max(0.025, (zoom ?? fitScale) * factor))
    }

    func stopAnimation() {
        playback?.cancel()
        animating = false
    }

    func toggleAnimation() {
        if animating { stopAnimation(); return }
        guard edits.isEmpty, let selected, let picture, picture.kind == .animation else { return }
        animating = true
        let token = generation
        playback = Task {
            var frame = picture
            var completed = 0
            defer { if token == generation && !Task.isCancelled { animating = false } }
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(frame.duration))
                    let next = (frame.index + 1) % frame.count
                    if next == 0 {
                        completed += 1
                        if frame.loops > 0 && completed >= frame.loops { return }
                    }
                    frame = try await pipeline.view(selected, index: next)
                    guard !Task.isCancelled, token == generation else { return }
                    self.picture = frame
                }
            } catch is CancellationError {
            } catch { if token == generation { notice = error.localizedDescription } }
        }
    }

    func toggleSlideshow() {
        if slideshow {
            show?.cancel()
            slideshow = false
            return
        }
        guard assets.count > 1 else { return }
        slideshow = true
        show = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                if !busy { move(1) }
            }
        }
    }
}
