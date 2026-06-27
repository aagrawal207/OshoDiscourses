import Foundation
import AVFoundation
import ActivityKit
import MediaPlayer
import Observation
import UIKit

@Observable
@MainActor
final class AudioPlayerService {

    // MARK: - Public State

    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var currentTrackId: String?
    var currentTitle: String = ""
    var currentSeries: String = ""
    var playbackRate: Float = 1.0
    var volume: Float = 1.0

    // MARK: - Queue

    struct QueueItem: Sendable {
        let id: String
        let url: URL
        let title: String
        let series: String
    }

    private(set) var queue: [QueueItem] = []
    private(set) var currentIndex: Int = 0

    var hasNext: Bool { currentIndex < queue.count - 1 }
    var hasPrevious: Bool { currentIndex > 0 }

    // MARK: - Noise Reduction / Voice Filter

    enum DenoiseStrength: String, CaseIterable, Sendable {
        case light, medium, strong
        /// Wet (denoised) fraction. Lower = clearer voice, higher = more noise removed.
        var wetMix: Float {
            switch self {
            case .light: return 0.35
            case .medium: return 0.5
            case .strong: return 0.6
            }
        }
        var label: String {
            switch self {
            case .light: return "Light"
            case .medium: return "Medium"
            case .strong: return "Strong"
            }
        }
    }

    var isNoiseReductionEnabled: Bool = false {
        didSet { rebuildAudioMix() }
    }
    var denoiseStrength: DenoiseStrength = .medium {
        didSet {
            noiseProcessor.wetMix = denoiseStrength.wetMix
            UserSettings.shared.denoiseStrength = denoiseStrength.rawValue
        }
    }
    private let noiseProcessor = NoiseReductionProcessor()

    // MARK: - Playback State

    weak var playbackStateService: PlaybackStateService?
    weak var downloadService: DownloadService?

    // MARK: - Position History (Kindle-style)

    private(set) var previousPosition: TimeInterval?
    var hasPreviousPosition: Bool { previousPosition != nil }

    // MARK: - Live Activity

    private var liveActivity: Activity<PlaybackAttributes>?
    private var liveActivityDismissTask: Task<Void, Never>?

    // MARK: - Private

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?

    // MARK: - Init

    init() {
        isNoiseReductionEnabled = UserSettings.shared.noiseReduction
        denoiseStrength = DenoiseStrength(rawValue: UserSettings.shared.denoiseStrength) ?? .medium
        noiseProcessor.wetMix = denoiseStrength.wetMix
        setupAudioSession()
        setupRemoteCommands()
        setupLiveActivityBridge()
    }

    /// Cleanup is handled by `stop()`. Since AudioPlayerService is MainActor-isolated,
    /// we cannot safely access isolated properties from deinit in Swift 6.
    /// The AVPlayer will be deallocated with the service, which stops playback.

    // MARK: - Public API

    func play(localURL: URL, id: String, title: String, series: String) {
        queue = [QueueItem(id: id, url: localURL, title: title, series: series)]
        currentIndex = 0
        loadAndPlay(item: queue[0])
    }

