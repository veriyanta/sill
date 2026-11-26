import CoreImage
import Foundation
import ImageIO

public actor Pipeline {
    let context = CIContext(options: [.cacheIntermediates: false])

    public init() {}

    public func view(_ asset: Asset, index: Int = 0) throws -> Picture {
        try Task.checkCancellation()
        return try withAccess(asset.folder ?? asset.url) {
            let source = try Source(asset)
            guard (0..<source.count).contains(index) else { throw ImageFailure.invalid("Frame is out of range.") }
            let physical = source.index(index)
            let properties = source.properties(physical)
            let image = try oriented(source, physical)
            let (duration, loops) = source.timing(physical)
            return Picture(image: image, type: source.type, index: index, count: source.count,
                           kind: source.kind, duration: duration, loops: loops,
                           metadata: Self.describe(properties))
        }
    }

    func oriented(_ source: Source, _ index: Int) throws -> CGImage {
        let image = try source.decode(index)
        let orientation = source.properties(index)[kCGImagePropertyOrientation as String] as? Int32 ?? 1
        guard (2...8).contains(orientation) else { return image }
        let transformed = CIImage(cgImage: image).oriented(forExifOrientation: orientation)
        let space = image.colorSpace?.model == .rgb ? image.colorSpace : nil
        guard let result = context.createCGImage(transformed, from: transformed.extent,
                                                  format: image.bitsPerComponent > 8 ? .RGBA16 : .RGBA8,
                                                  colorSpace: space ?? Self.sRGB) else { throw ImageFailure.render }
        return result
    }

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private static func describe(_ values: [String: Any]) -> String {
        values.keys.sorted().compactMap { key in
            guard let value = values[key], !(value is Data) else { return nil }
            if let fields = value as? [String: Any] {
                let lines = fields.keys.sorted().compactMap { field -> String? in
                    guard let detail = fields[field], !(detail is Data) else { return nil }
                    return "  \(field)  \(detail)"
                }
                return ([key] + lines).joined(separator: "\n")
            }
            return "\(key)  \(value)"
        }.joined(separator: "\n")
    }
}
