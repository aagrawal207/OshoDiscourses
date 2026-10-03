#if canImport(WatchConnectivity) && !targetEnvironment(macCatalyst)
import Foundation
import Observation
import OSLog

/// Phone-side lookups a transfer needs; the runtime wraps DownloadService and PlaybackStateService.
@MainActor
protocol WatchTransferLibrary: AnyObject {
    func localFileURL(for discourseID: String) -> URL?
    func resumePosition(for discourseID: String) -> Double
    func duration(for discourseID: String) -> Double
    /// When the phone last moved the resume position, so the Watch can compare it with its own listening.
    func resumeSavedAt(for discourseID: String) -> Date?
}

@MainActor
final class WatchRuntimeTransferLibrary: WatchTransferLibrary {
    private let downloads: DownloadService
    private let playbackState: PlaybackStateService
    private let player: AudioPlayerService

    init(downloads: DownloadService, playbackState: PlaybackStateService, player: AudioPlayerService) {
        self.downloads = downloads
        self.playbackState = playbackState
        self.player = player
    }

    func localFileURL(for discourseID: String) -> URL? {
        downloads.isDownloaded(discourseID) ? downloads.localFileURL(for: discourseID) : nil
    }

    func resumePosition(for discourseID: String) -> Double {
        if player.currentTrackId == discourseID, player.currentTime.isFinite { return max(0, player.currentTime) }
        return playbackState.getPosition(discourseId: discourseID)
    }

    func resumeSavedAt(for discourseID: String) -> Date? {
        // A playing talk's position is live, so it is newer than any save.
        if player.currentTrackId == discourseID, player.isPlaying { return Date() }
        return playbackState.lastSaved(discourseId: discourseID)
    }

    func duration(for discourseID: String) -> Double {
        if player.currentTrackId == discourseID, player.duration.isFinite, player.duration > 0 { return player.duration }
        return playbackState.getDuration(discourseId: discourseID)
    }
}

/// Sends downloaded audio to the Watch and remembers what the Watch last said it holds.
/// The Watch owns its copies: deleting a phone download never removes one.
@Observable
@MainActor
final class WatchTransferService {
    enum Outcome: Equatable, Sendable {
        case queued
        case alreadySending
        case alreadyOnWatch
    }

    enum Failure: Error, Equatable, Sendable {
        case unknownDiscourse
        case notDownloaded
        case notPaired
        case watchAppNotInstalled
        case unavailable
        case copyFailed

        var message: String {
            switch self {
            case .unknownDiscourse: return "This discourse is no longer in the catalog."
            case .notDownloaded: return "Download this discourse on your iPhone first."
            case .notPaired: return "Pair an Apple Watch with this iPhone first."
            case .watchAppNotInstalled: return "Install Osho Talks on your Apple Watch first."
            case .unavailable: return "Your iPhone can't reach Apple Watch right now. Try again in a moment."
            case .copyFailed: return "This discourse couldn't be prepared for Apple Watch. Try again."
            }
        }

        var logLabel: String {
            switch self {
            case .unknownDiscourse: return "unknownDiscourse"
            case .notDownloaded: return "notDownloaded"
            case .notPaired: return "notPaired"
            case .watchAppNotInstalled: return "notInstalled"
            case .unavailable: return "unavailable"
            case .copyFailed: return "copyFailed"
            }
        }
    }

    static let inventoryKey = "watch.inventory.v1"

    /// Last inventory the Watch reported, in its order.
    private(set) var inventory: [String]
    /// Transfers queued or in flight.
    private(set) var sending: Set<String> = []
    /// Discourses whose last transfer failed, with a listener-facing reason.
    private(set) var failures: [String: String] = [:]
    var linkState: WatchLinkState = .activating

    @ObservationIgnored private let sink: any WatchFileTransferSink
    @ObservationIgnored private let library: any WatchTransferLibrary
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let stagingDirectory: URL
    @ObservationIgnored private let fileManager = FileManager.default
    /// Clones queued by this process stay until their own finish callback; the
    /// session's outstanding list can lag right after `transferFile`.
    @ObservationIgnored private var stagedThisLaunch: Set<String> = []
    /// Discourses queued this launch, until their finish callback.
    @ObservationIgnored private var queuedThisLaunch: Set<String> = []