    func playQueue(items: [QueueItem], startIndex: Int = 0) {
        guard !items.isEmpty else { return }
        queue = items
        currentIndex = min(startIndex, items.count - 1)
        loadAndPlay(item: queue[currentIndex])
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            scheduleLiveActivityDismiss()
        } else {
            player.play()
            player.rate = playbackRate
            isPlaying = true
            liveActivityDismissTask?.cancel()
            liveActivityDismissTask = nil
        }
        updateNowPlayingInfo()
        updateLiveActivity()
    }

    private func scheduleLiveActivityDismiss() {
        liveActivityDismissTask?.cancel()
        liveActivityDismissTask = Task {
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled, !isPlaying else { return }
            endLiveActivity()
        }
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        currentTime = time
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.updateNowPlayingInfo()
            }
        }
    }

    func seekWithHistory(to time: TimeInterval) {
        guard abs(currentTime - time) > 10 else {
            seek(to: time)
            return
        }
        previousPosition = currentTime
        seek(to: time)
    }

    func returnToPreviousPosition() {
        guard let prev = previousPosition else { return }
        let current = currentTime
        seek(to: prev)
        previousPosition = current
    }

    func clearPositionHistory() {
        previousPosition = nil
    }

    func skipForward(_ seconds: TimeInterval = 30) {
        let target = currentTime + seconds
        if target >= duration - 1 {
            finishCurrentTrack()
        } else {
            seek(to: target)
        }
    }

    func skipBackward(_ seconds: TimeInterval = 15) {
        let target = max(currentTime - seconds, 0)
        seek(to: target)
    }

    func skipToNext() {
        guard hasNext else { return }
        currentIndex += 1
        loadAndPlay(item: queue[currentIndex])
    }

    func skipToPrevious() {
        // If more than 3 seconds in, restart current track
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        guard hasPrevious else {
            seek(to: 0)
            return
        }
        currentIndex -= 1
        loadAndPlay(item: queue[currentIndex])
    }

    private func finishCurrentTrack() {
        player?.pause()
        let completedTrackId = currentTrackId
        markCurrentAsCompleted()

        let shouldAutoPlay = hasNext && UserSettings.shared.autoPlayNext
        if shouldAutoPlay {
            skipToNext()
        } else {
            isPlaying = false
            currentTime = duration
            updateNowPlayingInfo()
            endLiveActivity()
            currentTrackId = nil
            currentTitle = ""
            currentSeries = ""
        }

        // Smart Delete: remove the completed episode
        if let completedId = completedTrackId {
            performSmartDelete(completedDiscourseId: completedId)
        }

        // Smart Download fallback: if pre-emptive didn't fire (short tracks), trigger now
        if let completedId = completedTrackId, !didTriggerPreemptiveDownload {
            performSmartDownload(afterDiscourseId: completedId)
        }
    }

    private func markCurrentAsCompleted() {
        guard let trackId = currentTrackId else { return }
        playbackStateService?.markListenedComplete(discourseId: trackId)
        playbackStateService?.clearPosition(discourseId: trackId)
    }

    // MARK: - Smart Download / Smart Delete

    private func performSmartDelete(completedDiscourseId: String) {
        guard UserSettings.shared.smartDelete else { return }
        guard let downloadService, downloadService.isDownloaded(completedDiscourseId) else { return }
        try? downloadService.deleteDownload(discourseID: completedDiscourseId)
    }

    private func performSmartDownload(afterDiscourseId: String) {
        guard UserSettings.shared.smartDownload else { return }
        guard let downloadService else { return }
        guard let lookup = Catalog.discourseLookup[afterDiscourseId] else { return }

        let series = lookup.series
        let allInSeries = Catalog.discourses(for: series)

        // Find the completed discourse's index in the series
        guard let completedIndex = allInSeries.firstIndex(where: { $0.id == afterDiscourseId }) else { return }

        // Find the next discourse in the series that is not already downloaded
        let remaining = allInSeries.suffix(from: allInSeries.index(after: completedIndex))
        guard let nextToDownload = remaining.first(where: { !downloadService.isDownloaded($0.id) }) else { return }

        Task {
            _ = try? await downloadService.download(nextToDownload)
        }
    }

    func setRate(_ rate: Float) {
        let clamped = max(0.5, min(rate, 2.0))
        playbackRate = clamped
        if isPlaying {
            player?.rate = clamped
        }
        updateNowPlayingInfo()
    }

    func setVolume(_ vol: Float) {
        let clamped = max(0.0, min(vol, 2.0))
        volume = clamped
        player?.volume = min(clamped, 1.0)
        if let currentItem = player?.currentItem {
            applyAudioMix(to: currentItem)
        }
    }

    func stop() {
        player?.pause()
        isPlaying = false
        currentTime = 0
        duration = 0
        currentTrackId = nil
        currentTitle = ""
        currentSeries = ""
        removeTimeObserver()
        removeEndObserver()
        player = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        endLiveActivity()
    }

    // MARK: - Private: Playback

    private func loadAndPlay(item: QueueItem) {
        // Save position+duration of the outgoing track before switching
        if let outgoingId = currentTrackId, currentTime > 0 {
            playbackStateService?.savePosition(discourseId: outgoingId, position: currentTime, duration: duration)
        }

        removeTimeObserver()
        removeEndObserver()
        statusObservation?.invalidate()

        currentTrackId = item.id
        currentTitle = item.title
        currentSeries = item.series
        currentTime = 0
        duration = 0
        didTriggerPreemptiveDownload = false

        let playerItem = AVPlayerItem(url: item.url)

        if player == nil {
            player = AVPlayer(playerItem: playerItem)
        } else {
            player?.replaceCurrentItem(with: playerItem)
        }

        player?.volume = min(volume, 1.0)
        noiseProcessor.reset()
        applyAudioMix(to: playerItem)

        // Observe when the item is ready to play
        statusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, item.status == .readyToPlay else { return }
                self.duration = item.duration.seconds.isFinite ? item.duration.seconds : 0

                // Resume from saved position if available
                let savedPosition = self.playbackStateService?.getPosition(discourseId: self.currentTrackId ?? "")
                if let saved = savedPosition, saved > 0, saved < self.duration - 5 {
                    self.seek(to: saved)
                    self.currentTime = saved
                }

                self.player?.play()
                self.player?.rate = self.playbackRate
                self.isPlaying = true
                self.setupTimeObserver()
                self.observePlayerEnd()
                self.updateNowPlayingInfo()
                self.startLiveActivity()
                self.playbackStateService?.recordPlay(discourseId: self.currentTrackId ?? "")
            }
        }
    }

    // MARK: - Private: Live Activity

    private func setupLiveActivityBridge() {
        let bridge = LiveActivityBridge.shared
        bridge.togglePlayPause = { [weak self] in self?.togglePlayPause() }
        bridge.skipForward = { [weak self] in self?.skipForward() }
        bridge.skipBack = { [weak self] in self?.skipBackward() }
    }

    private func startLiveActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // End any existing activity to avoid orphaning it on the Dynamic Island
        endLiveActivity()

        let attributes = PlaybackAttributes(
            seriesName: currentSeries,
            totalTracks: queue.count
        )
        let state = PlaybackAttributes.ContentState(
            title: currentTitle,
            trackNumber: currentIndex + 1,
            isPlaying: true,
            elapsedSeconds: currentTime,
            durationSeconds: duration,
            playbackRate: playbackRate
        )

        do {
            liveActivity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil),
                pushType: nil
            )
        } catch {
            // Live Activity not available on this device
        }
    }

    private func updateLiveActivity() {
        guard let activity = liveActivity else { return }
        let state = PlaybackAttributes.ContentState(
            title: currentTitle,
            trackNumber: currentIndex + 1,
            isPlaying: isPlaying,
            elapsedSeconds: currentTime,
            durationSeconds: duration,
            playbackRate: playbackRate
        )
        let content = ActivityContent(state: state, staleDate: nil)
        nonisolated(unsafe) let act = activity
        Task.detached {
            await act.update(content)
        }
    }

    private func endLiveActivity() {
        guard let activity = liveActivity else { return }
        let finalState = PlaybackAttributes.ContentState(
            title: currentTitle,
            trackNumber: currentIndex + 1,
            isPlaying: false,
            elapsedSeconds: currentTime,
            durationSeconds: duration,
            playbackRate: playbackRate
        )
        let content = ActivityContent(state: finalState, staleDate: nil)
        nonisolated(unsafe) let act = activity
        Task.detached {
            await act.end(content, dismissalPolicy: .immediate)
        }
        liveActivity = nil
    }

    // MARK: - Private: Audio Session

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            // RNNoise is trained at 48kHz; hint the session toward that rate so the
            // denoiser operates closest to its trained band layout. The OS may pick
            // a different rate — the processor handles whatever rate it receives.
            try? session.setPreferredSampleRate(48000)
            try session.setActive(true)
        } catch {
            // Audio session setup failed; playback may not work in background
        }
    }

    // MARK: - Private: Remote Commands

    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self, self.player != nil else { return .commandFailed }
            Task { @MainActor [weak self] in
                self?.togglePlayPause()
            }
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.isPlaying else { return .commandFailed }
            Task { @MainActor [weak self] in
                self?.togglePlayPause()
            }
            return .success
        }

        commandCenter.skipForwardCommand.preferredIntervals = [30]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            guard let self, self.player != nil else { return .commandFailed }
            Task { @MainActor [weak self] in
                self?.skipForward()
            }
            return .success
        }

        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self, self.player != nil else { return .commandFailed }
            Task { @MainActor [weak self] in
                self?.skipBackward()
            }
            return .success
        }

        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, self.player != nil else { return .commandFailed }
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor [weak self] in
                self?.seek(to: event.positionTime)
            }
            return .success
        }

        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, self.hasNext else { return .noActionableNowPlayingItem }
            Task { @MainActor [weak self] in
                self?.skipToNext()
            }
            return .success
        }

        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.skipToPrevious()
            }
            return .success
        }
    }

    // MARK: - Private: Now Playing

    private let nowPlayingArtwork: MPMediaItemArtwork? = {
        guard let image = UIImage(named: "OshoPortrait") else { return nil }
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }()

    private func updateNowPlayingInfo() {
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = currentTitle
        info[MPMediaItemPropertyArtist] = "Osho"
        info[MPMediaItemPropertyAlbumTitle] = currentSeries
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        if let artwork = nowPlayingArtwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Private: Time Observer

    private var lastLiveActivityUpdate: TimeInterval = 0
    private var didTriggerPreemptiveDownload = false

    private func setupTimeObserver() {
        removeTimeObserver()
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }
                let seconds = time.seconds
                if seconds.isFinite {
                    self.currentTime = seconds
                    // Update Live Activity every 5 seconds
                    if seconds - self.lastLiveActivityUpdate >= 5 {
                        self.lastLiveActivityUpdate = seconds
                        self.updateLiveActivity()
                    }
                    // Pre-emptive smart download: 20 seconds before end
                    if !self.didTriggerPreemptiveDownload,
                       self.duration > 30,
                       seconds >= self.duration - 20,
                       let trackId = self.currentTrackId {
                        self.didTriggerPreemptiveDownload = true
                        self.performSmartDownload(afterDiscourseId: trackId)
                    }
                }
            }
        }
    }

    private func removeTimeObserver() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
    }

    // MARK: - Private: End Observer

    private func observePlayerEnd() {
        removeEndObserver()
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player?.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.finishCurrentTrack()
            }
        }
    }

    private func removeEndObserver() {
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
            endObserver = nil
        }
    }

    // MARK: - Private: Audio Mix (Noise Reduction / Voice Filter + Volume Boost)

    private func applyAudioMix(to item: AVPlayerItem) {
        Task {
            guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first else { return }
            let boost = volume > 1.0 ? volume : Float(1.0)

            if isNoiseReductionEnabled {
                guard let mix = noiseProcessor.createAudioMix(for: track, volumeBoost: boost) else { return }
                await MainActor.run { item.audioMix = mix }
            } else if volume > 1.0 {
                let params = AVMutableAudioMixInputParameters(track: track)
                params.setVolume(volume, at: .zero)
                let mix = AVMutableAudioMix()
                mix.inputParameters = [params]
                await MainActor.run { item.audioMix = mix }
            } else {
                await MainActor.run { item.audioMix = nil }
            }
        }
    }

    private func rebuildAudioMix() {
        guard let item = player?.currentItem else { return }
        noiseProcessor.reset()
        applyAudioMix(to: item)
        UserSettings.shared.noiseReduction = isNoiseReductionEnabled
    }
}
