import AppKit
import Foundation
import SillCore
import UniformTypeIdentifiers

struct RecentFile: Codable, Identifiable {
    let displayPath: String
    let bookmark: Data?
    var id: String { displayPath }
    var name: String { URL(fileURLWithPath: displayPath).lastPathComponent }
}

enum RecentFiles {
    private static let key = "recentImageBookmarks"
    private static let limit = 12

    static func load() -> [RecentFile] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([RecentFile].self, from: data) else { return [] }
        return items
    }

    static func save(_ items: [RecentFile]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(Array(items.prefix(limit))), forKey: key)
    }

    static func adding(_ url: URL, to items: [RecentFile]) -> [RecentFile] {
        let path = url.path
        let bookmark = try? withAccess(url) {
            try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                 includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        let previous = items.first { $0.displayPath == path }
        let record = RecentFile(displayPath: path, bookmark: bookmark ?? previous?.bookmark)
        return Array(([record] + items.filter { $0.displayPath != path }).prefix(limit))
    }
}

extension Workspace {
    func rememberOpenedFile(_ asset: Asset) {
        recents = RecentFiles.adding(asset.url, to: recents)
        RecentFiles.save(recents)
    }

    func openRecent(_ recent: RecentFile) {
        if let bookmark = recent.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                openFiles([url])
                return
            }
        }
        let url = URL(fileURLWithPath: recent.displayPath)
        if FileManager.default.isReadableFile(atPath: url.path) {
            openFiles([url])
        } else {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.directoryURL = url.deletingLastPathComponent()
            panel.message = "Select \(recent.name) to restore access."
            if panel.runModal() == .OK { openFiles(panel.urls) }
        }
    }

    func clearRecents() {
        recents = []
        RecentFiles.save([])
    }
}
