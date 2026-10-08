import Foundation

enum HTMLEscape {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Escape for double-quoted HTML attribute values. `s` may already have
    /// `&amp;` / `&lt;` / `&gt;` from a prior `escape` pass — only quotes are added.
    static func escapeAttribute(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Whether `url` is safe to put in `href` / `src` (after optional `&amp;` decode).
    static func isAllowedURL(_ url: String, forImage: Bool) -> Bool {
        let t = url.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "&amp;", with: "&")
        guard !t.isEmpty else { return false }
        let lower = t.lowercased()
        if lower.hasPrefix("javascript:") || lower.hasPrefix("vbscript:") {
            return false
        }
        if lower.hasPrefix("data:") {
            return forImage && lower.hasPrefix("data:image/")
        }
        if lower.hasPrefix("mailto:") {
            return !forImage
        }
        if let schemeEnd = t.range(of: "://") {
            let scheme = String(t[..<schemeEnd.lowerBound]).lowercased()
            return scheme == "http" || scheme == "https"
        }
        // Relative paths, anchors, Obsidian attachment paths.
        return true
    }
}
