import Cocoa
import QuickLookThumbnailing

/// Finder-style text-page thumbnails for `.md` / `.markdown` / `.sheet`.
@objc(ThumbnailProvider)
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let url = request.fileURL
        // Point size; QL's CGContext is already scaled for the request.
        let size = request.maximumSize
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let text = try DocumentPreviewPage.plainText(forFileAt: url)
            let reply = QLThumbnailReply(contextSize: size) { context in
                TextDocumentThumbnail.draw(text: text, in: context, size: size)
                return true
            }
            handler(reply, nil)
        } catch {
            handler(nil, error)
        }
    }
}
