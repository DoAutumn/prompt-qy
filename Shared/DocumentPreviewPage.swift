import AppKit
import Foundation

/// Shared HTML shell for notes preview + Quick Look. GitHub-flavored light/dark
/// styling (no syntax highlighting), matching the target Space-preview look.
enum DocumentPreviewPage {
    static let supportedExtensions: Set<String> = ["md", "markdown", "sheet"]

    /// Preferred Quick Look window size as a fraction of the main display.
    static func preferredPreviewSize(
        widthFraction: CGFloat = 0.72,
        heightFraction: CGFloat = 0.85
    ) -> CGSize {
        let frame = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return CGSize(
            width: max(720, (frame.width * widthFraction).rounded()),
            height: max(540, (frame.height * heightFraction).rounded())
        )
    }

    static func readFile(at url: URL) throws -> String {
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        if let s = try? String(contentsOf: url, encoding: .isoLatin1) { return s }
        throw CocoaError(.fileReadCorruptFile)
    }

    /// Render file contents to body HTML (no outer document).
    static func bodyHTML(forFileAt url: URL) throws -> String {
        let raw = try readFile(at: url)
        let ext = url.pathExtension.lowercased()
        if ext == "sheet" { return SheetHTML.render(raw) }
        return MarkdownHTML.render(raw)
    }

    /// Plain text used for Finder-style document thumbnails.
    static func plainText(forFileAt url: URL) throws -> String {
        let raw = try readFile(at: url)
        let ext = url.pathExtension.lowercased()
        if ext == "sheet" {
            let text = SheetHTML.searchableText(from: raw)
            return text.isEmpty ? raw : text
        }
        return raw
    }

    /// `.document` — solid page bg for Quick Look. `.panel` — transparent so the
    /// notes-search WKWebView matches the left list (`windowBackgroundColor`).
    enum Chrome {
        case document
        case panel
    }

