// Draws the app icon: swift tools/make_icon.swift Resources/AppIcon.icns Resources/logo.png
import AppKit

guard CommandLine.arguments.count == 3, let logo = NSImage(contentsOfFile: CommandLine.arguments[2]), logo.size.width > 0 else {
    FileHandle.standardError.write(Data("usage: swift tools/make_icon.swift <out.icns> <logo.png>\n".utf8))
    exit(2)
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let s = CGFloat(px)
    let body = NSRect(x: s * 0.05, y: s * 0.05, width: s * 0.9, height: s * 0.9)
    let clip = NSBezierPath(roundedRect: body, xRadius: s * 0.2, yRadius: s * 0.2)
    NSColor(calibratedWhite: 254.0 / 255, alpha: 1).setFill(); clip.fill()
    NSColor(white: 0.80, alpha: 1).setStroke(); clip.lineWidth = max(1, s * 0.006); clip.stroke()
    let w = body.width * 0.78, h = w * logo.size.height / logo.size.width
    logo.draw(in: NSRect(x: body.midX - w / 2, y: body.midY - h / 2, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments[1]
let set = NSTemporaryDirectory() + "AppIcon.iconset"
try? FileManager.default.removeItem(atPath: set)
try! FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
var cache: [Int: Data] = [:]   // 16@2x == 32, 128@2x == 256, 256@2x == 512: render each pixel size once
func png(_ px: Int) -> Data { if let d = cache[px] { return d }; let d = render(px); cache[px] = d; return d }
for base in [16, 32, 128, 256, 512] {
    try! png(base).write(to: URL(fileURLWithPath: "\(set)/icon_\(base)x\(base).png"))
    try! png(base * 2).write(to: URL(fileURLWithPath: "\(set)/icon_\(base)x\(base)@2x.png"))
}
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set, "-o", out]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(atPath: set)
if p.terminationStatus != 0 { FileHandle.standardError.write(Data("iconutil failed\n".utf8)); exit(1) }
