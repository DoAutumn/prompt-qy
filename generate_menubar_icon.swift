// Crisp menu-bar template icon (speech bubble + ^ =).
// Draws each scale natively via CGBitmapContext (no AppKit flip surprises).
//
//   swift generate_menubar_icon.swift [output-dir]
//
// Writes MenuBarIcon.png (18), @2x (36), @3x (54), and -source (114).

import AppKit
import Foundation

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "assets")

let pointSize: CGFloat = 18
let strokePoints: CGFloat = 1.65

func drawTemplate(in ctx: CGContext) {
    ctx.setShouldAntialias(true)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    ctx.setStrokeColor(NSColor.black.cgColor)
    ctx.setLineWidth(strokePoints)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    let cx = pointSize / 2
    let cy = pointSize / 2 + 0.25
    let radius: CGFloat = 6.85

    // Tail at bottom-left — a bit longer + narrower mouth → sharper tip.
    let tipAngle = CGFloat.pi * 1.28
    let halfTail: CGFloat = 0.18
    let tipR = radius + 1.85
    let tip = CGPoint(
        x: cx + tipR * cos(tipAngle),
        y: cy + tipR * sin(tipAngle))

    let path = CGMutablePath()
    path.addArc(
        center: CGPoint(x: cx, y: cy),
        radius: radius,
        startAngle: tipAngle + halfTail,
        endAngle: tipAngle - halfTail + 2 * .pi,
        clockwise: false)
    path.addLine(to: tip)
    path.closeSubpath()
    ctx.addPath(path)
    ctx.strokePath()

    // Caret "^" — shallow/wide; nudged slightly upward.
    let caretX = cx - 2.4
    let caretLift: CGFloat = 0.55
    let caretTop = cy + 1.45 + caretLift
    let caretBot = cy - 2.05 + caretLift
    let caretHalf: CGFloat = 2.55
    ctx.beginPath()
    ctx.move(to: CGPoint(x: caretX - caretHalf, y: caretBot))
    ctx.addLine(to: CGPoint(x: caretX, y: caretTop))
    ctx.addLine(to: CGPoint(x: caretX + caretHalf, y: caretBot))
    ctx.strokePath()

    // Equals "=" — center gap must exceed stroke width or bars visually merge.
    let eqX = cx + 2.8
    let eqHalfW: CGFloat = 1.9
    let eqGap: CGFloat = strokePoints + 1.35  // clear space ≈ 1.35pt
    for yOff in [-eqGap / 2, eqGap / 2] as [CGFloat] {
        let y = cy + yOff
        ctx.beginPath()
        ctx.move(to: CGPoint(x: eqX - eqHalfW, y: y))
        ctx.addLine(to: CGPoint(x: eqX + eqHalfW, y: y))
        ctx.strokePath()
    }
}

func render(pixels: Int) -> NSBitmapImageRep {
    let px = pixels
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: px,
        height: px,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fputs("CGContext failed\n", stderr)
        exit(1)
    }
    ctx.clear(CGRect(x: 0, y: 0, width: px, height: px))
    // Map point space → pixels (CG is already y-up).
    ctx.scaleBy(x: CGFloat(px) / pointSize, y: CGFloat(px) / pointSize)
    drawTemplate(in: ctx)
    guard let cgImage = ctx.makeImage() else {
        fputs("makeImage failed\n", stderr)
        exit(1)
    }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    rep.size = NSSize(width: pointSize, height: pointSize)
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, name: String) {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fputs("encode failed \(name)\n", stderr)
        exit(1)
    }
    try! FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    try! data.write(to: outDir.appendingPathComponent(name))
    print("  \(name) (\(rep.pixelsWide)px)")
}

print("Menu bar icon → \(outDir.path)")
writePNG(render(pixels: 18), name: "MenuBarIcon.png")
writePNG(render(pixels: 36), name: "MenuBarIcon@2x.png")
writePNG(render(pixels: 54), name: "MenuBarIcon@3x.png")
writePNG(render(pixels: 114), name: "MenuBarIcon-source.png")