    static func wrap(
        bodyHTML: String,
        title: String,
        includeSearchJump: Bool = false,
        chrome: Chrome = .document
    ) -> String {
        let jumpScript = includeSearchJump ? searchJumpScript : ""
        let chromeCSS = chrome == .panel ? panelChromeOverride : ""
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(HTMLEscape.escape(title))</title>
        <style>
        \(stylesheet)
        \(chromeCSS)
        </style>
        </head>
        <body>
        <article>\(bodyHTML)</article>
        \(jumpScript)
        </body>
        </html>
        """
    }

    static func fullHTML(forFileAt url: URL) throws -> String {
        var body = try bodyHTML(forFileAt: url)
        // QL sandbox often only scopes the note file — inline local images so
        // relative Obsidian attachments still show. Prefer eager load for Space.
        body = inlineLocalImages(in: body, baseDirectory: url.deletingLastPathComponent())
        body = body.replacingOccurrences(of: "loading=\"lazy\"", with: "loading=\"eager\"")
        return wrap(
            bodyHTML: body,
            title: url.deletingPathExtension().lastPathComponent,
            chrome: .document
        )
    }

    /// Replace relative / file `<img src>` with data URIs when the file is readable.
    static func inlineLocalImages(in html: String, baseDirectory: URL) -> String {
        guard let re = try? NSRegularExpression(
            pattern: #"<img\b([^>]*?)\bsrc=(["'])([^"']+)\2([^>]*)>"#,
            options: [.caseInsensitive]
        ) else { return html }
        let ns = html as NSString
        let matches = re.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return html }
        var out = ""
        var cursor = 0
        for m in matches {
            let full = m.range
            out += ns.substring(with: NSRange(location: cursor, length: full.location - cursor))
            let before = ns.substring(with: m.range(at: 1))
            let quote = ns.substring(with: m.range(at: 2))
            let src = ns.substring(with: m.range(at: 3))
            let after = ns.substring(with: m.range(at: 4))
            if let dataURI = localImageDataURI(src: src, baseDirectory: baseDirectory) {
                let esc = HTMLEscape.escapeAttribute(dataURI)
                out += "<img\(before)src=\(quote)\(esc)\(quote)\(after)>"
            } else {
                out += ns.substring(with: full)
            }
            cursor = full.location + full.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    private static func localImageDataURI(src: String, baseDirectory: URL) -> String? {
        let decoded = src.replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decoded.isEmpty else { return nil }
        let lower = decoded.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://")
            || lower.hasPrefix("data:") { return nil }

        let fileURL: URL
        if lower.hasPrefix("file:") {
            guard let u = URL(string: decoded) else { return nil }
            fileURL = u
        } else {
            fileURL = URL(fileURLWithPath: decoded, relativeTo: baseDirectory)
                .standardizedFileURL
        }

        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return nil }
        // Cap inlined size so huge assets don't blow QL memory.
        guard data.count <= 8 * 1024 * 1024 else { return nil }
        let mime: String
        switch fileURL.pathExtension.lowercased() {
        case "png": mime = "image/png"
        case "jpg", "jpeg": mime = "image/jpeg"
        case "gif": mime = "image/gif"
        case "webp": mime = "image/webp"
        case "svg": mime = "image/svg+xml"
        case "bmp": mime = "image/bmp"
        case "ico": mime = "image/x-icon"
        case "heic": mime = "image/heic"
        case "tif", "tiff": mime = "image/tiff"
        default: mime = "application/octet-stream"
        }
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    /// Match NotesSearchPanel / list side (system window background).
    private static let panelChromeOverride = """
    html, body {
      background: transparent !important;
    }
    body {
      max-width: none;
      padding: 14px 16px 28px;
    }
    """

    // MARK: - Stylesheet (GitHub-like, system light/dark)

    static let stylesheet = """
    *, *::before, *::after { box-sizing: border-box; }

    :root {
      color-scheme: light dark;
      --bg: #ffffff;
      --fg: #1f2328;
      --link: #0969da;
      --border: #d0d7de;
      --code-bg: #f6f8fa;
      --bq-border: #d0d7de;
      --bq-fg: #656d76;
      --tbl-border: #d0d7de;
      --hr: #d8dee4;
      --mark-bg: #ffe58a;
      --mark-fg: inherit;
    }

    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #0d1117;
        --fg: #e6edf3;
        --link: #4493f8;
        --border: #30363d;
        --code-bg: #161b22;
        --bq-border: #3d444d;
        --bq-fg: #9198a1;
        --tbl-border: #3d444d;
        --hr: #21262d;
        --mark-bg: #8a6d1a;
        --mark-fg: #fff8d6;
      }
    }

    html { -webkit-text-size-adjust: 100%; }

    body {
      font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Helvetica Neue", Helvetica, Arial, sans-serif;
      font-size: 16px;
      line-height: 1.6;
      color: var(--fg);
      background: var(--bg);
      max-width: 900px;
      margin: 0 auto;
      padding: 40px 32px 60px;
      overflow-wrap: anywhere;
      word-break: break-word;
    }

    h1, h2, h3, h4, h5, h6 {
      margin-top: 1.5rem;
      margin-bottom: 0.75rem;
      font-weight: 600;
      line-height: 1.25;
      color: var(--fg);
    }
    h1 { font-size: 2em; padding-bottom: 0.3em; border-bottom: 1px solid var(--border); }
    h2 { font-size: 1.5em; padding-bottom: 0.3em; border-bottom: 1px solid var(--border); }
    h3 { font-size: 1.25em; }
    h4 { font-size: 1em; }
    h5 { font-size: 0.875em; }
    h6 { font-size: 0.85em; color: var(--bq-fg); }

    p { margin: 0 0 1rem; }
    a { color: var(--link); text-decoration: underline; text-underline-offset: 2px; }
    a:hover { opacity: 0.85; }
    .wiki {
      color: var(--link);
      border-bottom: 1px dashed color-mix(in srgb, var(--link) 50%, transparent);
    }

    code {
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      font-size: 85%;
      background: var(--code-bg);
      border-radius: 6px;
      padding: 0.2em 0.4em;
    }

    pre {
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      font-size: 85%;
      background: var(--code-bg);
      border-radius: 6px;
      padding: 1em 1.2em;
      overflow-x: auto;
      line-height: 1.5;
      margin: 0 0 1rem;
      border: 1px solid var(--border);
      white-space: pre; /* keep source newlines; scroll horizontally when wide */
    }
    pre code {
      background: none;
      padding: 0;
      border-radius: 0;
      font-size: 100%;
      white-space: inherit;
    }

    blockquote {
      margin: 0 0 1rem;
      padding: 0.15em 1em;
      color: var(--bq-fg);
      border-left: 0.25em solid var(--bq-border);
    }
    blockquote > :first-child { margin-top: 0; }
    blockquote > :last-child { margin-bottom: 0; }
    blockquote p {
      margin: 0;
    }

    table {
      border-collapse: collapse;
      border-spacing: 0;
      margin: 0 0 1rem;
      width: max-content;
      max-width: 100%;
      display: block;
      overflow: auto;
      font-size: 14px;
    }
    table th, table td {
      padding: 6px 13px;
      border: 1px solid var(--tbl-border);
      vertical-align: top;
      text-align: left;
    }
    table th { font-weight: 600; background: var(--code-bg); }
    table tr:nth-child(2n) {
      background: color-mix(in srgb, var(--code-bg) 60%, transparent);
    }

    hr {
      height: 0.25em;
      border: none;
      background: var(--hr);
      margin: 1.5rem 0;
    }

    ul, ol { padding-left: 1.6em; margin: 0.4em 0 0.8em; }
    li { margin: 0.45em 0; }
    /* Indented body under a bullet (blank line + 2-space paragraph in source). */
    li > p {
      margin: 0.35em 0 0.25em;
    }
    li > p:last-child { margin-bottom: 0; }
    del { opacity: 0.7; }
    img { max-width: 100%; height: auto; }

    mark.pq-hit {
      background: var(--mark-bg);
      color: var(--mark-fg);
      padding: 0 1px;
      border-radius: 2px;
    }

    article > :first-child { margin-top: 0; }
    article > :last-child { margin-bottom: 0; }
    """

    private static let searchJumpScript = """
    <script>
    window.pqJumpTo = function(q) {
      if (!q) { window.scrollTo(0, 0); return; }
      document.querySelectorAll('mark.pq-hit').forEach(function(m) {
        m.replaceWith(document.createTextNode(m.textContent || ''));
      });
      var needle = q.toLowerCase();
      var first = null;
      function highlightNode(node) {
        var text = node.nodeValue || '';
        var lower = text.toLowerCase();
        var idx = lower.indexOf(needle);
        if (idx < 0) return false;
        var frag = document.createDocumentFragment();
        var cursor = 0;
        while (idx >= 0) {
          if (idx > cursor) frag.appendChild(document.createTextNode(text.slice(cursor, idx)));
          var mark = document.createElement('mark');
          mark.className = 'pq-hit';
          mark.textContent = text.slice(idx, idx + q.length);
          frag.appendChild(mark);
          if (!first) first = mark;
          cursor = idx + q.length;
          idx = lower.indexOf(needle, cursor);
        }
        if (cursor < text.length) frag.appendChild(document.createTextNode(text.slice(cursor)));
        node.parentNode.replaceChild(frag, node);
        return true;
      }
      var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
      var nodes = [];
      while (walker.nextNode()) nodes.push(walker.currentNode);
      nodes.forEach(highlightNode);
      if (first) first.scrollIntoView({block: 'center', inline: 'nearest'});
    };
    </script>
    """
}
