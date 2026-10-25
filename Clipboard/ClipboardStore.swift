import AppKit
import CryptoKit
import Foundation

/// On-disk clipboard history: metadata index + payload files + image thumbnails.
/// Originals stay on disk; only metadata (+ optional thumb NSImage cache) stays hot.
enum ClipboardStore {
    enum Kind: String, Codable { case text, image }

    struct Item: Codable, Equatable {
        let id: String
        var kind: Kind
        /// One-line preview for the list (never the full payload).
        var preview: String
        var createdAt: Date
        var lastUsedAt: Date
        var pinned: Bool
        var sourceApp: String?
        var byteLength: Int
        /// SHA256 hex of normalized text or image bytes (dedup).
        var contentHash: String
        /// Payload file extension: `txt`, `png`, `jpg`, …
        var fileExtension: String
    }

    private struct IndexFile: Codable {
        var items: [Item]
    }

    private static let fm = FileManager.default
    private static var cache: [Item]?
    private static var thumbCache: [String: NSImage] = [:]
    private static let lock = NSLock()

    private static var rootURL: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("PromptQy/Clipboard", isDirectory: true)
    }

    private static var indexURL: URL { rootURL.appendingPathComponent("index.json") }
    private static var itemsDir: URL { rootURL.appendingPathComponent("items", isDirectory: true) }
    private static var thumbsDir: URL { rootURL.appendingPathComponent("thumbs", isDirectory: true) }

    static func prepare() {
        try? fm.createDirectory(at: itemsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
        _ = load()
    }

    static func allItems() -> [Item] {
        lock.lock(); defer { lock.unlock() }
        return sorted(loadUnlocked())
    }

    static func filtered(query: String) -> [Item] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let items = allItems()
        guard !q.isEmpty else { return items }
        return items.filter {
            $0.preview.lowercased().contains(q)
                || ($0.sourceApp?.lowercased().contains(q) ?? false)
        }
    }

    /// Insert or refresh a text clip. Returns the resulting item.
    @discardableResult
    static func addText(_ text: String, sourceApp: String?) -> Item? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let limited: String
        if trimmed.utf8.count > Settings.clipboardMaxTextBytes {
            let data = Data(trimmed.utf8.prefix(Settings.clipboardMaxTextBytes))
            limited = String(data: data, encoding: .utf8) ?? String(trimmed.prefix(Settings.clipboardMaxTextBytes / 4))
        } else {
            limited = trimmed
        }
        let hash = sha256(Data(limited.utf8))
        let preview = makeTextPreview(limited)
        return upsert(
            kind: .text,
            contentHash: hash,
            preview: preview,
            sourceApp: sourceApp,
            byteLength: limited.utf8.count,
            fileExtension: "txt",
            writePayload: { url in
                try limited.write(to: url, atomically: true, encoding: .utf8)
            },
            writeThumb: nil
        )
    }

    /// Insert or refresh an image clip from pasteboard data.
    /// `suggestedName` is the original filename when known (Finder / file URL).
    @discardableResult
    static func addImage(
        data: Data,
        type: NSPasteboard.PasteboardType,
        sourceApp: String?,
        suggestedName: String? = nil
    ) -> Item? {
        guard !data.isEmpty else { return nil }
        if data.count > Settings.clipboardMaxImageBytes { return nil }
        let hash = sha256(data)
        let ext: String
        switch type {
        case .png: ext = "png"
        case .tiff: ext = "tiff"
        default:
            if type.rawValue.contains("jpeg") || type.rawValue.contains("jpg") { ext = "jpg" }
            else if type.rawValue.contains("heic") { ext = "heic" }
            else { ext = "png" }
        }
        let preview = makeImagePreview(data: data, suggestedName: suggestedName)
        return upsert(
            kind: .image,
            contentHash: hash,
            preview: preview,
            sourceApp: sourceApp,
            byteLength: data.count,
            fileExtension: ext,
            writePayload: { url in try data.write(to: url, options: .atomic) },
            writeThumb: { thumbURL in
                guard let thumb = makeThumbnail(data: data) else { return }
                if let tiff = thumb.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) {
                    try jpeg.write(to: thumbURL, options: .atomic)
                }
            }
        )
    }

    /// Prefer real filename; fall back to a dated “截图” label (never “图片 W×H” alone).
    private static func makeImagePreview(data: Data, suggestedName: String?) -> String {
        if let raw = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let name = (raw as NSString).lastPathComponent
            if !name.isEmpty { return name }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        if let img = NSImage(data: data) {
            let s = img.size
            return String(format: "截图 %@ (%.0f×%.0f)", formatter.string(from: Date()), s.width, s.height)
        }
        return "截图 \(formatter.string(from: Date()))"
    }

    static func loadText(_ item: Item) -> String? {
        guard item.kind == .text else { return nil }
        return try? String(contentsOf: payloadURL(item), encoding: .utf8)
    }

    static func loadImageData(_ item: Item) -> Data? {
        guard item.kind == .image else { return nil }
        return try? Data(contentsOf: payloadURL(item))
    }

    static func thumbnail(for item: Item) -> NSImage? {
        guard item.kind == .image else { return nil }
        lock.lock()
        if let cached = thumbCache[item.id] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let url = thumbsDir.appendingPathComponent("\(item.id).jpg")
        let img: NSImage?
        if let data = try? Data(contentsOf: url) {
            img = NSImage(data: data)
        } else if let data = loadImageData(item) {
            img = makeThumbnail(data: data)
        } else {
            img = nil
        }
        if let img {
            lock.lock()
            thumbCache[item.id] = img
            lock.unlock()
        }
        return img
    }

    private static var tipCache: [String: NSImage] = [:]

    /// Larger decode for the selection tooltip (list thumbs are only ~128px).
    static func tooltipImage(for item: Item, maxSide: CGFloat = 520) -> NSImage? {
        guard item.kind == .image else { return nil }
        lock.lock()
        if let cached = tipCache[item.id] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        guard let data = loadImageData(item), let src = NSImage(data: data) else {
            return thumbnail(for: item)
        }
        let size = src.size
        guard size.width > 0, size.height > 0 else { return src }
        let scale = min(1, maxSide / max(size.width, size.height))
        let result: NSImage
        if scale >= 0.999 {
            result = src
        } else {
            let target = NSSize(
                width: max(1, (size.width * scale).rounded()),
                height: max(1, (size.height * scale).rounded()))
            let out = NSImage(size: target)
            out.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .high
            src.draw(
                in: NSRect(origin: .zero, size: target),
                from: NSRect(origin: .zero, size: size),
                operation: .copy,
                fraction: 1)
            out.unlockFocus()
            result = out
        }
        lock.lock()
        tipCache[item.id] = result
        // Bound tip cache — keep recently used tips only.
        if tipCache.count > 12 {
            let overflow = tipCache.count - 12
            for key in tipCache.keys.prefix(overflow) {
                tipCache.removeValue(forKey: key)
            }
        }
        lock.unlock()
        return result
    }

    static func clearThumbnailCache() {
        lock.lock()
        thumbCache.removeAll()
        tipCache.removeAll()
        lock.unlock()
    }

    static func touch(_ id: String) {
        mutate { items in
            guard let i = items.firstIndex(where: { $0.id == id }) else { return }
            items[i].lastUsedAt = Date()
        }
    }

    static func setPinned(_ id: String, pinned: Bool) {
        mutate { items in
            guard let i = items.firstIndex(where: { $0.id == id }) else { return }
            items[i].pinned = pinned
        }
        enforceLimits()
    }

    static func delete(_ id: String) {
        lock.lock()
        var items = loadUnlocked()
        guard let item = items.first(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        items.removeAll { $0.id == id }
        saveUnlocked(items)
        thumbCache.removeValue(forKey: id)
        tipCache.removeValue(forKey: id)
        lock.unlock()
        removeFiles(for: item)
    }

    static func clearUnpinned() {
        lock.lock()
        var items = loadUnlocked()
        let doomed = items.filter { !$0.pinned }
        items.removeAll { !$0.pinned }
        saveUnlocked(items)
        for d in doomed {
            thumbCache.removeValue(forKey: d.id)
            tipCache.removeValue(forKey: d.id)
        }
        lock.unlock()
        for d in doomed { removeFiles(for: d) }
    }

    /// Apply current text/image retention settings (e.g. after Settings change).
    static func applyLimits() {
        enforceLimits()
    }

    // MARK: - Internals

    private static func payloadURL(_ item: Item) -> URL {
        itemsDir.appendingPathComponent("\(item.id).\(item.fileExtension)")
    }

    private static func upsert(
        kind: Kind,
        contentHash: String,
        preview: String,
        sourceApp: String?,
        byteLength: Int,
        fileExtension: String,
        writePayload: (URL) throws -> Void,
        writeThumb: ((URL) throws -> Void)?
    ) -> Item? {
        lock.lock()
        var items = loadUnlocked()
        let now = Date()
        if let i = items.firstIndex(where: { $0.contentHash == contentHash }) {
            var existing = items[i]
            existing.lastUsedAt = now
            existing.preview = preview
            if let sourceApp { existing.sourceApp = sourceApp }
            items.remove(at: i)
            items.insert(existing, at: 0)
            saveUnlocked(items)
            lock.unlock()
            enforceLimits()
            return existing
        }
        let id = UUID().uuidString
        let item = Item(
            id: id,
            kind: kind,
            preview: preview,
            createdAt: now,
            lastUsedAt: now,
            pinned: false,
            sourceApp: sourceApp,
            byteLength: byteLength,
            contentHash: contentHash,
            fileExtension: fileExtension
        )
        do {
            try writePayload(payloadURL(item))
            if let writeThumb {
                try writeThumb(thumbsDir.appendingPathComponent("\(id).jpg"))
            }
        } catch {
            lock.unlock()
            return nil
        }
        items.insert(item, at: 0)
        saveUnlocked(items)
        lock.unlock()
        enforceLimits()
        return item
    }

    private static func enforceLimits() {
        lock.lock()
        var items = loadUnlocked()
        var changed = false

        // Text count (unpinned).
        var unpinnedText = items.indices.filter { !items[$0].pinned && items[$0].kind == .text }
        while unpinnedText.count > Settings.clipboardTextLimit {
            let idx = unpinnedText.removeLast()
            let doomed = items.remove(at: idx)
            removeFiles(for: doomed)
            thumbCache.removeValue(forKey: doomed.id)
            tipCache.removeValue(forKey: doomed.id)
            changed = true
            unpinnedText = items.indices.filter { !items[$0].pinned && items[$0].kind == .text }
        }

        // Image count (unpinned).
        var unpinnedImg = items.indices.filter { !items[$0].pinned && items[$0].kind == .image }
        while unpinnedImg.count > Settings.clipboardImageLimit {
            let idx = unpinnedImg.removeLast()
            let doomed = items.remove(at: idx)
            removeFiles(for: doomed)
            thumbCache.removeValue(forKey: doomed.id)
            tipCache.removeValue(forKey: doomed.id)
            changed = true
            unpinnedImg = items.indices.filter { !items[$0].pinned && items[$0].kind == .image }
        }

        // Image disk budget: drop unpinned images with oldest lastUsedAt first.
        func imageBytes(_ list: [Item]) -> Int {
            list.filter { $0.kind == .image && !$0.pinned }.map(\.byteLength).reduce(0, +)
        }
        while imageBytes(items) > Settings.clipboardImageDiskBudget {
            guard let idx = items.enumerated()
                .filter({ !$0.element.pinned && $0.element.kind == .image })
                .min(by: { $0.element.lastUsedAt < $1.element.lastUsedAt })?
                .offset else { break }
            let doomed = items.remove(at: idx)
            removeFiles(for: doomed)
            thumbCache.removeValue(forKey: doomed.id)
            tipCache.removeValue(forKey: doomed.id)
            changed = true
        }

        if changed { saveUnlocked(items) }
        lock.unlock()
    }

    private static func mutate(_ body: (inout [Item]) -> Void) {
        lock.lock()
        var items = loadUnlocked()
        body(&items)
        saveUnlocked(items)
        lock.unlock()
    }

    private static func load() -> [Item] {
        lock.lock(); defer { lock.unlock() }
        return loadUnlocked()
    }

    private static func loadUnlocked() -> [Item] {
        if let cache { return cache }
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode(IndexFile.self, from: data) else {
            cache = []
            return []
        }
        cache = decoded.items
        return decoded.items
    }

    private static func saveUnlocked(_ items: [Item]) {
        cache = items
        let encoded = IndexFile(items: items)
        if let data = try? JSONEncoder().encode(encoded) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    private static func sorted(_ items: [Item]) -> [Item] {
        items.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned && !b.pinned }
            return a.lastUsedAt > b.lastUsedAt
        }
    }

    private static func removeFiles(for item: Item) {
        try? fm.removeItem(at: payloadURL(item))
        try? fm.removeItem(at: thumbsDir.appendingPathComponent("\(item.id).jpg"))
    }

    private static func makeTextPreview(_ text: String) -> String {
        let one = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if one.count <= 200 { return one }
        return String(one.prefix(197)) + "…"
    }

    private static func makeThumbnail(data: Data) -> NSImage? {
        guard let src = NSImage(data: data) else { return nil }
        let maxEdge: CGFloat = 128
        let size = src.size
        guard size.width > 0, size.height > 0 else { return src }
        let scale = min(1, maxEdge / max(size.width, size.height))
        let target = NSSize(width: max(1, floor(size.width * scale)),
                            height: max(1, floor(size.height * scale)))
        let out = NSImage(size: target)
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .medium
        src.draw(in: NSRect(origin: .zero, size: target),
                 from: NSRect(origin: .zero, size: size),
                 operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Pause clipboard capture while PromptQy mutates the pasteboard itself.
enum ClipboardGate {
    private static var depth = 0
    private static let lock = NSLock()

    static var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return depth > 0
    }

    static func pause() {
        lock.lock(); depth += 1; lock.unlock()
    }

    static func resume() {
        lock.lock(); depth = max(0, depth - 1); lock.unlock()
    }

    static func withPaused<T>(_ body: () throws -> T) rethrows -> T {
        pause()
        defer { resume() }
        return try body()
    }
}

extension NSPasteboard.PasteboardType {
    /// Marker written when PromptQy puts history back on the pasteboard.
    static let promptqyClipboard = NSPasteboard.PasteboardType("io.github.promptqy.clipboard-internal")
}
