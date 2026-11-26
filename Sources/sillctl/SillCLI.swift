import Darwin
import Foundation
import SillCore

private let usage = """
Sill command-line image utility

  sillctl info FILE
  sillctl export INPUT --to FOLDER [--name FILENAME] [OPTIONS]
  sillctl batch INPUT_FOLDER --to FOLDER [--prefix TEXT] [--number] [OPTIONS]

Options
  --format original|jpeg|png|tiff|heic|bmp|gif   Default png
  --quality 0...1                               Default 0.9
  --keep-metadata                               Keep supported camera fields and GPS
  --all                                         Export all frames or pages when compatible
  --frame NUMBER                                Select a one-based frame or page for export
  --rotate-right | --rotate-left | --flip-horizontal | --flip-vertical | --grayscale
  --resize PIXELS                               Set long edge
  --crop X,Y,WIDTH,HEIGHT                        Fractions from the bottom-left
  --brightness -1...1 | --contrast 0.25...4
  --skip-existing | --overwrite                 Default keeps both files

Repeat edit flags to apply edits in order. Exit status is nonzero for invalid commands or failed jobs.
"""

private struct Invocation {
    let action: String
    let input: URL
    var output: URL?
    var name: String?
    var naming = BatchNaming()
    var index = 0
    var edits: [Edit] = []
    var options = ExportOptions()

    init(_ args: [String]) throws {
        var args = args[...]
        guard let action = args.popFirst(), ["info", "export", "batch"].contains(action),
              let path = args.popFirst() else { throw ImageFailure.invalid(usage) }
        self.action = action
        input = URL(fileURLWithPath: path)

        func value(_ flag: String) throws -> String {
            guard let text = args.popFirst(), !text.hasPrefix("--") else {
                throw ImageFailure.invalid("Missing value for \(flag).")
            }
            return text
        }

        func decimal(_ flag: String, range: ClosedRange<Double>) throws -> Double {
            guard let result = Double(try value(flag)), range.contains(result) else {
                throw ImageFailure.invalid("Invalid value for \(flag).")
            }
            return result
        }

        func collision(_ option: Collision) throws {
            guard options.collision == .keepBoth || options.collision == option else {
                throw ImageFailure.invalid("Choose one collision policy.")
            }
            options.collision = option
        }

        while let flag = args.popFirst() {
            guard action != "info" else { throw ImageFailure.invalid("info accepts a single file.") }
            switch flag {
            case "--to": output = URL(fileURLWithPath: try value(flag), isDirectory: true)
            case "--name" where action == "export": name = try value(flag)
            case "--prefix" where action == "batch": naming.prefix = try value(flag)
            case "--number" where action == "batch": naming.sequential = true
            case "--format":
                guard let format = ExportFormat(rawValue: try value(flag)), format.available else {
                    throw ImageFailure.invalid("Unknown or unavailable format.")
                }
                options.format = format
            case "--quality": options.quality = try decimal(flag, range: 0...1)
            case "--keep-metadata": options.preserveMetadata = true
            case "--all": options.allImages = true
            case "--frame" where action == "export":
                guard let frame = Int(try value(flag)), frame > 0 else { throw ImageFailure.invalid("Invalid frame number.") }
                index = frame - 1
            case "--rotate-right": edits.append(.rotateRight)
            case "--rotate-left": edits.append(.rotateLeft)
            case "--flip-horizontal": edits.append(.flipHorizontal)
            case "--flip-vertical": edits.append(.flipVertical)
            case "--grayscale": edits.append(.grayscale)
            case "--resize":
                guard let edge = Int(try value(flag)), (1...32_768).contains(edge) else {
                    throw ImageFailure.invalid("Invalid long edge.")
                }
                edits.append(.resize(maxEdge: edge))
            case "--crop":
                let fields = try value(flag).split(separator: ",", omittingEmptySubsequences: false)
                let coords = fields.compactMap { Double($0) }
                guard fields.count == 4, coords.count == 4, coords.allSatisfy({ (0...1).contains($0) }),
                      coords[2] > 0, coords[3] > 0, coords[0] + coords[2] <= 1, coords[1] + coords[3] <= 1 else {
                    throw ImageFailure.invalid("Enter four crop fractions inside the image.")
                }
                edits.append(.crop(CGRect(x: coords[0], y: coords[1], width: coords[2], height: coords[3])))
            case "--brightness": edits.append(.brightness(try decimal(flag, range: -1...1)))
            case "--contrast": edits.append(.contrast(try decimal(flag, range: 0.25...4)))
            case "--skip-existing": try collision(.skip)
            case "--overwrite": try collision(.overwrite)
            default: throw ImageFailure.invalid("Unknown option \(flag).")
            }
        }
        if options.format == .original && (!edits.isEmpty || index != 0 || options.allImages) {
            throw ImageFailure.invalid("Exact copies operate on the whole original file.")
        }
        if options.allImages && index != 0 { throw ImageFailure.invalid("Choose either --all or --frame.") }
    }
}

private actor Reporter {
    var failures = 0

    func record(_ event: BatchEvent) {
        switch event {
        case .written(_, let output): print(output.path)
        case .skipped(let asset): print("Skipped \(asset.name)")
        case .failed(let asset, let reason):
            failures += 1
            FileHandle.standardError.write(Data("\(asset.name) — \(reason)\n".utf8))
        }
    }
}

@main
struct SillCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--help"] || args == ["-h"] { print(usage); return }
        do {
            let command = try Invocation(args)
            let pipeline = Pipeline()
            let asset = Asset(command.input)
            if command.action == "info" {
                let picture = try await pipeline.view(asset)
                print("\(asset.name)\n\(picture.type)\n\(picture.width) × \(picture.height) px\n\(picture.count) image(s)\n\(picture.metadata)")
                return
            }
            guard let folder = command.output,
                  try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw ImageFailure.invalid("Select an existing destination folder with --to.")
            }
            if command.action == "batch" {
                let inputs = try Library.list(command.input)
                guard !inputs.isEmpty else { throw ImageFailure.invalid("No supported image files were found.") }
                let reporter = Reporter()
                try await pipeline.batch(inputs, to: folder, naming: command.naming, edits: command.edits,
                                         options: command.options) { event in await reporter.record(event) }
                if await reporter.failures > 0 { exit(1) }
            } else {
                let fallback = BatchNaming(prefix: "").name(asset, offset: 0, format: command.options.format)
                let written = try await pipeline.export(asset, to: folder, named: command.name ?? fallback,
                                                        index: command.index, edits: command.edits, options: command.options)
                print(written?.path ?? "Skipped \(asset.name)")
            }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
