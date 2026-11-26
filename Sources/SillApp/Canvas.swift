import AppKit
import SwiftUI

struct ImageCanvas: NSViewRepresentable {
    let image: CGImage
    let zoom: Double?
    var cropping = false
    var onCrop: (CGRect) -> Void = { _ in }
    let onFit: (Double) -> Void
    let onZoom: (Double) -> Void
    var onDraw: () -> Void = {}

    func makeNSView(context: Context) -> CanvasScroll {
        let view = CanvasScroll()
        view.drawsBackground = false
        view.hasHorizontalScroller = true
        view.hasVerticalScroller = true
        view.autohidesScrollers = true
        view.scrollerStyle = .overlay
        view.documentView = view.surface
        return view
    }

    func updateNSView(_ view: CanvasScroll, context: Context) {
        let changedSize = view.surface.image?.width != image.width || view.surface.image?.height != image.height
        view.surface.image = image
        view.surface.cropping = cropping
        view.surface.onCrop = onCrop
        view.surface.onDraw = onDraw
        view.onFit = onFit
        view.onZoom = onZoom
        let changed = changedSize || view.zoom != zoom
        view.zoom = zoom
        if changed { view.reflow() }
    }
}

final class CanvasScroll: NSScrollView {
    let surface = CanvasSurface()
    var zoom: Double?
    var onFit: ((Double) -> Void)?
    var onZoom: ((Double) -> Void)?
    private var lastFit = 0.0

    override func layout() {
        super.layout()
        reflow()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reflow()
    }

    func reflow() {
        guard let image = surface.image, contentSize.width > 1, contentSize.height > 1 else { return }
        let backing = window?.backingScaleFactor ?? 1
        let dimensions = CGSize(width: CGFloat(image.width) / backing, height: CGFloat(image.height) / backing)
        let fit = min(contentSize.width / dimensions.width, contentSize.height / dimensions.height)
        if abs(fit - lastFit) > 0.0001 {
            lastFit = fit
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lastFit == fit else { return }
                self.onFit?(fit)
            }
        }
        let old = surface.imageRect
        let bounds = contentView.bounds
        let anchor = old.isEmpty ? CGPoint(x: 0.5, y: 0.5) : CGPoint(x: (bounds.midX - old.minX) / old.width,
                                                                    y: (bounds.midY - old.minY) / old.height)
        let size = CGSize(width: dimensions.width * (zoom ?? fit), height: dimensions.height * (zoom ?? fit))
        let frame = CGSize(width: max(contentSize.width, size.width),
                           height: max(contentSize.height, size.height))
        let rect = CGRect(x: (frame.width - size.width) / 2, y: (frame.height - size.height) / 2,
                          width: size.width, height: size.height)
        guard surface.frame.size != frame || old != rect else { return }
        surface.setFrameSize(frame)
        surface.imageRect = rect
        surface.needsDisplay = true
        contentView.scroll(to: contentView.constrainBoundsRect(CGRect(
            x: rect.minX + rect.width * anchor.x - bounds.width / 2,
            y: rect.minY + rect.height * anchor.y - bounds.height / 2,
            width: bounds.width, height: bounds.height)).origin)
        reflectScrolledClipView(contentView)
    }

    override func magnify(with event: NSEvent) {
        onZoom?(max(0.5, 1 + event.magnification))
    }
}

final class CanvasSurface: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var imageRect = CGRect.zero
    var cropping = false { didSet { if !cropping { selection = .zero; needsDisplay = true } } }
    var onCrop: ((CGRect) -> Void)?
    var onDraw: (() -> Void)?
    private var hasDrawnImage = false
    private var start = CGPoint.zero
    private var pan = CGPoint.zero
    private var selection = CGRect.zero

    override func draw(_ dirtyRect: NSRect) {
        guard let image, !imageRect.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = imageRect.width * (window?.backingScaleFactor ?? 1) > CGFloat(image.width)
            ? .none : .high
        context.setFillColor(CGColor(gray: 0.25, alpha: 1))
        context.fill(imageRect)
        if image.alphaInfo != .none && image.alphaInfo != .noneSkipFirst && image.alphaInfo != .noneSkipLast {
            let region = imageRect.intersection(dirtyRect)
            if !region.isNull {
                context.saveGState()
                context.clip(to: imageRect)
                context.setFillColor(CGColor(gray: 0.33, alpha: 1))
                for y in Int(floor((region.minY - imageRect.minY) / 8))...Int(ceil((region.maxY - imageRect.minY) / 8)) {
                    for x in Int(floor((region.minX - imageRect.minX) / 8))...Int(ceil((region.maxX - imageRect.minX) / 8))
                    where (x + y).isMultiple(of: 2) {
                        context.fill(CGRect(x: imageRect.minX + CGFloat(x * 8), y: imageRect.minY + CGFloat(y * 8),
                                            width: 8, height: 8))
                    }
                }
                context.restoreGState()
            }
        }
        context.draw(image, in: imageRect)
        if !hasDrawnImage {
            hasDrawnImage = true
            onDraw?()
        }
        if !selection.isEmpty {
            context.setFillColor(NSColor.black.withAlphaComponent(0.48).cgColor)
            context.addRect(imageRect)
            context.addRect(selection)
            context.drawPath(using: .eoFill)
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineDash(phase: 0, lengths: [5, 3])
            context.stroke(selection)
        }
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        pan = event.locationInWindow
        selection = .zero
        needsDisplay = true
        if !cropping { NSCursor.closedHand.push() }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if cropping {
            selection = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                               width: abs(point.x - start.x), height: abs(point.y - start.y)).intersection(imageRect)
            needsDisplay = true
        } else if let scroll = enclosingScrollView {
            let clip = scroll.contentView
            var next = clip.bounds
            next.origin.x -= event.locationInWindow.x - pan.x
            next.origin.y -= event.locationInWindow.y - pan.y
            clip.scroll(to: clip.constrainBoundsRect(next).origin)
            scroll.reflectScrolledClipView(clip)
            pan = event.locationInWindow
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard cropping else { NSCursor.pop(); return }
        guard !selection.isNull, selection.width >= 2, selection.height >= 2 else { onCrop?(.zero); return }
        onCrop?(CGRect(x: (selection.minX - imageRect.minX) / imageRect.width,
                      y: (selection.minY - imageRect.minY) / imageRect.height,
                      width: selection.width / imageRect.width, height: selection.height / imageRect.height))
    }
}
