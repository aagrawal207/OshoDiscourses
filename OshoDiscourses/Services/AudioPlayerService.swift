import Foundation
import AVFoundation
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

    // MARK: - Private

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?

    // Audio-session lifecycle observers. iOS tears the session down on calls,
    // Siri, alarms, and headphone changes; without these we never reattach and
    // the Now Playing controls (Control Center, Lock Screen, AirPods) go dead.
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var wasPlayingBeforeInterruption = false

    // MARK: - Init

    init() {
        isNoiseReductionEnabled = UserSettings.shared.noiseReduction
        denoiseStrength = DenoiseStrength(rawValue: UserSettings.shared.denoiseStrength) ?? .medium
        noiseProcessor.wetMix = denoiseStrength.wetMix
        // Restore the listener's preferred speed; clamp in case a stale/corrupt
        // value was stored outside the supported 0.5–2.0 range.
        playbackRate = max(0.5, min(Float(UserSettings.shared.defaultPlaybackRate), 2.0))
        setupAudioSession()
        setupRemoteCommands()
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
        } else {
            // Reclaim the session in case it was deactivated while we were paused
            // (interruption, another app, backgrounding) so controls reappear.
            activateSession()
            player.play()
            player.rate = playbackRate
            isPlaying = true
        }
        updateNowPlayingInfo()
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

        // End-of-discourse sleep: let this talk finish, then stop here (don't
        // auto-advance). discourseDidFinish() resets the timer afterward.
        let endSleepArmed = SleepTimerService.shared.mode == .endOfDiscourse
        let shouldAutoPlay = hasNext && UserSettings.shared.autoPlayNext && !endSleepArmed
        if shouldAutoPlay {
            skipToNext()
        } else {
            isPlaying = false
            currentTime = duration
            updateNowPlayingInfo()
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

        // Notify the sleep timer so an armed end-of-discourse timer fires/resets.
        SleepTimerService.shared.discourseDidFinish()
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
        // Persist so the chosen speed survives relaunch. The in-player picker is
        // the single source of truth — no separate "remember speed" toggle.
        UserSettings.shared.defaultPlaybackRate = Double(clamped)
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

                // Activate the session at the moment playback actually begins, so
                // we acquire audio focus and the Now Playing controls light up.
                self.activateSession()
                self.player?.play()
                self.player?.rate = self.playbackRate
                self.isPlaying = true
                self.setupTimeObserver()
                self.observePlayerEnd()
                self.updateNowPlayingInfo()
                self.playbackStateService?.recordPlay(discourseId: self.currentTrackId ?? "")
            }
        }
    }

    // MARK: - Private: Audio Session

    /// Configures the session category once and starts listening for the system
    /// events that otherwise silently kill our Now Playing controls. Activation
    /// itself is deferred to `activateSession()` right before playback, since
    /// activating at launch can fail if another app currently holds audio focus.
    private func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            // RNNoise is trained at 48kHz; hint the session toward that rate so the
            // denoiser operates closest to its trained band layout. The OS may pick
            // a different rate — the processor handles whatever rate it receives.
            try? session.setPreferredSampleRate(48000)
        } catch {
            print("[AudioSession] category setup failed: \(error)")
        }
        observeInterruptions()
        observeRouteChanges()
    }

    /// Activates the audio session. Called right before playback and whenever we
    /// need to reclaim focus (interruption end, route change, foreground return).
    /// Returns true on success so callers can decide whether to proceed.
    @discardableResult
    private func activateSession() -> Bool {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            return true
        } catch {
            print("[AudioSession] activation failed: \(error)")
            return false
        }
    }

    /// Re-claims the session and refreshes Now Playing when the app returns to the
    /// foreground. iOS may have handed audio focus to another app while we were
    /// backgrounded; this puts our controls back without requiring a relaunch.
    func handleForegroundReturn() {
        guard currentTrackId != nil else { return }
        activateSession()
        updateNowPlayingInfo()
    }

    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            // Notification isn't Sendable, so pull out the primitive (Sendable)
            // values here on the main queue, then hop onto the main actor with
            // just those to touch our isolated state safely.
            let info = notification.userInfo
            let typeValue = info?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionValue = info?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated {
                self?.handleInterruption(typeValue: typeValue, optionValue: optionValue)
            }
        }
    }

    private func handleInterruption(typeValue: UInt?, optionValue: UInt?) {
        guard let typeValue, let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            // iOS has already paused us. Remember whether we were playing so we
            // can resume if the system says it's okay.
            wasPlayingBeforeInterruption = isPlaying
            isPlaying = false
            updateNowPlayingInfo()

        case .ended:
            // Reactivate the session no matter what, so the controls come back even
            // if we don't auto-resume. Then resume only if iOS grants .shouldResume
            // AND we were playing before.
            activateSession()
            let options = optionValue.map { AVAudioSession.InterruptionOptions(rawValue: $0) } ?? []
            if player != nil,
               Self.shouldResumeAfterInterruption(wasPlaying: wasPlayingBeforeInterruption, options: options) {
                player?.play()
                player?.rate = playbackRate
                isPlaying = true
            }
            wasPlayingBeforeInterruption = false
            updateNowPlayingInfo()

        @unknown default:
            break
        }
    }

    /// Pure resume decision after an interruption ends: only resume if we were
    /// playing when the interruption began AND iOS says it's okay (.shouldResume).
    /// Extracted (and nonisolated, since it touches no actor state) so the branch
    /// logic is unit-testable without AVFoundation or MainActor hopping.
    nonisolated static func shouldResumeAfterInterruption(
        wasPlaying: Bool,
        options: AVAudioSession.InterruptionOptions
    ) -> Bool {
        wasPlaying && options.contains(.shouldResume)
    }

    private func observeRouteChanges() {
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                self?.handleRouteChange(reasonValue: reasonValue)
            }
        }
    }

    private func handleRouteChange(reasonValue: UInt?) {
        guard let reasonValue,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        switch reason {
        case .oldDeviceUnavailable:
            // Headphones/AirPods were unplugged. Apple's convention: pause rather
            // than blast audio out of the speaker.
            if isPlaying {
                player?.pause()
                isPlaying = false
                updateNowPlayingInfo()
            }
        case .newDeviceAvailable, .categoryChange, .override:
            // A new output appeared or the route otherwise changed; make sure we
            // still hold the session and the controls reflect current state.
            if currentTrackId != nil {
                activateSession()
                updateNowPlayingInfo()
            }
        default:
            break
        }
    }

    // MARK: - Private: Remote Commands

    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // AirPods and most Bluetooth/wired headsets send a single TOGGLE command,
        // not separate play/pause. Handling this is what makes the AirPods pinch /
        // headset button work reliably.
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, self.player != nil else { return .commandFailed }
            Task { @MainActor [weak self] in
                self?.togglePlayPause()
            }
            return .success
        }

        // Explicit play. Guard only on having a player — never on isPlaying, which
        // can be stale after an interruption and would wrongly report failure,
        // making the control look dead.
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self, let player = self.player else { return .commandFailed }
            Task { @MainActor [weak self] in
                guard let self, !self.isPlaying else { return }
                self.activateSession()
                player.play()
                player.rate = self.playbackRate
                self.isPlaying = true
                self.updateNowPlayingInfo()
            }
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self, let player = self.player else { return .commandFailed }
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }
                player.pause()
                self.isPlaying = false
                self.updateNowPlayingInfo()
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
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
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
