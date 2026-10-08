import Foundation

/// Obsidian Spreadsheets (`.sheet` / Luckysheet JSON) → searchable text + HTML table.
enum SheetHTML {
    static func searchableText(from json: String) -> String {
        guard let sheets = parseSheets(json) else { return "" }
        var parts: [String] = []
        for sheet in sheets {
            if let name = sheet["name"] as? String, !name.isEmpty {
                parts.append(name)
            }
            for cell in (sheet["celldata"] as? [[String: Any]]) ?? [] {
                let text = cellDisplayText(cell["v"]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { parts.append(text) }
            }
        }
        return parts.joined(separator: "\n")
    }

    static func render(_ json: String) -> String {
        guard let sheets = parseSheets(json) else {
            return "<p>无法解析表格文件</p>"
        }
        if sheets.isEmpty { return "<p>（空表格）</p>" }
        var html: [String] = []
        for sheet in sheets {
            let name = (sheet["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !name.isEmpty {
                html.append("<h2>\(HTMLEscape.escape(name))</h2>")
            }
            html.append(renderTable(celldata: (sheet["celldata"] as? [[String: Any]]) ?? []))
        }
        return html.joined(separator: "\n")
    }

    private static func parseSheets(_ json: String) -> [[String: Any]]? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let arr = root as? [[String: Any]] { return arr }
        if let dict = root as? [String: Any] { return [dict] }
        return nil
    }

    private static func cellDisplayText(_ v: Any?) -> String {
        guard let dict = v as? [String: Any] else {
            if let s = v as? String { return s }
            if let n = v as? NSNumber { return n.stringValue }
            return ""
        }
        if let m = dict["m"] as? String, !m.isEmpty { return m }
        if let ct = dict["ct"] as? [String: Any],
           let t = ct["t"] as? String,
           t == "inlineStr",
           let spans = ct["s"] as? [[String: Any]] {
            return spans.compactMap { $0["v"] as? String }.joined()
        }
        if let s = dict["v"] as? String { return s }
        if let n = dict["v"] as? NSNumber { return n.stringValue }
        return ""
    }

    private struct GridCell {
        var text: String
        var rowspan: Int
        var colspan: Int
        var bg: String?
    }

    private static func renderTable(celldata: [[String: Any]]) -> String {
        guard !celldata.isEmpty else { return "<p>（空表格）</p>" }

        var grid: [String: GridCell] = [:]
        var covered = Set<String>()
        var maxR = 0
        var maxC = 0
        var minR = Int.max
        var minC = Int.max

        for item in celldata {
            guard let r = intValue(item["r"]), let c = intValue(item["c"]) else { continue }
            let v = item["v"] as? [String: Any]
            let text = cellDisplayText(item["v"])
            var rowspan = 1
            var colspan = 1
            if let mc = v?["mc"] as? [String: Any] {
                rowspan = max(1, intValue(mc["rs"]) ?? 1)
                colspan = max(1, intValue(mc["cs"]) ?? 1)
            }
            let bg = (v?["bg"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = "\(r),\(c)"
            grid[key] = GridCell(text: text, rowspan: rowspan, colspan: colspan, bg: bg)
            if rowspan > 1 || colspan > 1 {
                for rr in r..<(r + rowspan) {
                    for cc in c..<(c + colspan) {
                        if rr == r && cc == c { continue }
                        covered.insert("\(rr),\(cc)")
                    }
                }
            }
            maxR = max(maxR, r + rowspan - 1)
            maxC = max(maxC, c + colspan - 1)
            minR = min(minR, r)
            minC = min(minC, c)
        }

        guard minR != Int.max, minC != Int.max else { return "<p>（空表格）</p>" }

        var rows: [String] = []
        for r in minR...maxR {
            var cells: [String] = []
            for c in minC...maxC {
                let key = "\(r),\(c)"
                if covered.contains(key) { continue }
                let cell = grid[key] ?? GridCell(text: "", rowspan: 1, colspan: 1, bg: nil)
                let tag = (r == minR) ? "th" : "td"
                var attrs = ""
                if cell.rowspan > 1 { attrs += " rowspan=\"\(cell.rowspan)\"" }
                if cell.colspan > 1 { attrs += " colspan=\"\(cell.colspan)\"" }
                if let bg = cell.bg, isSafeCSSColor(bg) {
                    attrs += " style=\"background:\(bg)\""
                }
                let htmlText = HTMLEscape.escape(cell.text)
                    .replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\r", with: "\n")
                    .replacingOccurrences(of: "\n", with: "<br>")
                cells.append("<\(tag)\(attrs)>\(htmlText)</\(tag)>")
            }
            if !cells.isEmpty {
                rows.append("<tr>\(cells.joined())</tr>")
            }
        }
        return "<table>\(rows.joined())</table>"
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }

    /// Only allow simple hex / rgb colors from the sheet JSON into inline style.
    private static func isSafeCSSColor(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.hasPrefix("#") {
            let hex = t.dropFirst()
            return (hex.count == 3 || hex.count == 6 || hex.count == 8)
                && hex.allSatisfy { $0.isHexDigit }
        }
        // Strict rgb/rgba — digits, commas, spaces, dots, percent only inside parens.
        guard t.hasPrefix("rgb(") || t.hasPrefix("rgba("), t.hasSuffix(")") else {
            return false
        }
        let inner = t.dropFirst(t.hasPrefix("rgba(") ? 5 : 4).dropLast()
        return !inner.isEmpty
            && inner.allSatisfy { $0.isNumber || $0 == "," || $0 == " " || $0 == "." || $0 == "%" }
    }
}
