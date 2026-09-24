// 生成 Scivane.icns：墨绿方砖 + 象牙折页 L 标志。
// 用法： swift scripts/make_icon.swift <输出目录>
// 产物：<输出目录>/ 下的 Scivane.iconset/、Scivane.icns、icon_1024.png
//
// 取代了早期的 make_icon.py（暖炭底+琥珀扇形），那版已随品牌更新弃用。
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let set = out.appendingPathComponent("Scivane.iconset")
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
func render(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(size)/1024, y: CGFloat(size)/1024)
    let tile = NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 198, yRadius: 198)
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.22); shadow.shadowBlurRadius = 24; shadow.shadowOffset = NSSize(width: 0, height: -9)
    NSGraphicsContext.saveGraphicsState(); shadow.set(); color(0.08,0.18,0.15).setFill(); tile.fill(); NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0.19,0.34,0.27), ending: color(0.055,0.15,0.12))!.draw(in: tile, angle: -75)
    color(0.8,0.86,0.73).withAlphaComponent(0.18).setStroke(); tile.lineWidth = 2; tile.stroke()
    // Shared normalized fold geometry, translated from the SwiftUI mark.
    func polygon(_ points: [(CGFloat, CGFloat)], _ fill: NSColor) {
        let path = NSBezierPath()
        for (i, point) in points.enumerated() {
            let p = NSPoint(x: 216 + point.0 * 592, y: 220 + (1-point.1) * 592)
            if i == 0 { path.move(to:p) } else { path.line(to:p) }
        }
        path.close(); fill.setFill(); path.fill()
    }
    polygon([(0.20,0.12),(0.46,0.04),(0.46,0.65),(0.83,0.54),(0.83,0.80),(0.20,0.98)], color(0.94,0.94,0.83))
    polygon([(0.50,0.16),(0.72,0.09),(0.72,0.51),(0.50,0.58)], color(0.56,0.72,0.58))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for size in [16,32,128,256,512] {
    try render(size).write(to: set.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size*2).write(to: set.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try render(1024).write(to: out.appendingPathComponent("icon_1024.png"))
let task = Process(); task.executableURL = URL(fileURLWithPath:"/usr/bin/iconutil")
task.arguments = ["-c", "icns", set.path, "-o", out.appendingPathComponent("Scivane.icns").path]
try task.run(); task.waitUntilExit()
guard task.terminationStatus == 0 else { exit(task.terminationStatus) }
print("→ \(out.appendingPathComponent("Scivane.icns").path)")
