// Programmatically draw the PromptQy app icon at every iconset size.
// Theme: a text-input field with a chevron prompt and a caret — evoking the
// composer that feeds a terminal. Used by build_app.sh:
//   swift generate_icon.swift <output.iconset>

import AppKit
import Foundation

let sizes: [(px: Int, name: String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

// Superellipse (squircle) path matching the macOS Big Sur+ continuous corners.
func superellipsePath(in rect: NSRect, n: CGFloat = 5) -> NSBezierPath {
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let path = NSBezierPath()
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * copysign(pow(abs(ct), 2 / n), ct)
        let y = cy + b * copysign(pow(abs(st), 2 / n), st)
        if i == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
    }
    path.close()
    return path
}

func drawIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    defer { img.unlockFocus() }

    // Body inset to ~82% so it doesn't dwarf stock Dock icons.
    let margin = size * 0.09
    let body = NSRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
    let bgPath = superellipsePath(in: body)
    bgPath.addClip()

    // Gradient: teal → indigo (top to bottom).
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.10, green: 0.42, blue: 0.52, alpha: 1.0),
        NSColor(srgbRed: 0.18, green: 0.20, blue: 0.44, alpha: 1.0),
    ])!
    gradient.draw(in: bgPath, angle: -90)

    // Input field: a rounded rect roughly centered in the body.
    let fieldW = body.width * 0.62
    let fieldH = body.height * 0.30
    let field = NSRect(
        x: body.midX - fieldW / 2,
        y: body.midY - fieldH / 2,
        width: fieldW, height: fieldH)
    let fieldRadius = fieldH * 0.28
    NSColor.white.withAlphaComponent(0.95).setFill()
    NSBezierPath(roundedRect: field, xRadius: fieldRadius, yRadius: fieldRadius).fill()

    // Chevron prompt ">" on the left inside the field.
    let inset = field.height * 0.30
    let chevW = field.height * 0.26
    let cx0 = field.minX + field.width * 0.14
    let cyMid = field.midY
    let chev = NSBezierPath()
    chev.move(to: NSPoint(x: cx0, y: cyMid + inset))
    chev.line(to: NSPoint(x: cx0 + chevW, y: cyMid))
    chev.line(to: NSPoint(x: cx0, y: cyMid - inset))
    chev.lineWidth = max(1, field.height * 0.10)
    chev.lineCapStyle = .round
    chev.lineJoinStyle = .round
    NSColor(srgbRed: 0.14, green: 0.22, blue: 0.40, alpha: 1.0).setStroke()
    chev.stroke()

    // Blinking caret bar to the right of the prompt.
    let caretW = field.height * 0.11
    let caretH = field.height * 0.52
    let caret = NSRect(
        x: cx0 + chevW + field.width * 0.10,
        y: field.midY - caretH / 2,
        width: caretW, height: caretH)
    NSColor(srgbRed: 0.14, green: 0.22, blue: 0.40, alpha: 1.0).setFill()
    NSBezierPath(roundedRect: caret, xRadius: caretW / 2, yRadius: caretW / 2).fill()

    // Top-edge glossy highlight.
    let highlight = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.16),
        NSColor.white.withAlphaComponent(0.0),
    ])!
    highlight.draw(in: bgPath, angle: -90)

    return img
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(
        "usage: swift generate_icon.swift <iconset-dir>\n".data(using: .utf8)!)
    exit(1)
}
let outputDir = args[1]
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

for entry in sizes {
    let img = drawIcon(size: CGFloat(entry.px))
    guard let tiff = img.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:])
    else {
        FileHandle.standardError.write("failed to encode \(entry.name)\n".data(using: .utf8)!)
        exit(1)
    }
    try png.write(to: URL(fileURLWithPath: "\(outputDir)/\(entry.name)"))
    print("  \(entry.name) (\(entry.px)px)")
}
