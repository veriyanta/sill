import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageFailure: LocalizedError, Sendable {
    case unreadable(String), oversized, render, invalid(String), encode, collision
    case recursiveImageLimit(Int)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let name): "Couldn’t read \(name)."
        case .oversized: "The image exceeds the 80-megapixel or 32,768-pixel edge limit."
        case .render: "Couldn’t render the image."
        case .invalid(let detail): detail
        case .encode: "Couldn’t encode the selected format."
        case .collision: "A file with that name already exists."
        case .recursiveImageLimit(let limit):
            "This folder and its subfolders contain more than \(limit.formatted()) images. The scan stopped. Choose a smaller folder or turn off Include Subfolders."
        }
    }
}

public struct Asset: Hashable, Sendable, Identifiable {
    public let url: URL
    public let folder: URL?
    public var id: URL { url }
    public var name: String { url.lastPathComponent }

    public init(_ url: URL, folder: URL? = nil) {
        self.url = url
        self.folder = folder
    }
}

public func withAccess<T>(_ url: URL, _ work: () throws -> T) rethrows -> T {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    return try work()
}

public enum ImageKind: Equatable, Sendable { case still, animation, pages }

public struct Picture: Sendable {
    public let image: CGImage
    public let type: String
    public let index: Int
    public let count: Int
    public let kind: ImageKind
    public let duration: Double
    public let loops: Int
    public let metadata: String
    public var width: Int { image.width }
    public var height: Int { image.height }
}

public enum Library {
    public static let extensions: Set<String> = [
        "jpeg", "jpg", "jpe", "png", "apng", "gif", "tif", "tiff", "heif",
        "heic", "bmp", "webp", "ico", "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2"
    ]

    public static func list(_ folder: URL, access: URL? = nil,
                            requireReadableEntries: Bool = false) throws -> [Asset] {
        try withAccess(access ?? folder) {
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
            return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys),
                                                                options: [.skipsHiddenFiles, .skipsPackageDescendants])
                .filter {
                    guard extensions.contains($0.pathExtension.lowercased()) else { return false }
                    do {
                        let values = try $0.resourceValues(forKeys: keys)
                        return values.isRegularFile == true && values.isSymbolicLink != true
                    } catch {
                        if requireReadableEntries { throw error }
                        return false
                    }
                }
                .sorted {
                    let order = $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
                }
                .map { Asset($0, folder: access ?? folder) }
        }
    }

    public static let recursiveImageLimit = 4096

    public static func listRecursively(_ folder: URL, access: URL? = nil) throws -> [Asset] {
        let scope = access ?? folder
        return try withAccess(scope) {
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
            var traversalError: Error?
            guard let entries = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys),
                                                               options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                               errorHandler: { _, error in
                traversalError = error
                return false
            }) else {
                throw ImageFailure.unreadable(folder.lastPathComponent)
            }

            var images: [Asset] = []
            while let url = entries.nextObject() as? URL {
                try Task.checkCancellation()
                guard extensions.contains(url.pathExtension.lowercased()) else { continue }
                let values = try url.resourceValues(forKeys: keys)
                guard values.isRegularFile == true && values.isSymbolicLink != true else { continue }
                guard images.count < recursiveImageLimit else { throw ImageFailure.recursiveImageLimit(recursiveImageLimit) }
                images.append(Asset(url, folder: scope))
            }
            if let traversalError { throw traversalError }
            try Task.checkCancellation()
            return images.sorted {
                let order = $0.url.path.localizedStandardCompare($1.url.path)
                return order == .orderedSame ? $0.url.path < $1.url.path : order == .orderedAscending
            }
        }
    }
}

struct Source {
    let handle: CGImageSource
    let type: String
    let count: Int
    let firstIndex: Int

    init(_ asset: Asset) throws {
        guard let handle = CGImageSourceCreateWithURL(asset.url as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary), let type = CGImageSourceGetType(handle), CGImageSourceGetCount(handle) > 0 else {
            throw ImageFailure.unreadable(asset.name)
        }
        self.handle = handle
        self.type = type as String
        count = CGImageSourceGetCount(handle)
        let primary = CGImageSourceGetPrimaryImageIndex(handle)
        firstIndex = (0..<count).contains(primary) ? primary : 0
    }

