import Foundation
import Network

/// Where a discourse can be downloaded from. The archive.org mirror serves from US data
/// centres; oshoworld.com serves from Delhi.
enum DownloadSource: String, CaseIterable, Sendable {
    case archive
    case oshoworld
}

/// Chooses which server to try first. Measured 2026-10-12: from Mumbai, connecting took
/// 28 ms to oshoworld.com and 300–570 ms to archive.org; from the US, the reverse.
enum DownloadSourcePolicy {
    static let nearOshoworldRegions: Set<String> = ["IN", "NP", "BD", "LK", "BT"]
    static let nearOshoworldTimeZones: Set<String> = [
        "Asia/Kolkata", "Asia/Calcutta", "Asia/Kathmandu", "Asia/Katmandu", "Asia/Dhaka", "Asia/Colombo", "Asia/Thimphu",
    ]
    /// A measured server must be clearly faster before it overrides the regional default.
    static let switchRatio = 1.25
    static let speedsKey = "downloads.sourceBytesPerSecond"

    /// Either signal counts: many listeners in India set their phone's region to the US.
    static func isNearOshoworld(region: String?, timeZone: String) -> Bool {
        region.map(nearOshoworldRegions.contains) == true || nearOshoworldTimeZones.contains(timeZone)
    }

    static var isNearOshoworldNow: Bool {
        isNearOshoworld(region: Locale.current.region?.identifier, timeZone: TimeZone.current.identifier)
    }

    static func order(
        _ available: [DownloadSource], speeds: [DownloadSource: Double], nearOshoworld: Bool
    ) -> [DownloadSource] {
        var order: [DownloadSource] = nearOshoworld ? [.oshoworld, .archive] : [.archive, .oshoworld]
        order = order.filter(available.contains)
        guard order.count == 2, let first = speeds[order[0]], let second = speeds[order[1]] else { return order }
        // This phone's own experience beats the regional guess once both servers have been tried.
        return second > first * switchRatio ? [order[1], order[0]] : order
    }

    /// Recent downloads matter more than old ones, so a network change shows up within a few downloads.
    static func blended(previous: Double?, sample: Double) -> Double {
        guard sample.isFinite, sample >= 0 else { return previous ?? 0 }
        guard let previous, previous.isFinite else { return sample }
        return previous * 0.5 + sample * 0.5
    }

    static func loadSpeeds(from defaults: UserDefaults) -> [DownloadSource: Double] {
        let stored = defaults.dictionary(forKey: speedsKey) as? [String: Double] ?? [:]
        var speeds: [DownloadSource: Double] = [:]
        for (key, value) in stored {
            if let source = DownloadSource(rawValue: key), value.isFinite, value >= 0 { speeds[source] = value }
        }
        return speeds
    }

    static func saveSpeeds(_ speeds: [DownloadSource: Double], to defaults: UserDefaults) {
        defaults.set(Dictionary(uniqueKeysWithValues: speeds.map { ($0.key.rawValue, $0.value) }), forKey: speedsKey)
    }
}

/// What the current network allows downloads to do.
enum DownloadNetwork: Equatable, Sendable {
    case unrestricted
    case cellularOnly
    case offline

    static func classify(satisfied: Bool, wifi: Bool, wired: Bool, cellular: Bool) -> DownloadNetwork {
        guard satisfied else { return .offline }
        if wifi || wired { return .unrestricted }
        return cellular ? .cellularOnly : .unrestricted
    }

    static func classify(_ path: NWPath) -> DownloadNetwork {
        classify(
            satisfied: path.status == .satisfied, wifi: path.usesInterfaceType(.wifi),
            wired: path.usesInterfaceType(.wiredEthernet), cellular: path.usesInterfaceType(.cellular)
        )
    }
}
