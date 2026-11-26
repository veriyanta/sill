import CoreImage
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum Edit: Sendable, Equatable {
    case rotateRight, rotateLeft, flipHorizontal, flipVertical
    case crop(CGRect)
    case resize(maxEdge: Int)
    case grayscale
    case brightness(Double)
    case contrast(Double)
}

public enum ExportFormat: String, CaseIterable, Sendable, Identifiable {
    case original, jpeg, png, tiff, heic, bmp, gif

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .original: "Original — exact copy"
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .tiff: "TIFF"
        case .heic: "HEIC"
        case .bmp: "BMP"
        case .gif: "GIF"
        }
    }

    public var type: UTType? {
        switch self {
        case .original: nil
        case .jpeg: .jpeg
        case .png: .png
        case .tiff: .tiff
        case .heic: .heic
        case .bmp: .bmp
        case .gif: .gif
        }
    }

    public var available: Bool {
        guard let type else { return true }
        return (CGImageDestinationCopyTypeIdentifiers() as? [String])?.contains(type.identifier) == true
    }

    public func filename(extensionOf asset: Asset) -> String {
        type?.preferredFilenameExtension ?? asset.url.pathExtension
    }
}

public enum Collision: String, Sendable, CaseIterable, Identifiable {
    case keepBoth, skip, overwrite
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .keepBoth: "Keep both"
        case .skip: "Skip existing"
        case .overwrite: "Replace existing"
        }
    }
}

public struct ExportOptions: Sendable {
    public var format: ExportFormat
    public var quality: Double
    public var preserveMetadata: Bool
    public var collision: Collision
    public var allImages: Bool

    public init(format: ExportFormat = .png, quality: Double = 0.9, preserveMetadata: Bool = false,
                collision: Collision = .keepBoth, allImages: Bool = false) {
        self.format = format
        self.quality = quality
        self.preserveMetadata = preserveMetadata
        self.collision = collision
        self.allImages = allImages
    }
}

extension Pipeline {
    public func preview(_ picture: Picture, edits: [Edit]) throws -> CGImage {
        try Task.checkCancellation()
        return try render(picture.image, edits: edits)
    }