    var kind: ImageKind {
        guard count > 1 else { return .still }
        return ["com.compuserve.gif", "public.png", "org.webmproject.webp"].contains(type) ? .animation : .pages
    }

    func index(_ requested: Int) -> Int {
        if requested == 0 { return firstIndex }
        return requested <= firstIndex ? requested - 1 : requested
    }

    func properties(_ index: Int) -> [String: Any] {
        CGImageSourceCopyPropertiesAtIndex(handle, index, nil) as? [String: Any] ?? [:]
    }

    static func check(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= 32_768, height <= 32_768,
              width <= 80_000_000 / height else { throw ImageFailure.oversized }
    }

    func decode(_ index: Int, thumbnail: Int? = nil) throws -> CGImage {
        let props = properties(index)
        if let width = props[kCGImagePropertyPixelWidth as String] as? Int,
           let height = props[kCGImagePropertyPixelHeight as String] as? Int {
            try Self.check(width: width, height: height)
        }
        if let thumbnail {
            guard let image = CGImageSourceCreateThumbnailAtIndex(handle, index, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: thumbnail,
                kCGImageSourceShouldCache: true,

                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary) else { throw ImageFailure.render }
            return image
        }
        guard let image = CGImageSourceCreateImageAtIndex(handle, index, [
                kCGImageSourceShouldCache: true,

            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { throw ImageFailure.render }
        try Self.check(width: image.width, height: image.height)
        return image
    }

    func timing(_ index: Int) -> (Double, Int) {
        let groups = [(kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime,
                       kCGImagePropertyGIFDelayTime, kCGImagePropertyGIFLoopCount),
                      (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime,
                       kCGImagePropertyAPNGDelayTime, kCGImagePropertyAPNGLoopCount),
                      (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime,
                       kCGImagePropertyWebPDelayTime, kCGImagePropertyWebPLoopCount)]
        let frame = properties(index)
        let container = CGImageSourceCopyProperties(handle, nil) as? [String: Any] ?? [:]
        for (group, raw, delay, loop) in groups {
            guard let values = frame[group as String] as? [String: Any] else { continue }
            let overall = container[group as String] as? [String: Any]
            let duration = values[raw as String] as? Double ?? values[delay as String] as? Double ?? 0.1
            let loops = overall?[loop as String] as? Int ?? values[loop as String] as? Int ?? 1
            return (duration.isFinite ? max(0.02, min(duration, 86_400)) : 0.1, max(0, loops))
        }
        return (0.1, 1)
    }
}

public actor Thumbnails {
    private struct Entry {
        let image: CGImage
        let bytes: Int
        var lastUse: UInt64
    }

    private var cache: [URL: Entry] = [:]
    private var cost = 0
    private var clock: UInt64 = 0
    private let countLimit = 320
    private let byteLimit = 32 * 1024 * 1024

    public init() {}

    public func load(_ asset: Asset) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        return withAccess(asset.folder ?? asset.url) {
            let values = try? asset.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            var key = URLComponents(url: asset.url, resolvingAgainstBaseURL: false)
            key?.fragment = "\(values?.fileSize ?? -1)-\(values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? -1)"
            let url = key?.url ?? asset.url
            clock &+= 1
            if var entry = cache[url] {
                entry.lastUse = clock
                cache[url] = entry
                return entry.image
            }
            guard let source = try? Source(asset),
                  let image = try? source.decode(source.firstIndex, thumbnail: 144) else { return nil }
            let bytes = image.bytesPerRow * image.height
            if bytes <= byteLimit {
                while cache.count >= countLimit || cost + bytes > byteLimit {
                    guard let oldest = cache.min(by: { $0.value.lastUse < $1.value.lastUse }) else { break }
                    cache.removeValue(forKey: oldest.key)
                    cost -= oldest.value.bytes
                }
                cache[url] = Entry(image: image, bytes: bytes, lastUse: clock)
                cost += bytes
            }
            return image
        }
    }

    public func clear() {
        cache.removeAll()
        cost = 0
    }
}
