import UIKit
import ImageIO

/// Loads, caches, and downsamples Archive.org series cover (waveform) art.
///
/// Why not AsyncImage: the covers live behind `archive.org/download/...`,
/// which 302-redirects to an ephemeral datanode with no Cache-Control on
/// either hop. URLCache keys the response by the datanode URL, so the stable
/// URL always re-hits the network for the redirect — and refetches the body
/// whenever the datanode rotates. In a 261-row list that meant continuous
/// request churn while scrolling, an initials→image flash on every row
/// re-entry, and full 800×200 decodes rendered into 32–48pt cells.
///
/// This loader fetches each cover once, persists the bytes in
/// Caches/covers/<seriesID>.png (purgeable by the OS, rebuilt on demand),
/// keeps an ImageIO-downsampled UIImage in an NSCache, and coalesces
/// concurrent requests. `cachedImage` is synchronous so a recycled row can
/// paint its cover on the first frame with no placeholder pass.
@MainActor
enum CoverArtLoader {

    /// Downsampled decode target (longest side, px). Largest render is the
    /// 120pt series-detail hero ≈ 360px @3x; 480 keeps it sharp there while
    /// cutting the 800×200 originals' decode + texture cost.
    nonisolated private static let maxPixelSize: CGFloat = 480

    /// NSCache is documented thread-safe; nonisolated(unsafe) lets the
    /// synchronous first-frame lookup run from view inits (nonisolated).
    nonisolated(unsafe) private static let memory = NSCache<NSString, UIImage>()

    /// One in-flight fetch per series, so 20 visible rows of the same series
    /// (or rapid scroll bounce) share a single network request.
    private static var inFlight: [String: Task<UIImage?, Never>] = [:]

    /// Synchronous memory-cache hit, for first-frame rendering in view inits.
    nonisolated static func cachedImage(for seriesID: String) -> UIImage? {
        memory.object(forKey: seriesID as NSString)
    }

    /// The cover for a series, from memory → disk → network (in that order),
    /// or nil if the series has no mapped cover / the fetch fails. Failures
    /// aren't negatively cached: the next appearance retries, which is what
    /// you want for a flaky connection.
    static func image(for seriesID: String) async -> UIImage? {
        if let hit = cachedImage(for: seriesID) { return hit }
        if let running = inFlight[seriesID] { return await running.value }
        guard let url = ArchiveCatalog.coverURL(forSeriesID: seriesID) else { return nil }

        let task = Task<UIImage?, Never> {
            await load(seriesID: seriesID, url: url)
        }
        inFlight[seriesID] = task
        let image = await task.value
        inFlight[seriesID] = nil
        if let image {
            memory.setObject(image, forKey: seriesID as NSString)
        }
        return image
    }

    /// Disk/network load + downsample, off the main actor.
    nonisolated private static func load(seriesID: String, url: URL) async -> UIImage? {
        let fileURL = diskURL(for: seriesID)
        if let data = try? Data(contentsOf: fileURL), let image = downsample(data) {
            return image
        }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true,
              let image = downsample(data) else { return nil }
        // Persist the original bytes (not the downsample) so a future larger
        // render target only needs a re-decode, not a re-download.
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
        return image
    }

    nonisolated private static func diskURL(for seriesID: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let safe = seriesID.replacingOccurrences(of: "/", with: "_")
        return caches.appendingPathComponent("covers/\(safe).png")
    }

    /// ImageIO thumbnail decode: produces a bitmap no larger than
    /// `maxPixelSize` without ever inflating the full-size image.
    nonisolated private static func downsample(_ data: Data) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