    func render(_ input: CGImage, edits: [Edit]) throws -> CGImage {
        guard !edits.isEmpty else { return input }
        var image = CIImage(cgImage: input)
        for edit in edits {
            try Task.checkCancellation()
            switch edit {
            case .rotateRight: image = image.oriented(.right)
            case .rotateLeft: image = image.oriented(.left)
            case .flipHorizontal: image = image.oriented(.upMirrored)
            case .flipVertical: image = image.oriented(.downMirrored)
            case .crop(let box):
                guard [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite),
                      box.width > 0, box.height > 0 else { throw ImageFailure.invalid("Select a crop area.") }
                let ext = image.extent
                let area = CGRect(x: ext.minX + ext.width * box.minX, y: ext.minY + ext.height * box.minY,
                                  width: ext.width * box.width, height: ext.height * box.height)
                    .integral.intersection(ext)
                guard !area.isEmpty else { throw ImageFailure.invalid("The crop is outside the image.") }
                image = image.cropped(to: area)
            case .resize(let edge):
                guard (1...32_768).contains(edge) else {
                    throw ImageFailure.invalid("Enter a long edge from 1 to 32,768 pixels.")
                }
                let ext = image.extent
                let ratio = Double(edge) / max(ext.width, ext.height)
                let width = max(1, Int((ext.width * ratio).rounded()))
                let height = max(1, Int((ext.height * ratio).rounded()))
                try Source.check(width: width, height: height)
                image = image.transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY))
                image = image.clampedToExtent().applyingFilter("CILanczosScaleTransform", parameters: [
                    kCIInputScaleKey: Double(height) / ext.height,
                    kCIInputAspectRatioKey: (Double(width) / ext.width) / (Double(height) / ext.height)
                ]).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
            case .grayscale:
                image = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            case .brightness(let value):
                guard value.isFinite, (-1...1).contains(value) else {
                    throw ImageFailure.invalid("Brightness must be between −1 and 1.")
                }
                image = image.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: value])
            case .contrast(let value):
                guard value.isFinite, (0.25...4).contains(value) else {
                    throw ImageFailure.invalid("Contrast must be between 0.25 and 4.")
                }
                image = image.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: value])
            }
        }
        let space = input.colorSpace?.model == .rgb ? input.colorSpace : nil
        guard let output = context.createCGImage(image, from: image.extent,
                                                  format: input.bitsPerComponent > 8 ? .RGBA16 : .RGBA8,
                                                  colorSpace: space ?? Self.sRGB) else { throw ImageFailure.render }
        return output
    }

    /// Returns nil when an existing destination was skipped.
    public func export(_ asset: Asset, to folder: URL, named filename: String, index: Int = 0,
                       edits: [Edit] = [], options: ExportOptions) throws -> URL? {
        try Task.checkCancellation()
        try Self.validate(filename)
        guard options.quality.isFinite, (0...1).contains(options.quality) else {
            throw ImageFailure.invalid("Quality must be between 0 and 1.")
        }
        return try withAccess(asset.folder ?? asset.url) {
            try withAccess(folder) {
                let proposed = folder.appending(path: filename)
                let stage = folder.appending(path: ".sill-\(UUID().uuidString).tmp")
                defer { try? FileManager.default.removeItem(at: stage) }
                if options.format == .original {
                    guard edits.isEmpty else { throw ImageFailure.invalid("An exact copy cannot include pixel edits.") }
                    let original = asset.url.resolvingSymlinksInPath()
                    guard try original.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                        throw ImageFailure.unreadable(asset.name)
                    }
                    _ = try Source(Asset(original))
                    try FileManager.default.copyItem(at: original, to: stage)
                } else {
                    let source = try Source(asset)
                    try encode(source, to: stage, index: index, edits: edits, options: options)
                }
                try Task.checkCancellation()
                return try Self.publish(stage, as: proposed, collision: options.collision)
            }
        }
    }

    static func validate(_ name: String) throws {
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains("\0"),
              name.utf8.count <= 255 else { throw ImageFailure.invalid("Enter a valid file name.") }
    }

    private func encode(_ source: Source, to stage: URL, index: Int, edits: [Edit], options: ExportOptions) throws {
        guard let type = options.format.type, options.format.available,
              (0..<source.count).contains(index) else { throw ImageFailure.encode }
        if options.allImages && source.count > 1 {
            let compatible = (source.kind == .pages && options.format == .tiff)
                || (source.kind == .animation && [.gif, .png].contains(options.format))
            guard compatible else {
                throw ImageFailure.invalid("Choose TIFF for all pages, or GIF or PNG for all animation frames.")
            }
        }
        let indices = options.allImages ? 0..<source.count : index..<(index + 1)
        guard let consumer = CGDataConsumer(url: stage as CFURL),
              let destination = CGImageDestinationCreateWithDataConsumer(consumer, type.identifier as CFString,
                                                                         indices.count, nil) else { throw ImageFailure.encode }
        let sequence = indices.count > 1 && source.kind == .animation
        let png = options.format == .png
        let group = png ? kCGImagePropertyPNGDictionary : kCGImagePropertyGIFDictionary
        let delay = png ? kCGImagePropertyAPNGDelayTime : kCGImagePropertyGIFDelayTime
        let loop = png ? kCGImagePropertyAPNGLoopCount : kCGImagePropertyGIFLoopCount
        if sequence {
            CGImageDestinationSetProperties(destination, [group: [loop: source.timing(source.index(0)).1]] as CFDictionary)
        }
        for logical in indices {
            try Task.checkCancellation()
            let physical = source.index(logical)
            let image = try render(oriented(source, physical), edits: edits)
            var properties: [CFString: Any] = [kCGImagePropertyOrientation: 1]
            if options.format == .jpeg || options.format == .heic {
                properties[kCGImageDestinationLossyCompressionQuality] = options.quality
            }
            if options.format == .jpeg || options.format == .bmp {
                properties[kCGImageDestinationBackgroundColor] = CGColor(gray: 1, alpha: 1)
            }
            if options.preserveMetadata {
                let original = source.properties(physical)
                // Geometry, thumbnails and maker-specific offsets describe the original raster.
                let groups: [(CFString, [String])] = [
                    (kCGImagePropertyTIFFDictionary, ["Artist", "Copyright", "DateTime", "Make", "Model", "ImageDescription"]),
                    (kCGImagePropertyExifDictionary, ["DateTimeOriginal", "DateTimeDigitized", "ExposureTime",
                        "FNumber", "ISOSpeedRatings", "FocalLength", "LensModel", "LensMake", "UserComment"]),
                    (kCGImagePropertyGPSDictionary, ["Latitude", "LatitudeRef", "Longitude", "LongitudeRef",
                        "Altitude", "AltitudeRef", "DateStamp", "TimeStamp"])
                ]
                for (key, allowed) in groups {
                    if let fields = original[key as String] as? [String: Any] {
                        properties[key] = fields.filter { allowed.contains($0.key) }
                    }
                }
            }
            if sequence { properties[group] = [delay: source.timing(physical).0] }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw ImageFailure.encode }
    }

    private static func publish(_ stage: URL, as proposed: URL, collision: Collision) throws -> URL? {
        var candidate = proposed
        let parent = proposed.deletingLastPathComponent()
        let stem = proposed.deletingPathExtension().lastPathComponent
        let suffix = proposed.pathExtension.isEmpty ? "" : ".\(proposed.pathExtension)"
        for attempt in 1...10_000 {
            try Task.checkCancellation()
            let status: Int32 = stage.withUnsafeFileSystemRepresentation { from in
                candidate.withUnsafeFileSystemRepresentation { to in
                    if collision == .overwrite { return Darwin.rename(from!, to!) }
                    return renamex_np(from!, to!, UInt32(RENAME_EXCL))
                }
            }
            if status == 0 { return candidate }
            let code = errno
            guard code == EEXIST, collision != .overwrite else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            if collision == .skip { return nil }
            let ending = " \(attempt + 1)\(suffix)"
            let limit = 255 - ending.utf8.count
            var prefix = ""
            for character in stem {
                guard prefix.utf8.count + String(character).utf8.count <= limit else { break }
                prefix.append(character)
            }
            candidate = parent.appending(path: prefix + ending)
        }
        throw ImageFailure.collision
    }
}