    init(
        sink: any WatchFileTransferSink, library: any WatchTransferLibrary, defaults: UserDefaults = .standard,
        stagingDirectory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WatchTransfers", isDirectory: true)
    ) {
        self.sink = sink
        self.library = library
        self.defaults = defaults
        self.stagingDirectory = stagingDirectory
        inventory = defaults.stringArray(forKey: Self.inventoryKey) ?? []
        linkState = sink.linkState
    }

    var inventorySet: Set<String> { Set(inventory) }

    func updateInventory(_ ids: [String]) {
        var seen = Set<String>()
        let cleaned = ids.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard cleaned != inventory else { return }
        inventory = cleaned
        defaults.set(cleaned, forKey: Self.inventoryKey)
        for id in cleaned { failures[id] = nil }
    }

    /// Re-reads outstanding transfers, which survive relaunch inside WatchConnectivity.
    func refresh() {
        linkState = sink.linkState
        // Before activation the session reports nothing outstanding, which must not discard staged files.
        guard case .ready = linkState else { return }
        let outstanding = sink.outstandingTransferDiscourseIDs()
        sending = outstanding.union(queuedThisLaunch)
        if outstanding.isEmpty { removeStagedFiles() }
    }

    func send(_ discourseID: String) throws(Failure) -> Outcome {
        guard let entry = Catalog.discourseLookup[discourseID] else { throw .unknownDiscourse }
        linkState = sink.linkState
        if inventorySet.contains(discourseID) { return .alreadyOnWatch }
        if sending.contains(discourseID) || sink.outstandingTransferDiscourseIDs().contains(discourseID) {
            sending.insert(discourseID)
            return .alreadySending
        }
        do {
            try queue(discourseID, entry: entry)
            failures[discourseID] = nil
            sending.insert(discourseID)
            queuedThisLaunch.insert(discourseID)
            Logger.watchSession.info("transfer queued")
            return .queued
        } catch {
            failures[discourseID] = error.message
            Logger.watchSession.info("transfer not queued: \(error.logLabel, privacy: .public)")
            throw error
        }
    }

    func transferFinished(discourseID: String?, fileURL: URL, succeeded: Bool) {
        if fileURL.deletingLastPathComponent().standardizedFileURL == stagingDirectory.standardizedFileURL {
            try? fileManager.removeItem(at: fileURL)
            stagedThisLaunch.remove(fileURL.lastPathComponent)
        }
        guard let discourseID else { return }
        sending.remove(discourseID)
        queuedThisLaunch.remove(discourseID)
        if succeeded {
            // Optimistic until the Watch's next inventory, which is authoritative.
            if !inventory.contains(discourseID) { updateInventory(inventory + [discourseID]) }
            Logger.watchSession.info("transfer finished")
        } else {
            failures[discourseID] = "Sending to Apple Watch didn't finish. Try again from Apple Watch."
            Logger.watchSession.info("transfer failed")
        }
    }

    private func queue(_ discourseID: String, entry: (discourse: CatalogDiscourse, series: SeriesInfo)) throws(Failure) {
        switch linkState {
        case .ready(let paired, let installed, _):
            guard paired else { throw .notPaired }
            guard installed else { throw .watchAppNotInstalled }
        default:
            throw .unavailable
        }
        guard let source = library.localFileURL(for: discourseID) else { throw .notDownloaded }
        let file = CompanionOfflineFile(
            discourseID: discourseID, title: entry.discourse.displayTitle, series: entry.series.name,
            resumePosition: max(0, library.resumePosition(for: discourseID)),
            duration: max(0, library.duration(for: discourseID)),
            resumeSavedAt: library.resumeSavedAt(for: discourseID)
        )
        let metadata: Data
        do { metadata = try CompanionWire.encode(file) } catch { throw .copyFailed }
        // A clone keeps the transfer intact if Smart Delete or the listener removes the download mid-flight.
        let staged = stagingDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(source.pathExtension.isEmpty ? "mp3" : source.pathExtension)
        do {
            try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: staged)
        } catch {
            throw .copyFailed
        }
        do {
            try sink.transferFile(staged, metadata: metadata)
            stagedThisLaunch.insert(staged.lastPathComponent)
        } catch {
            try? fileManager.removeItem(at: staged)
            throw .unavailable
        }
    }

    private func removeStagedFiles() {
        guard let files = try? fileManager.contentsOfDirectory(at: stagingDirectory, includingPropertiesForKeys: nil) else { return }
        for file in files where !stagedThisLaunch.contains(file.lastPathComponent) {
            try? fileManager.removeItem(at: file)
        }
    }
}
#endif
