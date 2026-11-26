import Foundation

struct CheckFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

func require<T>(_ value: T?, file: StaticString = #fileID, line: UInt = #line) throws -> T {
    guard let value else { throw CheckFailure("\(file):\(line) expected a value") }
    return value
}

func expect(_ condition: @autoclosure () throws -> Bool, _ detail: String = "",
            file: StaticString = #fileID, line: UInt = #line) {
    do {
        if try condition() { return }
    } catch {
        fatalError("\(file):\(line) \(error)")
    }
    fatalError("\(file):\(line) assertion failed \(detail)")
}

func equal<T: Equatable>(_ actual: @autoclosure () throws -> T, _ expected: T,
                          file: StaticString = #fileID, line: UInt = #line) {
    do {
        let value = try actual()
        expect(value == expected, "got \(value), expected \(expected)", file: file, line: line)
    } catch {
        fatalError("\(file):\(line) \(error)")
    }
}

@main
struct Checks {
    static func main() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--make-viewer-fixtures" {
            try makeViewerFixtures(URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
            return
        }
        let view = ViewTests()
        try await run("Browse and view JPEG and PNG", view.testBrowsingAndViewing)
        try await run("Recursive folders, scope, symlinks, and the 4,096-image cap", RecursiveFolderTests().testRecursiveScopeAndLimit)

        try await run("View GIF frames", view.testGIF)
        try await run("View APNG frames", view.testAPNG)
        try await run("View TIFF pages", view.testTIFF)
        let export = ExportTests()
        try await run("Core Image edits and still codecs", export.testStillFormats)
        try await run("GIF, APNG and TIFF sequence export", export.testSequenceExport)
        try await run("Exact copy, collisions and atomic replacement", export.testCopyCollisionAndAtomicReplacement)
        try await run("JPEG EXIF and GPS retention", export.testCameraMetadataAndOrientation)
        let batch = BatchTests()
        try await run("View WebP and ICO", batch.testAdditionalViewFormats)
        try await run("Batch ordering, partial failure and overlap protection", batch.testBatch)
        try await run("Batch cancellation keeps already published files", batch.testCancellation)
    }

    static func run(_ name: String, _ body: () async throws -> Void) async throws {
        FileHandle.standardError.write(Data("RUN   \(name)\n".utf8))

        try await body()
        print("PASS  \(name)")
    }
}
