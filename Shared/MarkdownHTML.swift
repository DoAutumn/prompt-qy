import Foundation

/// Lightweight Markdown → HTML. Covers Obsidian basics (headings, emphasis, code,
/// lists, links, wikilinks, GFM pipe tables) and passes through raw HTML blocks.
enum MarkdownHTML {
    static func render(_ markdown: String) -> String {
        var text = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Whole-note HTML (e.g. Obsidian HTML tables) — don't escape tags.
        if trimmed.hasPrefix("<") {
            return sanitizePassthroughHTML(text)
        }

        var fences: [String] = []
        text = replaceFences(in: text, store: &fences)

        var html: [String] = []
        /// Open lists from outer → inner. Indent is leading spaces before the marker.
        var listStack: [(indent: Int, kind: String)] = []
        var openLi = false
        var para: [String] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0

        func flushPara() {
            guard !para.isEmpty else { return }
            let body = para.map { inline($0) }.joined(separator: "<br>")
            html.append("<p>" + body + "</p>")
            para.removeAll()
        }
        func leadingIndent(_ line: String) -> Int {
            var n = 0
            for ch in line {
                if ch == " " { n += 1 }
                else if ch == "\t" { n += 4 }
                else { break }
            }
            return n
        }
        func closeOpenLi() {
            if openLi {
                html.append("</li>")
                openLi = false
            }
        }
        func flushList() {
            while !listStack.isEmpty {
                closeOpenLi()
                html.append("</\(listStack.removeLast().kind)>")
                if !listStack.isEmpty { openLi = true }  // still inside parent <li>
            }
            closeOpenLi()
        }
        func isUnorderedItem(_ t: String) -> Bool {
            t.range(of: #"^[-*+]\s+"#, options: .regularExpression) != nil
                || t.range(of: #"^[-*+]$"#, options: .regularExpression) != nil
        }
        func isOrderedItem(_ t: String) -> Bool {
            t.range(of: #"^\d+\.\s+"#, options: .regularExpression) != nil
                || t.range(of: #"^\d+\.$"#, options: .regularExpression) != nil
        }
        /// Indented continuation of the current list item (not a new marker).
        func isListContinuation(_ raw: String) -> Bool {
            guard raw.first == " " || raw.first == "\t" else { return false }
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return false }
            return !isUnorderedItem(t) && !isOrderedItem(t)
        }
        /// Indented paragraphs belonging to the current list item.
        /// Blank lines separate paragraphs; they are NOT emitted as `<br><br>`.
        func consumeListContinuationParagraphs() -> [[String]] {
            var paras: [[String]] = []
            var current: [String] = []
            while i < lines.count {
                let raw = lines[i]
                let t = raw.trimmingCharacters(in: .whitespaces)
                if t.isEmpty {
                    var j = i + 1
                    while j < lines.count && lines[j].trimmingCharacters(in: .whitespaces).isEmpty {
                        j += 1
                    }
                    if j < lines.count && isListContinuation(lines[j]) {
                        if !current.isEmpty {
                            paras.append(current)
                            current = []
                        }
                        i += 1
                        continue
                    }
                    break
                }
                if isListContinuation(raw) {
                    current.append(t)
                    i += 1
                    continue
                }
                break
            }
            if !current.isEmpty { paras.append(current) }
            return paras
        }
        func openListItem(indent: Int, kind: String, content: String) {
            while let last = listStack.last, last.indent > indent {
                closeOpenLi()
                html.append("</\(last.kind)>")
                listStack.removeLast()
                openLi = true
            }
            if let last = listStack.last, last.indent == indent {
                if last.kind != kind {
                    closeOpenLi()
                    html.append("</\(last.kind)>")
                    listStack.removeLast()
                    html.append("<\(kind)>")
                    listStack.append((indent, kind))
                } else {
                    closeOpenLi()
                }
            } else {
                html.append("<\(kind)>")
                listStack.append((indent, kind))
            }
            html.append("<li>\(content)")
            openLi = true
        }
        func emitListItem(indent: Int, kind: String, firstLine: String) {
            let paras = consumeListContinuationParagraphs()
            var content = inline(firstLine)
            for para in paras {
                let text = para.map { inline($0) }.joined(separator: "<br>")
                content += "<p>\(text)</p>"
            }
            openListItem(indent: indent, kind: kind, content: content)
        }
        /// Merge consecutive `>` lines into one `<blockquote>`. Strips leading /
        /// trailing empty `>` so they don't inflate padding via extra `<br>`.
        func consumeBlockquoteHTML() -> String {
            var quotes: [String] = []
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("> ") {
                    quotes.append(String(t.dropFirst(2)))
                } else if t == ">" {
                    quotes.append("")
                } else {
                    break
                }
                i += 1
            }
            while quotes.first?.isEmpty == true { quotes.removeFirst() }
            while quotes.last?.isEmpty == true { quotes.removeLast() }
            var collapsed: [String] = []
            for q in quotes {
                if q.isEmpty {
                    if collapsed.last?.isEmpty == false { collapsed.append("") }
                } else {
                    collapsed.append(q)
                }
            }
            let body = collapsed.map { inline($0) }.joined(separator: "<br>")
            return "<blockquote><p>\(body)</p></blockquote>"
        }

        while i < lines.count {
            let line = lines[i]
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            if trimmedLine.isEmpty {
                flushPara()
                // Keep lists open across blank lines when the next block is still
                // a list item (any indent) — otherwise numbering / nesting resets.
                var j = i + 1
                while j < lines.count && lines[j].trimmingCharacters(in: .whitespaces).isEmpty {
                    j += 1
                }
                if j < lines.count {
                    let peek = lines[j].trimmingCharacters(in: .whitespaces)
                    let stillList = isUnorderedItem(peek) || isOrderedItem(peek)
                    if !stillList { flushList() }
                } else {
                    flushList()
                }
                i += 1
                continue
            }

            // Raw HTML block (table / div / …) — Obsidian embeds these as-is.
            if let tag = htmlBlockTag(trimmedLine) {
                flushPara()
                flushList()
                var block = [line]
                let close = "</\(tag)>"
                if !trimmedLine.lowercased().contains(close) && !isVoidHTMLTag(tag) {
                    i += 1
                    while i < lines.count {
                        block.append(lines[i])
                        if lines[i].lowercased().contains(close) { break }
                        i += 1
                    }
                }
                html.append(sanitizePassthroughHTML(block.joined(separator: "\n")))
                i += 1
                continue
            }

            if let fenceIdx = fencePlaceholderIndex(trimmedLine) {
                flushPara()
                flushList()
                html.append("<pre><code>\(fences[fenceIdx])</code></pre>")
                i += 1
                continue
            }

            // GFM pipe table
            if trimmedLine.contains("|"),
               i + 1 < lines.count,
               isTableSeparator(lines[i + 1]) {
                flushPara()
                flushList()
                var tableLines = [line, lines[i + 1]]
                i += 2
                while i < lines.count {
                    let next = lines[i].trimmingCharacters(in: .whitespaces)
                    if next.isEmpty || !next.contains("|") { break }
                    tableLines.append(lines[i])
                    i += 1
                }
                html.append(renderPipeTable(tableLines))
                continue
            }

            if let heading = heading(trimmedLine) {
                flushPara()
                flushList()
                html.append(heading)
                i += 1
                continue
            }

            // Preserve leading indent so nested lists (`  - child`) work.
            let indent = leadingIndent(line)
            if let m = trimmedLine.range(of: #"^[-*+](?:\s+|$)"#, options: .regularExpression) {
                flushPara()
                i += 1
                let first = String(trimmedLine[m.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                emitListItem(indent: indent, kind: "ul", firstLine: first)
                continue
            }
            if let m = trimmedLine.range(of: #"^\d+\.(?:\s+|$)"#, options: .regularExpression) {
                flushPara()
                i += 1
                let first = String(trimmedLine[m.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                emitListItem(indent: indent, kind: "ol", firstLine: first)
                continue
            }
            // Merge consecutive `>` lines into one blockquote (CommonMark).
            if trimmedLine.hasPrefix("> ") || trimmedLine == ">" {
                flushPara()
                flushList()
                html.append(consumeBlockquoteHTML())
                continue
            }
            if trimmedLine.hasPrefix("---") && trimmedLine.allSatisfy({ $0 == "-" || $0 == " " }) {
                flushPara()
                flushList()
                html.append("<hr>")
                i += 1
                continue
            }

            flushList()
            para.append(trimmedLine)
            i += 1
        }
        flushPara()
        flushList()
        return html.joined(separator: "\n")
    }

    /// Visible-text haystack for search count / jump (HTML notes: strip tags).
    static func searchHaystack(from body: String) -> String {
        if body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") {
            return body.replacingOccurrences(
                of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        }
        return body
    }

    /// Count non-overlapping case-insensitive occurrences of `query` in `body`.
    /// For HTML notes, tags are stripped so the count matches visible text.
    static func matchCount(in body: String, query: String) -> Int {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return 0 }
        let haystack = searchHaystack(from: body)
        let lower = haystack.lowercased()
        let n = needle.lowercased()
        var count = 0
        var start = lower.startIndex
        while let r = lower.range(of: n, range: start..<lower.endIndex) {
            count += 1
            start = r.upperBound
        }
        return count
    }

    // MARK: - GFM tables

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("|"), t.contains("-") else { return false }
        // |---|:---| or ---|---
        return t.range(of: #"^\|?(\s*:?-+:?\s*\|)+\s*:?-+:?\s*\|?\s*$"#, options: .regularExpression) != nil
            || t.range(of: #"^\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)+\|?\s*$"#, options: .regularExpression) != nil
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t = String(t.dropFirst()) }
        if t.hasSuffix("|") { t = String(t.dropLast()) }
        return t.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func renderPipeTable(_ rows: [String]) -> String {
        guard rows.count >= 2 else { return "" }
        let headers = splitTableRow(rows[0])
        let aligns: [String] = splitTableRow(rows[1]).map { cell in
            let c = cell.trimmingCharacters(in: .whitespaces)
            let left = c.hasPrefix(":")
            let right = c.hasSuffix(":")
            if left && right { return "center" }
            if right { return "right" }
            if left { return "left" }
            return ""
        }
        var out = "<table>\n<thead>\n<tr>"
        for (i, h) in headers.enumerated() {
            let a = i < aligns.count ? aligns[i] : ""
            let style = a.isEmpty ? "" : " style=\"text-align:\(a)\""
            out += "<th\(style)>\(inline(h))</th>"
        }
        out += "</tr>\n</thead>\n<tbody>\n"
        for r in rows.dropFirst(2) {
            let cells = splitTableRow(r)
            out += "<tr>"
            for i in 0..<headers.count {
                let a = i < aligns.count ? aligns[i] : ""
                let style = a.isEmpty ? "" : " style=\"text-align:\(a)\""
                let text = i < cells.count ? cells[i] : ""
                out += "<td\(style)>\(inline(text))</td>"
            }
            out += "</tr>\n"
        }
        out += "</tbody>\n</table>"
        return out
    }

    // MARK: - Helpers

    private static func htmlBlockTag(_ line: String) -> String? {
        // No iframe — passthrough HTML is sanitized but keep the allowlist tight.
        let pattern = #"^<(table|div|section|article|details|aside|figure|blockquote|ul|ol|pre|p)\b"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)),
              m.numberOfRanges > 1 else { return nil }
        return (line as NSString).substring(with: m.range(at: 1)).lowercased()
    }

    private static func isVoidHTMLTag(_ tag: String) -> Bool {
        ["br", "hr", "img", "input", "meta", "link"].contains(tag)
    }

    /// Strip active content from Obsidian-style raw HTML notes.
    private static func sanitizePassthroughHTML(_ html: String) -> String {
        var s = html
        let blockTags = ["script", "iframe", "object", "embed", "form"]
        for tag in blockTags {
            if let re = try? NSRegularExpression(
                pattern: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>",
                options: [.caseInsensitive]) {
                s = re.stringByReplacingMatches(
                    in: s, range: NSRange(location: 0, length: (s as NSString).length),
                    withTemplate: "")
            }
            if let re = try? NSRegularExpression(
                pattern: "<\(tag)\\b[^>]*/?>",
                options: [.caseInsensitive]) {
                s = re.stringByReplacingMatches(
                    in: s, range: NSRange(location: 0, length: (s as NSString).length),
                    withTemplate: "")
            }
        }
        if let onRe = try? NSRegularExpression(
            pattern: #"\son[a-z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#,
            options: [.caseInsensitive]) {
            s = onRe.stringByReplacingMatches(
                in: s, range: NSRange(location: 0, length: (s as NSString).length),
                withTemplate: "")
        }
        if let jsRe = try? NSRegularExpression(
            pattern: #"(?i)(href|src)\s*=\s*(['"])\s*javascript:[^'"]*\2"#) {
            s = jsRe.stringByReplacingMatches(
                in: s, range: NSRange(location: 0, length: (s as NSString).length),
                withTemplate: "")
        }
        return s
    }

    private static func replaceFences(in text: String, store: inout [String]) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []
        var i = 0
        while i < lines.count {
            if lines[i].hasPrefix("```") {
                var code: [String] = []
                i += 1
                while i < lines.count && !lines[i].hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                store.append(HTMLEscape.escape(code.joined(separator: "\n")))
                out.append("%%FENCE\(store.count - 1)%%")
                if i < lines.count { i += 1 }
                continue
            }
            out.append(lines[i])
            i += 1
        }
        return out.joined(separator: "\n")
    }

    private static func fencePlaceholderIndex(_ line: String) -> Int? {
        guard line.hasPrefix("%%FENCE"), line.hasSuffix("%%") else { return nil }
        let inner = line.dropFirst(7).dropLast(2)
        return Int(inner)
    }

    private static func heading(_ line: String) -> String? {
        var n = 0
        for ch in line {
            if ch == "#" { n += 1 } else { break }
        }
        guard (1...6).contains(n) else { return nil }
        let rest = line.dropFirst(n)
        guard rest.first == " " || rest.isEmpty else { return nil }
        let title = rest.drop(while: { $0 == " " })
        return "<h\(n)>\(inline(String(title)))</h\(n)>"
    }

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "svg", "ico", "heic", "tif", "tiff",
    ]

    private static func isImagePath(_ path: String) -> Bool {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        let ext = (name as NSString).pathExtension.lowercased()
        return imageExtensions.contains(ext)
    }

    private static func imgTag(src: String, alt: String, loading: String = "lazy") -> String {
        let s = HTMLEscape.escapeAttribute(src)
        let a = HTMLEscape.escapeAttribute(alt)
        return "<img src=\"\(s)\" alt=\"\(a)\" loading=\"\(loading)\" decoding=\"async\">"
    }

    private static func inline(_ s: String) -> String {
        var t = HTMLEscape.escape(s)
        // Obsidian embeds before wiki links: `![[photo.png]]` / `![[a.png|alt]]`.
        t = replace(t, pattern: #"!\[\[([^\]|#]+)(?:#[^\]|]*)?(?:\|([^\]]+))?\]\]"#) { g in
            let path = g[1].trimmingCharacters(in: .whitespaces)
            let alt = g.count > 2 && !g[2].isEmpty ? g[2] : path
            if isImagePath(path), HTMLEscape.isAllowedURL(path, forImage: true) {
                return imgTag(src: path, alt: alt)
            }
            return "<span class=\"wiki\">\(alt)</span>"
        }
        t = replace(t, pattern: #"\[\[([^\]|]+)\|([^\]]+)\]\]"#) { "<span class=\"wiki\">\($0[2])</span>" }
        t = replace(t, pattern: #"\[\[([^\]]+)\]\]"#) { "<span class=\"wiki\">\($0[1])</span>" }
        // Images before links so `![alt](url)` isn't eaten as a link.
        t = replace(t, pattern: #"!\[([^\]]*)\]\(([^)\s]+)\)"#) { g in
            guard HTMLEscape.isAllowedURL(g[2], forImage: true) else {
                return g[1].isEmpty ? "" : g[1]
            }
            return imgTag(src: g[2], alt: g[1])
        }
        t = replace(t, pattern: #"\[([^\]]+)\]\(([^)]+)\)"#) { g in
            guard HTMLEscape.isAllowedURL(g[2], forImage: false) else { return g[1] }
            return "<a href=\"\(HTMLEscape.escapeAttribute(g[2]))\">\(g[1])</a>"
        }
        t = replace(t, pattern: #"`([^`]+)`"#) { "<code>\($0[1])</code>" }
        t = replace(t, pattern: #"~~([^~]+)~~"#) { "<del>\($0[1])</del>" }
        t = replace(t, pattern: #"\*\*([^*]+)\*\*"#) { "<strong>\($0[1])</strong>" }
        t = replace(t, pattern: #"__([^_]+)__"#) { "<strong>\($0[1])</strong>" }
        t = replace(t, pattern: #"(?<!\w)\*([^*]+)\*(?!\w)"#) { "<em>\($0[1])</em>" }
        t = replace(t, pattern: #"(?<!\w)_([^_]+)_(?!\w)"#) { "<em>\($0[1])</em>" }
        t = autolinkBareURLs(t)
        return t
    }

    /// Turn remaining bare `http(s)://…` into links (skip text already inside tags).
    private static func autolinkBareURLs(_ s: String) -> String {
        guard let re = try? NSRegularExpression(
            pattern: #"(?<!["'=])(https?://[^\s<>\"']+)"#
        ) else { return s }
        let ns = s as NSString
        let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }
        var out = ""
        var cursor = 0
        for m in matches {
            let full = m.range
            let before = ns.substring(with: NSRange(location: 0, length: full.location))
            let lastLT = before.lastIndex(of: "<")
            let lastGT = before.lastIndex(of: ">")
            let insideTag = lastLT != nil && (lastGT == nil || lastLT! > lastGT!)
            out += ns.substring(with: NSRange(location: cursor, length: full.location - cursor))
            let raw = ns.substring(with: full)
            if insideTag {
                out += raw
            } else {
                var url = raw
                while let last = url.last, ".,;:!?)]》」』".contains(last) {
                    url = String(url.dropLast())
                }
                if url.count >= 8, HTMLEscape.isAllowedURL(url, forImage: false) {
                    let escaped = HTMLEscape.escape(url)
                    out += "<a href=\"\(HTMLEscape.escapeAttribute(escaped))\">\(escaped)</a>"
                    if raw.count > url.count {
                        out += String(raw.dropFirst(url.count))
                    }
                } else {
                    out += raw
                }
            }
            cursor = full.location + full.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    private static func replace(
        _ input: String,
        pattern: String,
        _ build: ([String]) -> String
    ) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return input }
        let ns = input as NSString
        let matches = re.matches(in: input, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return input }
        var out = ""
        var cursor = 0
        for m in matches {
            let full = m.range
            out += ns.substring(with: NSRange(location: cursor, length: full.location - cursor))
            var groups = [ns.substring(with: full)]
            for i in 1..<m.numberOfRanges {
                let r = m.range(at: i)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            out += build(groups)
            cursor = full.location + full.length
        }
        out += ns.substring(from: cursor)
        return out
    }
}
