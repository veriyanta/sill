import Foundation
import SillCore

struct RecursiveFolderTests {
    func testRecursiveScopeAndLimit() async throws {
        let fm = FileManager.default
        let root = try temporaryFolder()
        defer { try? fm.removeItem(at: root) }
        let main = root.appending(path: "Main", directoryHint: .isDirectory)
        let nested = main.appending(path: "Child/Grandchild", directoryHint: .isDirectory)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        let direct = main.appending(path: "root.png")
        try Data([0]).write(to: direct)
        let nestedImage = nested.appending(path: "nested.JPG")
        try Data([0]).write(to: nestedImage)
        try Data([0]).write(to: nested.appending(path: "ignored.txt"))
        try Data([0]).write(to: nested.appending(path: ".hidden.png"))
        try fm.createSymbolicLink(at: nested.appending(path: "link.png"), withDestinationURL: direct)
        try fm.createSymbolicLink(at: nested.appending(path: "loop"), withDestinationURL: main)

        equal(try Library.list(main).map(\.name), ["root.png"])
        let recursive = try Library.listRecursively(main, access: root)
        equal(recursive.map(\.name), ["nested.JPG", "root.png"])
        expect(recursive.allSatisfy { $0.folder == root })

        for i in 0..<(Library.recursiveImageLimit - recursive.count) {
            try fm.linkItem(at: direct, to: nested.appending(path: "extra-\(i).png"))
        }
        equal(try Library.listRecursively(main).count, Library.recursiveImageLimit)
        try fm.linkItem(at: direct, to: nested.appending(path: "too-many.png"))
        do {
            _ = try Library.listRecursively(main)
            throw CheckFailure("Recursive enumeration accepted an image beyond the cap.")
        } catch ImageFailure.recursiveImageLimit(let limit) {
            equal(limit, Library.recursiveImageLimit)
        }
        equal(try Library.list(main).map(\.name), ["root.png"])
    }
}
