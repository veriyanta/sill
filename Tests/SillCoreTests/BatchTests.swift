import Foundation
import SillCore
import UniformTypeIdentifiers

private actor BatchLog {
    private(set) var events: [BatchEvent] = []
    func record(_ event: BatchEvent) { events.append(event) }
}

struct BatchTests {
    func testAdditionalViewFormats() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let webp = folder.appending(path: "sample.webp")
        let bytes = try require(Data(base64Encoded: "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA"))
        try bytes.write(to: webp)
        let ico = folder.appending(path: "sample.ico")
        try fixture(ico, type: try require(UTType(filenameExtension: "ico")), width: 32, height: 32)
        let pipeline = Pipeline()
        let web = try await pipeline.view(Asset(webp))
        equal(web.width, 1)
        equal(web.type, "org.webmproject.webp")
        let icon = try await pipeline.view(Asset(ico))
        equal(icon.type, "com.microsoft.ico")
    }

    func testBatch() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appending(path: "output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        for (name, type) in [("10.tiff", UTType.tiff), ("2.jpg", .jpeg), ("1.png", .png)] {
            try fixture(folder.appending(path: name), type: type)
        }
        try Data("bad image".utf8).write(to: folder.appending(path: "3.png"))
        let inputs = try Library.list(folder)
        let pipeline = Pipeline()
        let log = BatchLog()
        try await pipeline.batch(inputs, to: output, naming: BatchNaming(prefix: "Proof-", sequential: true),
                                 edits: [.resize(maxEdge: 45)], options: ExportOptions()) {
            await log.record($0)
        }
        let events = await log.events
        equal(events.count, 4)
        let expected = ["Proof-1.png", "Proof-2.png", "Proof-4.png"]
        let actual = try FileManager.default.contentsOfDirectory(atPath: output.path).sorted()
        equal(actual, expected)
        guard case .failed(let badInput, _) = events[2] else { throw CheckFailure("Expected corrupt input to fail.") }
        equal(badInput.name, "3.png")
        for file in actual {
            let result = try await pipeline.view(Asset(output.appending(path: file)))
            equal(result.width, 45)
            equal(result.height, 30)
        }
        do {
            try await pipeline.batch(inputs, to: folder, naming: BatchNaming(),
                                     options: ExportOptions(format: .original, collision: .overwrite)) { _ in }
            throw CheckFailure("Unsafe batch overwrite succeeded.")
        } catch is ImageFailure {}
    }

    func testCancellation() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appending(path: "output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        for name in ["a.png", "b.png"] { try fixture(folder.appending(path: name), type: .png) }
        let inputs = try Library.list(folder)
        let pipeline = Pipeline()
        do {
            try await Task {
                try await pipeline.batch(inputs, to: output, naming: BatchNaming(), options: ExportOptions()) { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }.value
            throw CheckFailure("Expected cancellation to stop the batch.")
        } catch is CancellationError {}
        equal(try FileManager.default.contentsOfDirectory(atPath: output.path), ["a.png"])
    }
}
