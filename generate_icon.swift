// PromptQy App icon — colorful squircle (WeCom-like blues) with the menu-bar
// speech-bubble + ^= motif from assets/. Used by build_app.sh:
//   swift generate_icon.swift <output.iconset>
//
// Spec (macos-app-icon skill): ~9% transparent margin → body ≈ 82%,
// superellipse n≈5, solid fill to the mask edge.

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

/// Speech bubble + ^= in the same proportions as `generate_menubar_icon.swift`,
/// mapped into `body` (AppKit y-up).
/// `insetRatio` shrinks the glyph inside the squircle (padding around the logo).
func drawLogo(in body: NSRect, strokeScale: CGFloat, insetRatio: CGFloat = 0.15) {
    let inset = min(body.width, body.height) * insetRatio
    let area = body.insetBy(dx: inset, dy: inset)
    let S = min(area.width, area.height)
    // Local 18pt design space → logo area pixels.
    let u = S / 18.0
    let cx = area.midX
    let cy = area.midY + 0.25 * u
    let radius = 7.4 * u
    let stroke = max(1.2, 1.65 * u * strokeScale)

    let white = NSColor.white.withAlphaComponent(0.96)
    white.setStroke()
    white.setFill()

    // Soft drop for depth (WeCom-style layered look).
    if S >= 64 {
        let shadow = NSColor.black.withAlphaComponent(0.18)
        shadow.setStroke()
        let tipAngle = CGFloat.pi * 1.28
        let halfTail: CGFloat = 0.18
        let tipR = radius + 1.85 * u
        let tip = NSPoint(
            x: cx + tipR * cos(tipAngle) + 0.6 * u,
            y: cy + tipR * sin(tipAngle) - 0.8 * u)
        let shadowPath = NSBezierPath()
        shadowPath.appendArc(
            withCenter: NSPoint(x: cx + 0.6 * u, y: cy - 0.8 * u),
            radius: radius,
            startAngle: (tipAngle + halfTail) * 180 / .pi,
            endAngle: (tipAngle - halfTail + 2 * .pi) * 180 / .pi,
            clockwise: false)
        shadowPath.line(to: tip)
        shadowPath.close()
        shadowPath.lineWidth = stroke
        shadowPath.lineCapStyle = .round
        shadowPath.lineJoinStyle = .round
        shadowPath.stroke()
    }

    white.setStroke()

    // Tail at bottom-left (~230°), y-up.
    let tipAngle = CGFloat.pi * 1.28
    let halfTail: CGFloat = 0.18
    let tipR = radius + 1.85 * u
    let tip = NSPoint(
        x: cx + tipR * cos(tipAngle),
        y: cy + tipR * sin(tipAngle))

    let bubble = NSBezierPath()
    bubble.appendArc(
        withCenter: NSPoint(x: cx, y: cy),
        radius: radius,
        startAngle: (tipAngle + halfTail) * 180 / .pi,
        endAngle: (tipAngle - halfTail + 2 * .pi) * 180 / .pi,
        clockwise: false)
    bubble.line(to: tip)
    bubble.close()
    bubble.lineWidth = stroke
    bubble.lineCapStyle = .round
    bubble.lineJoinStyle = .round
    bubble.stroke()

    // Caret "^"
    let caretX = cx - 2.4 * u
    let caretLift = 0.55 * u
    let caretTop = cy + 1.45 * u + caretLift
    let caretBot = cy - 2.05 * u + caretLift
    let caretHalf = 2.55 * u
    let caret = NSBezierPath()
    caret.move(to: NSPoint(x: caretX - caretHalf, y: caretBot))
    caret.line(to: NSPoint(x: caretX, y: caretTop))
    caret.line(to: NSPoint(x: caretX + caretHalf, y: caretBot))
    caret.lineWidth = stroke
    caret.lineCapStyle = .round
    caret.lineJoinStyle = .round
    caret.stroke()

    // Equals "="
    let eqX = cx + 2.8 * u
    let eqHalfW = 1.9 * u
    let eqGap = stroke + 1.35 * u
    for yOff in [-eqGap / 2, eqGap / 2] {
        let y = cy + yOff
        let bar = NSBezierPath()
        bar.move(to: NSPoint(x: eqX - eqHalfW, y: y))
        bar.line(to: NSPoint(x: eqX + eqHalfW, y: y))
        bar.lineWidth = stroke
        bar.lineCapStyle = .round
        bar.stroke()
    }
}

func drawIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    defer { img.unlockFocus() }

    let margin = size * 0.09
    let body = NSRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
    let bgPath = superellipsePath(in: body)
    bgPath.addClip()

    // WeCom-like multi-blue: sky → primary → deep indigo (top → bottom).
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.35, green: 0.72, blue: 0.98, alpha: 1.0),  // light sky
        NSColor(srgbRed: 0.18, green: 0.45, blue: 0.95, alpha: 1.0),  // brand blue
        NSColor(srgbRed: 0.12, green: 0.22, blue: 0.62, alpha: 1.0),  // deep indigo
    ])!
    gradient.draw(in: bgPath, angle: -90)

    // Cool cyan side wash (multi-color depth, not flat).
    let wash = NSGradient(colors: [
        NSColor(srgbRed: 0.20, green: 0.90, blue: 0.85, alpha: 0.22),
        NSColor(srgbRed: 0.20, green: 0.90, blue: 0.85, alpha: 0.0),
    ])!
    wash.draw(from: NSPoint(x: body.minX, y: body.maxY),
              to: NSPoint(x: body.midX, y: body.midY),
              options: [])

    // Slightly heavier stroke on tiny sizes so ^= remains legible.
    let strokeScale: CGFloat = size <= 32 ? 1.15 : 1.0
    drawLogo(in: body, strokeScale: strokeScale)

    // Top gloss.
    let highlight = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.22),
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
