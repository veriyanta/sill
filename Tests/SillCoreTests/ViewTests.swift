import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import SillCore

func fixtureImage(width: Int = 30, height: Int = 20, red: Bool = true) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(red: red ? 0.9 : 0.1, green: 0.35, blue: 0.6, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(red: 0, green: 0.85, blue: 0.05, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: max(1, width / 3), height: max(1, height / 3)))
    return context.makeImage()!
}

func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "SillTests-\(UUID())", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

func fixture(_ url: URL, type: UTType, frames: Int = 1, orientation: Int = 1,
             width: Int = 30, height: Int = 20) throws {
    let destination = try require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, frames, nil))
    if type == .gif || (type == .png && frames > 1) {
        let group = type == .gif ? kCGImagePropertyGIFDictionary : kCGImagePropertyPNGDictionary
        let loop = type == .gif ? kCGImagePropertyGIFLoopCount : kCGImagePropertyAPNGLoopCount
        CGImageDestinationSetProperties(destination, [group: [loop: 0]] as CFDictionary)
    }
    for index in 0..<frames {
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
        if type == .gif { properties[kCGImagePropertyGIFDictionary] = [kCGImagePropertyGIFDelayTime: 0.15] }
        if type == .png && frames > 1 {
            properties[kCGImagePropertyPNGDictionary] = [kCGImagePropertyAPNGDelayTime: 0.15]
        }
        CGImageDestinationAddImage(destination, fixtureImage(width: width, height: height, red: index.isMultiple(of: 2)), properties as CFDictionary)
    }
    expect(CGImageDestinationFinalize(destination))
}

struct ViewTests {
    func testBrowsingAndViewing() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try fixture(folder.appending(path: "10.jpg"), type: .jpeg, orientation: 6)
        try fixture(folder.appending(path: "2.png"), type: .png)
        try "hello".write(to: folder.appending(path: "ignore.txt"), atomically: true, encoding: .utf8)
        let files = try Library.list(folder)
        expect(files.map(\.name) == ["2.png", "10.jpg"])
        let pipeline = Pipeline()
        let picture = try await pipeline.view(files[1])
        expect(picture.width == 20)
        expect(picture.height == 30)
        expect(picture.type == UTType.jpeg.identifier)
        expect(picture.metadata.contains("Orientation"))
        let marker = try pixel(picture.image, x: 2, y: picture.height - 3)
        let opposite = try pixel(picture.image, x: picture.width - 3, y: 2)
        expect(Int(marker[1]) > Int(marker[0]) + 80, "The lower-left marker should rotate to upper left.")
        expect(Int(opposite[0]) > Int(opposite[1]) + 40, "The opposite corner should remain red.")
        let thumbnail = await Thumbnails().load(files[0])
        expect(thumbnail?.width == 30)
    }

    func testGIF() async throws { try await sequenceViewing(type: .gif) }
    func testAPNG() async throws { try await sequenceViewing(type: .png) }
    func testTIFF() async throws { try await sequenceViewing(type: .tiff) }

    private func sequenceViewing(type: UTType) async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "sample.\(type.preferredFilenameExtension!)")
        try fixture(url, type: type, frames: 2)
        let pipeline = Pipeline()
        let picture = try await pipeline.view(Asset(url), index: 1)
        expect(picture.index == 1)
        expect(picture.count == 2)
        expect(picture.kind == (type == .tiff ? .pages : .animation))
        if type != .tiff {
            expect(abs(picture.duration - 0.15) < 0.02)
            expect(picture.loops == 0)
        }
    }
}

private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 4)
    try bytes.withUnsafeMutableBytes { storage in
        let space = try require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try require(CGContext(data: storage.baseAddress, width: 1, height: 1,
                                              bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: -x, y: -y, width: image.width, height: image.height))
    }
    return bytes
}
