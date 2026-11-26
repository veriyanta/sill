import Foundation

public struct BatchNaming: Sendable {
    public var prefix: String
    public var sequential: Bool

    public init(prefix: String = "", sequential: Bool = false) {
        self.prefix = prefix
        self.sequential = sequential
    }

    public func name(_ asset: Asset, offset: Int, format: ExportFormat) -> String {
        let basename = prefix + (sequential ? String(offset + 1) : asset.url.deletingPathExtension().lastPathComponent)
        let ext = format.filename(extensionOf: asset)
        return ext.isEmpty ? basename : "\(basename).\(ext)"
    }
}

public enum BatchEvent: Sendable {
    case written(Asset, URL)
    case skipped(Asset)
    case failed(Asset, String)
}

public extension Pipeline {
    /// Runs jobs serially. Each event describes one completed attempt.
    func batch(_ inputs: [Asset], to folder: URL, naming: BatchNaming,
                           edits: [Edit] = [], options: ExportOptions,
                           progress: @Sendable (BatchEvent) async -> Void) async throws {
        let targets = inputs.enumerated().map { naming.name($0.element, offset: $0.offset, format: options.format) }
        let normalize: (URL) -> String = {
            $0.resolvingSymlinksInPath().standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
        }
        if options.collision == .overwrite {
            let sourcePaths = Set(inputs.map { input in withAccess(input.folder ?? input.url) { normalize(input.url) } })
            let targetPaths = try withAccess(folder) {
                try targets.map { name in
                    try Self.validate(name)
                    return normalize(folder.appending(path: name))
                }
            }
            guard Set(targetPaths).count == targetPaths.count else {
                throw ImageFailure.invalid("Multiple inputs have the same output name. Enable sequential numbering.")
            }
            guard sourcePaths.isDisjoint(with: targetPaths) else {
                throw ImageFailure.invalid("A batch export can’t replace a batch input. Choose a different folder or naming pattern.")
            }
        }
        for (asset, name) in zip(inputs, targets) {
            try Task.checkCancellation()
            let event: BatchEvent
            do {
                if let url = try export(asset, to: folder, named: name, edits: edits, options: options) {
                    event = .written(asset, url)
                } else {
                    event = .skipped(asset)
                }
            } catch is CancellationError { throw CancellationError() }
            catch { event = .failed(asset, error.localizedDescription) }
            await progress(event)
        }
    }
}
