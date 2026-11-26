import AppKit

let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func makeIcon(_ edge: Int) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: edge, height: edge, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(edge) / 1024
    context.scaleBy(x: scale, y: scale)
    let tile = CGPath(roundedRect: CGRect(x: 62, y: 62, width: 900, height: 900),
                      cornerWidth: 205, cornerHeight: 205, transform: nil)
    context.saveGState()
    context.addPath(tile)
    context.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [color(0x35544e), color(0x121e22)] as CFArray,
                              locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 180, y: 940), end: CGPoint(x: 800, y: 70), options: [])
    context.restoreGState()
    context.addPath(tile)
    context.setStrokeColor(color(0x48635c))
    context.setLineWidth(6)
    context.strokePath()
    let window = CGPath(roundedRect: CGRect(x: 225, y: 275, width: 574, height: 495),
                        cornerWidth: 67, cornerHeight: 67, transform: nil)
    context.addPath(window)
    context.setFillColor(color(0x101e21))
    context.fillPath()
    context.saveGState()
    context.addPath(window)
    context.clip()
    context.setFillColor(color(0xc9f8a9))
    context.fillEllipse(in: CGRect(x: 565, y: 575, width: 106, height: 106))
    let hills = CGMutablePath()
    hills.move(to: CGPoint(x: 180, y: 295))
    hills.addQuadCurve(to: CGPoint(x: 420, y: 545), control: CGPoint(x: 355, y: 536))
    hills.addQuadCurve(to: CGPoint(x: 592, y: 413), control: CGPoint(x: 474, y: 568))
    hills.addQuadCurve(to: CGPoint(x: 820, y: 497), control: CGPoint(x: 648, y: 331))
    hills.addLine(to: CGPoint(x: 820, y: 235))
    hills.addLine(to: CGPoint(x: 180, y: 235))
    hills.closeSubpath()
    context.addPath(hills)
    context.setFillColor(color(0x6eaf96))
    context.fillPath()
    context.restoreGState()
    context.addPath(window)
    context.setStrokeColor(color(0xb1ebc6))
    context.setLineWidth(34)
    context.strokePath()
    context.setFillColor(color(0xb1ebc6))
    context.addPath(CGPath(roundedRect: CGRect(x: 187, y: 212, width: 650, height: 32),
                           cornerWidth: 16, cornerHeight: 16, transform: nil))
    context.fillPath()
    return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try makeIcon(size).write(to: base.appending(path: "icon_\(size)x\(size).png"))
    try makeIcon(size * 2).write(to: base.appending(path: "icon_\(size)x\(size)@2x.png"))
}
