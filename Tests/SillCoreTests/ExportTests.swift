import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import SillCore

struct ExportTests {
    func testStillFormats() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appending(path: "input.png")
        try fixture(input, type: .png)
        let pipeline = Pipeline()
        let asset = Asset(input)
        let edits: [Edit] = [.rotateRight, .crop(CGRect(x: 0, y: 0, width: 0.5, height: 1)),
                             .flipHorizontal, .grayscale, .brightness(0.1), .contrast(1.2), .resize(maxEdge: 60)]
        let picture = try await pipeline.view(asset)
        let preview = try await pipeline.preview(picture, edits: edits)
        equal(preview.width, 20)
        equal(preview.height, 60)
        for format in ExportFormat.allCases where format != .original {
            expect(format.available, "\(format) writer missing")
            let written = try await pipeline.export(asset, to: folder, named: "output.\(format.filename(extensionOf: asset))",
                                                    edits: edits, options: ExportOptions(format: format))
            let output = try require(written)
            let result = try await pipeline.view(Asset(output))
            equal(result.type, format.type?.identifier)
            equal(result.width, preview.width)
            equal(result.height, preview.height)
        }
    }

    func testSequenceExport() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pipeline = Pipeline()
        for (type, format) in [(UTType.gif, ExportFormat.gif), (.gif, .png), (.tiff, .tiff)] {
            let input = folder.appending(path: "\(UUID()).\(type.preferredFilenameExtension!)")
            try fixture(input, type: type, frames: 3)
            let asset = Asset(input)
            let written = try await pipeline.export(asset, to: folder, named: "sequence.\(format.filename(extensionOf: asset))",
                                                    edits: [.rotateLeft],
                                                    options: ExportOptions(format: format, allImages: true))
            let result = try await pipeline.view(Asset(require(written)), index: 2)
            equal(result.count, 3)
            equal(result.width, 20)
            equal(result.height, 30)
            if type == .gif {
                equal(result.kind, .animation)
                expect(abs(result.duration - 0.15) < 0.02)
                equal(result.loops, 0)
            } else {
                equal(result.kind, .pages)
            }
        }
    }

    func testCopyCollisionAndAtomicReplacement() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appending(path: "input.jpg")
        try fixture(input, type: .jpeg, orientation: 6)
        let original = try Data(contentsOf: input)
        let pipeline = Pipeline()
        let first = try await pipeline.export(Asset(input), to: folder, named: "input.jpg",
                                              options: ExportOptions(format: .original))
        equal(first?.lastPathComponent, "input 2.jpg")
        equal(try Data(contentsOf: require(first)), original)
        let skipped = try await pipeline.export(Asset(input), to: folder, named: "input.jpg",
                                                options: ExportOptions(format: .original, collision: .skip))
        expect(skipped == nil)
        equal(try Data(contentsOf: input), original)
        do {
            _ = try await pipeline.export(Asset(input), to: folder, named: "input.jpg",
                                           edits: [.crop(.zero)],
                                           options: ExportOptions(format: .jpeg, collision: .overwrite))
            expect(false, "Invalid edit unexpectedly succeeded")
        } catch is ImageFailure {}
        equal(try Data(contentsOf: input), original)
        let replaced = try await pipeline.export(Asset(input), to: folder, named: "input.jpg",
                                                  edits: [.resize(maxEdge: 60)],
                                                  options: ExportOptions(format: .jpeg, collision: .overwrite))
        equal(replaced?.path, input.path)
        let result = try await pipeline.view(Asset(input))
        equal(result.height, 60)
        let items = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        equal(Set(items), Set(["input.jpg", "input 2.jpg"]))
    }

    func testCameraMetadataAndOrientation() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appending(path: "input.jpg")
        let source = try require(CGImageDestinationCreateWithURL(input as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(source, fixtureImage(), [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:01:03 10:00:01"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 10.7, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 12.4, kCGImagePropertyGPSLongitudeRef: "E"]
        ] as CFDictionary)
        expect(CGImageDestinationFinalize(source))
        let pipeline = Pipeline()
        for keep in [false, true] {
            let url = try await pipeline.export(Asset(input), to: folder, named: "metadata-\(keep).jpg",
                                                options: ExportOptions(format: .jpeg, preserveMetadata: keep))
            let output = try await pipeline.view(Asset(require(url)))
            equal(output.width, 20)
            equal(output.height, 30)
            equal(output.metadata.contains("2024:01:03 10:00:01"), keep)
            equal(output.metadata.contains("{GPS}"), keep)
        }
    }
}
