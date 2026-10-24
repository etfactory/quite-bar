import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let iconset = output.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (points, scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    let px = points * scale
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    let bg = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 210, yRadius: 210)
    let gradient = NSGradient(starting: NSColor(srgbRed: 0.24, green: 0.59, blue: 0.45, alpha: 1),
                              ending: NSColor(srgbRed: 0.09, green: 0.31, blue: 0.25, alpha: 1))!
    gradient.draw(in: bg, angle: -70)
    NSColor.white.withAlphaComponent(0.22).setStroke()
    let line = NSBezierPath()
    line.lineWidth = 35
    line.lineCapStyle = .round
    line.move(to: NSPoint(x: 400, y: 320)); line.line(to: NSPoint(x: 400, y: 704)); line.stroke()
    NSColor.white.setStroke()
    let arrow = NSBezierPath()
    arrow.lineWidth = 65
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 665, y: 350)); arrow.line(to: NSPoint(x: 510, y: 512)); arrow.line(to: NSPoint(x: 665, y: 674)); arrow.stroke()
    NSGraphicsContext.restoreGraphicsState()
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try bitmap.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
}
// ICNS is a chunk container; writing it directly avoids external image tooling.
// ICNS는 청크 기반 컨테이너이므로 외부 이미지 도구 없이 직접 기록합니다.
func bigEndian(_ number: Int) -> Data {
    var value = UInt32(number).bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}
let chunks = [("icp4", "16x16"), ("ic11", "16x16@2x"), ("icp5", "32x32"),
              ("ic12", "32x32@2x"), ("ic07", "128x128"), ("ic13", "128x128@2x"),
              ("ic08", "256x256"), ("ic14", "256x256@2x"), ("ic09", "512x512"), ("ic10", "512x512@2x")]
var body = Data()
for (type, name) in chunks {
    let png = try Data(contentsOf: iconset.appendingPathComponent("icon_\(name).png"))
    body.append(Data(type.utf8)); body.append(bigEndian(png.count + 8)); body.append(png)
}
var icns = Data("icns".utf8)
icns.append(bigEndian(body.count + 8)); icns.append(body)
try icns.write(to: output.appendingPathComponent("AppIcon.icns"))
print(output.appendingPathComponent("AppIcon.icns").path)
