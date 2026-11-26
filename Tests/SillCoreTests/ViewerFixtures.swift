import Foundation
import UniformTypeIdentifiers

func makeViewerFixtures(_ root: URL) throws {
    let fm = FileManager.default
    let browse = root.appending(path: "browse")
    let workload = root.appending(path: "mixed-2000")
    let templates = root.appending(path: "templates")
    for folder in [browse, workload, templates] {
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    try fixture(browse.appending(path: "1 Rotated.jpg"), type: .jpeg, orientation: 6, width: 900, height: 600)
    try Data("intentionally corrupt PNG".utf8).write(to: browse.appending(path: "2 Corrupt.png"))
    try fixture(browse.appending(path: "10 Healthy.png"), type: .png, width: 640, height: 480)

    let codecs: [(UTType, String, Int, Int, Int)] = [
        (.jpeg, "jpg", 1920, 1080, 1),
        (.png, "png", 1280, 720, 1),
        (.tiff, "tiff", 640, 480, 2),
        (.heic, "heic", 1280, 960, 1),
        (.gif, "gif", 256, 192, 3)
    ]
    var inputs: [URL] = []
    for (codec, ext, width, height, frames) in codecs {
        let url = templates.appending(path: "image.\(ext)")
        try fixture(url, type: codec, frames: frames, width: width, height: height)
        inputs.append(url)
    }
    let webp = templates.appending(path: "image.webp")
    let bytes = try require(Data(base64Encoded: "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA"))
    try bytes.write(to: webp)
    inputs.append(webp)

    for index in 1...2000 {
        let input = inputs[(index - 1) % inputs.count]
        let destination = workload.appending(path: "\(index).\(input.pathExtension)")
        try fm.copyItem(at: input, to: destination)
    }
}
