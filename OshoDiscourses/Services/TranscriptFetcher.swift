import Foundation

/// Network side of transcripts: fetches the raw HTML description for a catalog
/// entry from oshoworld.com, first through the site's JSON API and, if that
/// fails, by scraping the page's embedded Next.js data. Pure extraction helpers
/// are separated from I/O so the payload shapes are unit tested.
enum TranscriptFetcher {

    enum FetchError: LocalizedError, Equatable {
        case badStatus(Int)
        case noDescription
        case blank

        var errorDescription: String? {
            switch self {
            case .badStatus(let code): return "oshoworld.com answered with status \(code)."
            case .noDescription: return "The page did not contain a transcript."
            case .blank: return "oshoworld.com has no text for this discourse yet."
            }
        }
    }

    /// The description HTML for `entry`. Tries the API, then the page.
    static func fetchDescriptionHTML(
        for entry: TranscriptCatalog.Entry,
        allowsCellular: Bool,
        session: URLSession = .shared
    ) async throws -> String {
        var lastError: Error = FetchError.noDescription
        if let url = TranscriptCatalog.descriptionURL(for: entry) {
            do {
                let data = try await fetch(url, allowsCellular: allowsCellular, session: session)
                if let html = description(fromAPIResponse: data) { return html }
                lastError = FetchError.noDescription
            } catch {
                lastError = error
            }
        }
        if let url = TranscriptCatalog.pageURL(for: entry) {
            let data = try await fetch(url, allowsCellular: allowsCellular, session: session)
            if let html = description(fromPageHTML: String(decoding: data, as: UTF8.self)) { return html }
        }
        throw lastError
    }

    private static func fetch(_ url: URL, allowsCellular: Bool, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.allowsCellularAccess = allowsCellular
        // The site's own client sends this on every API call; it costs nothing
        // to look like it.
        request.setValue("application/json", forHTTPHeaderField: "Content-type")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FetchError.badStatus(http.statusCode)
        }
        return data
    }

    // MARK: - Payload extraction

    private struct APIResponse: Decodable {
        let description: String?
        let error: Bool?
    }

    /// `{"description": "<html>"}`; `{"error": true}` or a missing field yields nil.
    static func description(fromAPIResponse data: Data) -> String? {
        guard let decoded = try? JSONDecoder().decode(APIResponse.self, from: data),
              decoded.error != true,
              let description = decoded.description else { return nil }
        return description
    }

    /// Digs `props.pageProps.data.pageData.audioData.description` out of the
    /// `__NEXT_DATA__` script that Next.js embeds in every server-rendered page.
    static func description(fromPageHTML html: String) -> String? {
        guard let scriptRange = html.range(of: "<script id=\"__NEXT_DATA__\" type=\"application/json\">"),
              let end = html.range(of: "</script>", range: scriptRange.upperBound..<html.endIndex) else { return nil }
        let json = html[scriptRange.upperBound..<end.lowerBound]
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) else { return nil }
        var node: Any? = object
        for key in ["props", "pageProps", "data", "pageData", "audioData", "description"] {
            node = (node as? [String: Any])?[key]
        }
        return node as? String
    }
}
