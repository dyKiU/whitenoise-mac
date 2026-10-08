import Foundation

/// Uses YouTube's fixed oEmbed endpoint instead of parsing a watch/consent page.
/// Only the video identifier is forwarded; share tokens and unrelated query values stay local.
nonisolated enum YouTubeLinkPreview {
    static let maximumMetadataBytes = 64 * 1024

    static func metadataURL(for url: URL) -> URL? {
        guard LinkPreviewMetadata.fetchableURL(url.absoluteString) != nil,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let host = components.host?.lowercased()
        else { return nil }
        let path = components.path.split(separator: "/", omittingEmptySubsequences: true)
        let identifier: String?
        switch host {
        case "youtu.be":
            identifier = path.count == 1 ? String(path[0]) : nil
        case "youtube.com", "www.youtube.com", "m.youtube.com":
            if components.path == "/watch" {
                let values = components.queryItems?.filter { $0.name == "v" } ?? []
                identifier = values.count == 1 ? values[0].value : nil
            } else if path.count == 2, ["shorts", "embed", "live"].contains(String(path[0])) {
                identifier = String(path[1])
            } else {
                identifier = nil
            }
        default:
            return nil
        }
        guard let identifier, identifier.utf8.count == 11,
            identifier.utf8.allSatisfy({ byte in
                (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                    || byte == 45 || byte == 95
            })
        else { return nil }
        var endpoint = URLComponents(string: "https://www.youtube.com/oembed")!
        endpoint.queryItems = [
            URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(identifier)"),
            URLQueryItem(name: "format", value: "json"),
        ]
        return endpoint.url
    }

    static func parse(_ data: Data) -> LinkPreviewMetadata? {
        guard data.count <= maximumMetadataBytes,
            let response = try? JSONDecoder().decode(Response.self, from: data),
            response.version == "1.0", response.type == "video"
        else { return nil }
        let title = response.title.flatMap(LinkPreviewMetadata.compactTitle)
        let imageURL = response.thumbnailURL.flatMap(LinkPreviewMetadata.fetchableURL)
        guard title != nil || imageURL != nil else { return nil }
        return LinkPreviewMetadata(title: title, imageURL: imageURL)
    }

    private struct Response: Decodable {
        let version: String
        let type: String
        let title: String?
        let thumbnailURL: String?

        enum CodingKeys: String, CodingKey {
            case version, type, title
            case thumbnailURL = "thumbnail_url"
        }
    }
}
