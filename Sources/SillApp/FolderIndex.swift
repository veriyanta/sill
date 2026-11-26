import Darwin
import Foundation
import SillCore

struct DiskLocation: Identifiable, Sendable {
    let url: URL
    let name: String
    var id: URL { url }
}

actor FolderIndex {
    func volumes() -> [DiskLocation] {
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        var volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeLocalizedNameKey],
                                                             options: [.skipHiddenVolumes]) ?? []
        if !volumes.contains(where: { $0.path == "/" }) { volumes.insert(root, at: 0) }
        return Self.sorted(volumes).map { url in
            let name = (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName
            return DiskLocation(url: url, name: name ?? (url.path == "/" ? "Startup Disk" : url.lastPathComponent))
        }
    }

    func images(_ folder: URL, access: URL?, includingSubfolders: Bool) throws -> [Asset] {
        try Task.checkCancellation()
        if includingSubfolders { return try Library.listRecursively(folder, access: access) }
        return try Library.list(folder, access: access)
    }

    func siblings(of file: Asset, in folder: URL, access: URL?) throws -> [Asset] {
        try Task.checkCancellation()
        let items = try Library.list(folder, access: access, requireReadableEntries: true)
        // A directory can be listable even if its files are outside the sandbox.
        if items.count > 1, let index = items.firstIndex(where: { $0.url.standardizedFileURL.path == file.url.standardizedFileURL.path }) {
            for offset in Set([1, items.count - 1]) {
                let candidate = items[(index + offset) % items.count]
                do {
                    try withAccess(candidate.folder ?? folder) {
                        let handle = try FileHandle(forReadingFrom: candidate.url)
                        try handle.close()
                    }
                } catch where Self.permissionDenied(error) {
                    throw error
                } catch {
                    // Unreadable or deleted images use the viewer’s normal recovery.
                }
            }
        }
        return items
    }

    func directories(_ folder: URL, access: URL?) throws -> [URL] {
        try Task.checkCancellation()
        return try withAccess(access ?? folder) {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
            let entries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys),
                                                                       options: [.skipsHiddenFiles])
            return Self.sorted(entries.filter {
                guard let values = try? $0.resourceValues(forKeys: keys) else { return false }
                return values.isDirectory == true && values.isPackage != true && values.isSymbolicLink != true
            })
        }
    }

    static func permissionDenied(_ error: Error) -> Bool {
        let underlying = error as NSError
        if underlying.domain == NSCocoaErrorDomain && underlying.code == NSFileReadNoPermissionError { return true }
        if underlying.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(underlying.code) { return true }
        return (underlying.userInfo[NSUnderlyingErrorKey] as? NSError).map { permissionDenied($0) } ?? false
    }

    private static func sorted(_ urls: [URL]) -> [URL] {
        urls.sorted {
            let order = $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
    }
}
