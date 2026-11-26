import AppKit
import SillCore

extension Workspace {
    func reveal() {
        guard let selected else { return }
        withAccess(selected.folder ?? selected.url) {
            NSWorkspace.shared.activateFileViewerSelecting([selected.url])
        }
    }

    func openEnclosingFolder(for asset: Asset? = nil) {
        let image = asset ?? selected
        guard let folder = image?.url.deletingLastPathComponent() ?? folderLocation else { return }
        let scope = image?.folder ?? image?.url ?? folder
        let opened = withAccess(scope) {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
        }
        if !opened { notice = "Couldn’t open the folder in Finder." }
    }

    func copyImage() {
        guard let image = displayedImage else { return }
        let size = NSSize(width: image.width, height: image.height)
        let content = NSImage(cgImage: image, size: size)
        let clipboard = NSPasteboard.general
        clipboard.clearContents()
        if !clipboard.writeObjects([content]) { notice = "Couldn’t copy the image." }
    }

    func printImage() {
        guard let image = displayedImage else { return }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let height = info.paperSize.height - info.topMargin - info.bottomMargin
        let view = NSImageView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        view.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        view.imageScaling = .scaleProportionallyUpOrDown
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = true
        operation.run()
    }
}
