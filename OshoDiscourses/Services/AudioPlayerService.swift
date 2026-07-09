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

    // In-flight seek tracking. Seeks are async and zero-tolerance (they can take
    // a moment to land), while the periodic observer fires every 0.5s. Without
    // this, the observer overwrites `currentTime` with the player's *pre-seek*
    // clock mid-seek, so a rapid burst of skip taps (e.g. from the lock screen)
    // all read the same stale position and never accumulate — the skip lands
    // well short of where it should. `pendingSeekTarget` holds where we're
    // seeking *to*; skips accumulate from it, and the observer defers to it.
    // `seekGeneration` makes the completion idempotent: only the most recent
    // seek clears the pending target, so a superseded seek can't wipe it early.
    //
    // `pendingSeekIssuedAt` guards against the opposite failure: a seek whose
    // completion never arrives (app suspended on the lock screen mid-seek,
    // media services reset, interruption). Without it, a lost completion left
    // `pendingSeekTarget` set forever — the observer stopped tracking time and
    // skips anchored on a position minutes in the past, so a lock-screen -15
    // jumped back "2 minutes instead of 15 seconds". A pending target is only
    // trusted while fresh (`pendingSeekMaxAge`); after that the live player
    // clock is the truth again.
    private var pendingSeekTarget: TimeInterval?
    private var pendingSeekIssuedAt: Date?
    private var seekGeneration = 0

    // Audio-session lifecycle observers. iOS tears the session down on calls,
    // Siri, alarms, and headphone changes; without these we never reattach and
    // the Now Playing controls (Control Center, Lock Screen, AirPods) go dead.
    // The service lives for the app's lifetime (a single instance injected via
    // .environment), so these tokens are intentionally never removed.
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var mediaResetObserver: NSObjectProtocol?
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
        guard let player else {
            // No player but a current track means the player was torn down
            // under us (media services reset while paused). Rebuild at the
            // saved position instead of silently ignoring the tap.
            if currentTrackId != nil, queue.indices.contains(currentIndex) {
                loadAndPlay(item: queue[currentIndex])
            }
            return
        }
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
        // Record where we're headed so skips accumulate from the target (not the
        // stale player clock) and the periodic observer doesn't snap us back
        // while the seek is in flight.
        pendingSeekTarget = time
        pendingSeekIssuedAt = Date()
        seekGeneration += 1
        let generation = seekGeneration
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Only the most recent seek clears the pending target — a burst
                // of taps issues several seeks, and a stale completion must not
                // release the guard before the final one lands.
                if generation == self.seekGeneration {
                    self.pendingSeekTarget = nil
                    self.pendingSeekIssuedAt = nil
                }
                self.updateNowPlayingInfo()
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

    /// How long an in-flight seek's target is trusted as the skip anchor.
    /// Local-file seeks land in milliseconds; if a completion hasn't arrived
    /// after this long it was lost (suspension, media-services reset) and the
    /// live player clock is the truth again.
    nonisolated static let pendingSeekMaxAge: TimeInterval = 2.0

    /// The position a skip acts from. While a *fresh* seek is in flight this is
    /// the seek's target (not the player's lagging clock), so rapid taps
    /// accumulate: two +30s taps advance 60s, not 30s. A stale pending target
    /// (lost completion) is ignored — otherwise skips anchor on a position
    /// minutes in the past. The fallback reads the player's live clock, not
    /// `currentTime`: a stuck pending target also froze `currentTime`, so only
    /// the player itself knows where playback actually is.
    private var skipAnchor: TimeInterval {
        let liveClock = player?.currentTime().seconds
        let clock = (liveClock?.isFinite == true) ? liveClock! : currentTime
        return Self.skipAnchor(
            pendingTarget: pendingSeekTarget,
            pendingAge: pendingSeekIssuedAt.map { Date().timeIntervalSince($0) },
            currentTime: clock
        )
    }

    /// Pure anchor selection so the staleness rule is unit-testable without a
    /// player: trust the pending target only while its age is within
    /// `pendingSeekMaxAge`; otherwise fall back to the live clock.
    nonisolated static func skipAnchor(
        pendingTarget: TimeInterval?,
        pendingAge: TimeInterval?,
        currentTime: TimeInterval,
        maxAge: TimeInterval = AudioPlayerService.pendingSeekMaxAge
    ) -> TimeInterval {
        if let pendingTarget, let pendingAge, pendingAge <= maxAge {
            return pendingTarget
        }
        return currentTime
    }

    /// What a forward skip should do. Pure so the two things that actually caused
    /// bugs — accumulating from the right anchor and NOT finishing a track whose
    /// duration is still unknown — are unit-testable without a player. (The
    /// in-flight-seek *race* still needs an integration test; this only covers
    /// the arithmetic and the duration==0 guard.)
    enum SkipOutcome: Equatable {
        case seek(TimeInterval)
        case finish
    }

    nonisolated static func skipForwardOutcome(
        anchor: TimeInterval,
        seconds: TimeInterval,
        duration: TimeInterval
    ) -> SkipOutcome {
        // duration <= 0 means "not known yet" — advance, never finish.
        if duration > 0, anchor + seconds >= duration - 1 {
            return .finish
        }
        return .seek(anchor + seconds)
    }

    nonisolated static func skipBackwardTarget(
        anchor: TimeInterval,
        seconds: TimeInterval
    ) -> TimeInterval {
        max(anchor - seconds, 0)
    }

    func skipForward(_ seconds: TimeInterval = 30) {
        switch Self.skipForwardOutcome(anchor: skipAnchor, seconds: seconds, duration: duration) {
        case .finish:
            finishCurrentTrack()
        case .seek(let target):
            seek(to: target)
        }
    }

    func skipBackward(_ seconds: TimeInterval = 15) {
        seek(to: Self.skipBackwardTarget(anchor: skipAnchor, seconds: seconds))
    }

    func skipToNext() {
        guard hasNext else { return }
        currentIndex += 1
        loadAndPlay(item: queue[currentIndex])
    }

    /// Jump directly to a queue entry (from the Up Next list). No-op if the index
    /// is out of range or already playing.
    func playQueueItem(at index: Int) {
        guard queue.indices.contains(index), index != currentIndex else { return }
        currentIndex = index
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
        // Idempotency: a skipForward that lands .finish and the item's natural
        // DidPlayToEndTime can both call this for the same instant. The first
        // call either advances (new track id) or clears currentTrackId; a stray
        // second call for a track that's no longer current must not finish the
        // *next* track (double-skip) or re-fire smart delete / sleep timer.
        guard currentTrackId != nil else { return }
        player?.pause()
        let completedTrackId = currentTrackId
        markCurrentAsCompleted()

        // End-of-discourse sleep: let this talk finish, then stop here (don't
        // auto-advance). discourseDidFinish() resets the timer afterward.
        let endSleepArmed = SleepTimerService.shared.mode == .endOfDiscourse
        let autoNext = UserSettings.shared.autoPlayNext && !endSleepArmed

        // Auto-play is download-only. Prefer the queue's next item; if the queue
        // is exhausted — a single-item queue (e.g. started from a bookmark), or
        // the next talk only finished downloading after playback began — fall
        // back to the next *downloaded* discourse in the same series so a
        // fully-downloaded series plays straight through regardless of how
        // playback started. This never advances to a discourse not on disk.
        if autoNext, hasNext {
            skipToNext()
        } else if autoNext,
                  let completedTrackId,
                  let next = nextDownloadedItem(after: completedTrackId) {
            queue.append(next)
            currentIndex = queue.count - 1
            loadAndPlay(item: next)
        } else {
            isPlaying = false
            // Only snap to the end when we actually know it; duration is 0 until
            // the item is ready, and blanking to 0:00 would misreport a finish.
            if duration > 0 { currentTime = duration }
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

        // Finishing a discourse is a natural high point — a good, non-intrusive
        // moment to ask for an App Store rating. The service self-gates on active
        // days and once-per-version, so this is safe to call on every finish.
        ReviewRequestService.requestReviewIfAppropriate()
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

    /// The next *downloaded* discourse after the given one in the same series,
    /// as a ready-to-play QueueItem, or nil if none is on disk. Used by
    /// auto-play to continue past a queue that didn't include it (single-item
    /// queue, or a talk downloaded after playback started).
    private func nextDownloadedItem(after discourseId: String) -> QueueItem? {
        guard let downloadService,
              let lookup = Catalog.discourseLookup[discourseId] else { return nil }
        let allInSeries = Catalog.discourses(for: lookup.series)
        let orderedIds = allInSeries.map(\.id)
        guard let nextId = Self.nextDownloadedId(
            after: discourseId,
            in: orderedIds,
            isDownloaded: { downloadService.isDownloaded($0) }
        ), let disc = allInSeries.first(where: { $0.id == nextId }),
           let url = downloadService.localFileURL(for: nextId) else { return nil }

        return QueueItem(id: disc.id, url: url, title: disc.displayTitle, series: lookup.series.name)
    }

    /// The first downloaded id strictly after `current` in the ordered series,
    /// or nil if none. Pure so auto-play's advance rule is unit-testable without
    /// a player, filesystem, or catalog.
    nonisolated static func nextDownloadedId(
        after current: String,
        in orderedIds: [String],
        isDownloaded: (String) -> Bool
    ) -> String? {
        guard let idx = orderedIds.firstIndex(of: current) else { return nil }
        return orderedIds[orderedIds.index(after: idx)...].first(where: isDownloaded)
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

    private var volumeMixRebuildTask: Task<Void, Never>?

    func setVolume(_ vol: Float) {
        let clamped = max(0.0, min(vol, 2.0))
        let crossedBoostBoundary = (volume > 1.0) != (clamped > 1.0)
        volume = clamped
        player?.volume = min(clamped, 1.0)
        guard let currentItem = player?.currentItem else { return }
        // Volume ≤ 1.0 is handled entirely by player.volume; the audio mix only
        // carries the boost above 1.0 (and the denoise tap). Rebuilding the mix
        // creates a fresh MTAudioProcessingTap, so during a slider drag we
        // rebuild once when crossing the 1.0 boundary and otherwise debounce —
        // per-tick rebuilds thrash tap prepare/finalize while audio renders.
        if crossedBoostBoundary {
            volumeMixRebuildTask?.cancel()
            applyAudioMix(to: currentItem)
        } else if clamped > 1.0 {
            volumeMixRebuildTask?.cancel()
            volumeMixRebuildTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self, let item = self.player?.currentItem else { return }
                self.applyAudioMix(to: item)
            }
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
        pendingSeekTarget = nil
        pendingSeekIssuedAt = nil
        removeTimeObserver()
        removeEndObserver()
        // Kill the status observation too: a still-loading item's readyToPlay
        // would otherwise fire after stop and resurrect isPlaying/Now Playing.
        statusObservation?.invalidate()
        statusObservation = nil
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
        // Drop any in-flight seek from the outgoing track so it can't block the
        // new track's time observer.
        pendingSeekTarget = nil
        pendingSeekIssuedAt = nil
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
                guard let self else { return }
                // A corrupt/missing local file fails silently otherwise — the UI
                // sits at 0:00 with stale Now Playing. Surface a clean stopped
                // state; the track stays current so the user can retry.
                if item.status == .failed {
                    print("[Player] item failed to load: \(String(describing: item.error))")
                    self.isPlaying = false
                    self.updateNowPlayingInfo()
                    return
                }
                // `trackId` also guards against a late readyToPlay arriving after
                // stop(): with no current track there's nothing to start.
                guard item.status == .readyToPlay, let trackId = self.currentTrackId else { return }
                self.duration = item.duration.seconds.isFinite ? item.duration.seconds : 0

                // Resume from saved position if available
                let savedPosition = self.playbackStateService?.getPosition(discourseId: trackId)
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
                self.playbackStateService?.recordPlay(discourseId: trackId)
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
        observeMediaServicesReset()
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

    private func observeMediaServicesReset() {
        mediaResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleMediaServicesReset()
            }
        }
    }

    /// mediaserverd (the system audio daemon) crashed: the session category,
    /// the AVPlayer, and any audio tap are all invalid now, and playback plus
    /// Now Playing controls stay dead until relaunch. Apple's guidance is to
    /// reconfigure the session and rebuild every audio object from scratch.
    private func handleMediaServicesReset() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [])
        try? session.setPreferredSampleRate(48000)
        noiseProcessor.reset()

        guard currentTrackId != nil, queue.indices.contains(currentIndex) else {
            player = nil
            return
        }
        if isPlaying {
            // Rebuild and resume where we were. loadAndPlay saves the outgoing
            // position first, then its resume path seeks back to it.
            loadAndPlay(item: queue[currentIndex])
        } else {
            // Paused: don't blast audio unprompted. Drop the dead player but
            // keep track/position state; togglePlayPause rebuilds on demand.
            removeTimeObserver()
            removeEndObserver()
            statusObservation?.invalidate()
            statusObservation = nil
            pendingSeekTarget = nil
            pendingSeekIssuedAt = nil
            player = nil
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

        // Handler discipline: MPRemoteCommandCenter does not guarantee which
        // thread delivers events, so the closures must not read MainActor state
        // (player, isPlaying, hasNext) directly — all state access happens
        // inside the Task hop. The cost is returning .success optimistically;
        // a no-op on a dead player is harmless, while an off-actor read is a
        // data race the compiler can't see (the closure is formed in a
        // MainActor context, so captures aren't checked).

        // AirPods and most Bluetooth/wired headsets send a single TOGGLE command,
        // not separate play/pause. Handling this is what makes the AirPods pinch /
        // headset button work reliably.
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard self != nil else { return .commandFailed }
            Task { @MainActor [weak self] in
                self?.togglePlayPause()
            }
            return .success
        }

        // Explicit play. Never guard on isPlaying at dispatch time — it can be
        // stale after an interruption and would wrongly report failure, making
        // the control look dead. The player is re-read inside the hop so a
        // track change between dispatch and execution can't resume a replaced
        // (zombie) player instance.
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard self != nil else { return .commandFailed }
            Task { @MainActor [weak self] in
                guard let self, !self.isPlaying, let player = self.player else { return }
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
            guard self != nil else { return .commandFailed }
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying, let player = self.player else { return }
                player.pause()
                self.isPlaying = false
                self.updateNowPlayingInfo()
            }
            return .success
        }

        commandCenter.skipForwardCommand.preferredIntervals = [30]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            guard self != nil else { return .commandFailed }
            Task { @MainActor [weak self] in
                self?.skipForward()
            }
            return .success
        }

        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            guard self != nil else { return .commandFailed }
            Task { @MainActor [weak self] in
                self?.skipBackward()
            }
            return .success
        }

        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard self != nil, let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = event.positionTime
            Task { @MainActor [weak self] in
                self?.seek(to: position)
            }
            return .success
        }

        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard self != nil else { return .commandFailed }
            Task { @MainActor [weak self] in
                self?.skipToNext()
            }
            return .success
        }

        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard self != nil else { return .commandFailed }
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
                // Don't clobber currentTime while a seek is in flight — the
                // player's clock still reads the pre-seek position and would
                // snap us backward, breaking skip accumulation. But self-heal:
                // if the completion was lost (suspension, media-services reset),
                // release the guard once the seek is stale so time tracking
                // doesn't stay frozen forever.
                if self.pendingSeekTarget != nil {
                    let age = self.pendingSeekIssuedAt.map { Date().timeIntervalSince($0) } ?? .infinity
                    guard age > Self.pendingSeekMaxAge else { return }
                    self.pendingSeekTarget = nil
                    self.pendingSeekIssuedAt = nil
                }
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
        // Identity of the item we're observing (ObjectIdentifier is Sendable;
        // AVPlayerItem isn't, so it can't cross into the Task directly). If a
        // skip/finish replaces the item between notification delivery and Task
        // execution, the stale end event must not finish the *new* track.
        let observedItemID = (player?.currentItem).map(ObjectIdentifier.init)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player?.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      let observedItemID,
                      (self.player?.currentItem).map(ObjectIdentifier.init) == observedItemID else { return }
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
