import AVFoundation
import Foundation
import MediaPlayer
import Observation
import OSLog

/// Plays discourses stored on the watch. Long-form audio routes to Bluetooth headphones; activation
/// shows the system route picker when none is connected.
@MainActor @Observable
final class OfflinePlayer {
    private(set) var current: OfflineEntry?
    private(set) var isPlaying = false
    private(set) var isActivating = false
    private(set) var elapsed: Double = 0
    private(set) var duration: Double = 0
    private(set) var rate: Float = 1
    private(set) var errorMessage: String?

    nonisolated static let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
    static let saveInterval: TimeInterval = 10
    static let routeMessage = "Connect Bluetooth headphones to listen on Apple Watch."

    @ObservationIgnored private let library: OfflineLibrary
    @ObservationIgnored private let recorder: ListeningRecorder
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    @ObservationIgnored private var lastSavedAt: TimeInterval = 0
    @ObservationIgnored private var commandsInstalled = false

    init(library: OfflineLibrary, reporter: PositionReporter) {
        self.library = library
        recorder = ListeningRecorder(library: library, reporter: reporter)
        library.willDelete = { [weak self] id in
            if self?.current?.discourseID == id { self?.stop() }
        }
        library.loadedDiscourseID = { [weak self] in self?.current?.discourseID }
    }

    var hasItem: Bool { current != nil }

    func play(_ entry: OfflineEntry) {
        if current?.discourseID == entry.discourseID, player != nil {
            resume()
            return
        }
        stop()
        // Nothing is loaded now, so newer phone listening for this talk applies before it starts.
        library.applyPhonePositions()
        let entry = library.entry(for: entry.discourseID) ?? entry
        let url = library.store.fileURL(for: entry)
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "This talk is missing from Apple Watch. Save it again from iPhone."
            return
        }
        current = entry
        recorder.load(entry)
        duration = entry.duration
        elapsed = entry.startPosition
        let savedRate = UserDefaults.standard.float(forKey: Self.rateKey)
        rate = Self.rates.contains(savedRate) ? savedRate : 1
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .timeDomain
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        self.player = player
        observe(player, item: item)
        installRemoteCommands()
        if elapsed > 0 { player.seek(to: CMTime(seconds: elapsed, preferredTimescale: 600)) }
        resume()
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func resume() {
        guard player != nil, !isActivating else { return }
        errorMessage = nil
        isActivating = true
        Task { [weak self] in
            let ok = await Self.activateSession()
            guard let self else { return }
            isActivating = false
            guard ok else {
                errorMessage = Self.routeMessage
                return
            }
            guard let player else { return }
            if let duration = current?.duration, duration > 0, elapsed >= duration - 0.5 {
                await player.seek(to: .zero)
                elapsed = 0
            }
            player.playImmediately(atRate: rate)
            isPlaying = true
            recorder.playbackStarted()
            updateNowPlaying()
        }
    }

    func pause() {
        guard let player else { return }
        player.pause()
        isPlaying = false
        persist(finished: false, reason: .pause)
        updateNowPlaying()
    }

    func skip(by seconds: Double) {
        guard let player else { return }
        let limit = duration > 0 ? duration : .greatestFiniteMagnitude
        let target = max(0, min(elapsed + seconds, limit))
        elapsed = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        updateNowPlaying()
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        UserDefaults.standard.set(newRate, forKey: Self.rateKey)
        if isPlaying { player?.rate = newRate }
        updateNowPlaying()
    }

    /// Saves when the app leaves the foreground; only listening the phone has not had is reported.
    func saveNow() {
        guard current != nil else { return }
        persist(finished: false, reason: isPlaying ? nil : .pause)
    }

    func stop() {
        let wasLoaded = current != nil
        if wasLoaded, player != nil { persist(finished: false, reason: .pause) }
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
        player = nil
        current = nil
        isPlaying = false
        elapsed = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if wasLoaded { library.applyPhonePositions() }
    }

    // MARK: Private

    private static let rateKey = "osho.watch.offlineRate"

    private func observe(_ player: AVPlayer, item: AVPlayerItem) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 10), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let began = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                == AVAudioSession.InterruptionType.began.rawValue
            MainActor.assumeIsolated { if began { self?.pause() } }
        }
    }

    private func tick(_ time: CMTime) {
        guard let player else { return }
        let seconds = time.seconds
        if seconds.isFinite { elapsed = max(0, seconds) }
        if let itemDuration = player.currentItem?.duration.seconds, itemDuration.isFinite, itemDuration > 0 {
            duration = itemDuration
        }
        let playing = player.timeControlStatus != .paused
        if playing != isPlaying {
            isPlaying = playing
            if !playing { persist(finished: false, reason: .pause) }
            updateNowPlaying()
        }
        guard isPlaying else { return }
        // Periodic reports ride on saves, so each one carries a stored position and its stamp.
        if WatchClock.now - lastSavedAt >= Self.saveInterval { persist(finished: false, reason: .tick) }
    }

    private func finish() {
        isPlaying = false
        if duration > 0 { elapsed = duration }
        persist(finished: true, reason: .finish)
        updateNowPlaying()
    }

    private func persist(finished: Bool, reason: PositionReportPolicy.Reason?) {
        guard let entry = current else { return }
        lastSavedAt = WatchClock.now
        current = recorder.save(
            entry.discourseID, position: elapsed, duration: duration > 0 ? duration : nil,
            finished: finished, report: reason
        ) ?? entry
    }

    private func updateNowPlaying() {
        guard let entry = current else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: entry.title,
            MPMediaItemPropertyArtist: entry.series,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
    }

    private func installRemoteCommands() {
        guard !commandsInstalled else { return }
        commandsInstalled = true
        Self.installCommands { [weak self] command in
            Task { @MainActor [weak self] in self?.handle(command) }
        }
    }

    private func handle(_ command: RemoteCommand) {
        switch command {
        case .play: resume()
        case .pause: pause()
        case .toggle: togglePlayPause()
        case .forward: skip(by: 30)
        case .backward: skip(by: -15)
        case .rate(let value): setRate(value)
        }
    }

    fileprivate enum RemoteCommand: Sendable {
        case play, pause, toggle, forward, backward
        case rate(Float)
    }

    // Handlers are created outside main-actor isolation; MediaPlayer may call them on any queue.
    nonisolated private static func installCommands(_ handler: @escaping @Sendable (RemoteCommand) -> Void) {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { _ in handler(.play); return .success }
        center.pauseCommand.addTarget { _ in handler(.pause); return .success }
        center.togglePlayPauseCommand.addTarget { _ in handler(.toggle); return .success }
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { _ in handler(.forward); return .success }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { _ in handler(.backward); return .success }
        center.changePlaybackRateCommand.supportedPlaybackRates = rates.map { NSNumber(value: $0) }
        center.changePlaybackRateCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            handler(.rate(event.playbackRate))
            return .success
        }
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }

    nonisolated private static func activateSession() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
            let activated = try await session.activate(options: [])
            if !activated { Logger.watchOffline.info("audio route not chosen") }
            return activated
        } catch {
            Logger.watchOffline.error("audio session activation failed")
            return false
        }
    }
}
