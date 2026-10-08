import AppKit

/// Full-bleed text thumbnail matching system `.js` / `.json` Finder thumbs:
/// white page, black monospace body from the top-left, no badge, no dog-ear
/// chrome (Finder may still wrap icon-mode requests; content itself stays plain).
enum TextDocumentThumbnail {
    static func draw(text: String, in context: CGContext, size: CGSize) {
        NSGraphicsContext.saveGraphicsState()
        let ns = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current = ns
        defer { NSGraphicsContext.restoreGraphicsState() }

        let bounds = NSRect(origin: .zero, size: size)
        NSColor.white.setFill()
        bounds.fill()

        // Dense body text — same look as system JS thumbs (see user screenshot).
        let insetX = max(4, size.width * 0.04)
        let insetY = max(4, size.height * 0.04)
        let fontSize = max(5, min(11, size.width * 0.048))
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.lineSpacing = 0

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph,
        ]

        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }

        let lineHeight = fontSize * 1.28
        var y = size.height - insetY - lineHeight
        let maxWidth = size.width - insetX * 2
        let maxLines = max(4, Int((size.height - insetY * 2) / lineHeight))

        var drawn = 0
        for line in lines {
            guard drawn < maxLines, y >= insetY * 0.4 else { break }
            let display = line.isEmpty ? " " : line
            let rect = NSRect(x: insetX, y: y, width: maxWidth, height: lineHeight)
            (display as NSString).draw(
                with: rect,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: attrs
            )
            y -= lineHeight
            drawn += 1
        }
    }
}
