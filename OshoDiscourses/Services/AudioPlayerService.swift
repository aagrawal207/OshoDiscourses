import Foundation
import AVFoundation
import MediaPlayer
import Observation
import UIKit
import os

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
        /// RNNoise's wet fraction; DeepFilterNet uses its native attenuation cap instead.
        var wetMix: Float {
            switch self {
            case .light: return 0.35
            case .medium: return 0.5
            case .strong: return 0.6
            }
        }
        var intensity: Float {
            switch self {
            case .light: return 0.45
            case .medium: return 0.7
            case .strong: return 1.0
            }
        }
        /// Native attenuation cap, independent of Voice Focus. Upstream treats 100 dB
        /// and above as unlimited; this is not RNNoise's wet/dry control.
        var attenuationLimitDb: Float {
            switch self {
            case .light: return 6
            case .medium: return 12
            case .strong: return 100
            }
        }
        var label: String {
            switch self {
            case .light: return "Light"
            case .medium: return "Medium"
            case .strong: return "Strong"
            }
        }

        var detail: String {
            switch self {
            case .light: return "Gentle cleanup that keeps more of the original sound."
            case .medium: return "A good starting point for most recordings."
            case .strong: return "More noise reduction. The voice may sound less natural."
            }
        }
    }

    enum AudioMixFailure: String, Equatable, Sendable {
        case trackLoading, noAudioTrack, tapCreation, playback

        var label: String {
            switch self {
            case .trackLoading: return "Couldn't load audio track"
            case .noAudioTrack: return "No audio track"
            case .tapCreation: return "Couldn't attach noise reduction"
            case .playback: return "Playback unavailable"
            }
        }
    }

    enum AudioProcessingStatus: Equatable, Sendable {
        case off, waitingForPlayback, preparing, loadingModel, modelReady, active
        case waitingForAudio, bypassing, unsupportedFormat, sourceError
        case setupFailed(AudioMixFailure)
        case modelUnavailable(DeepFilterProcessor.Status)

        var isActive: Bool { self == .active }

        var isIssue: Bool {
            switch self {
            case .waitingForAudio, .bypassing, .unsupportedFormat, .sourceError, .setupFailed, .modelUnavailable: return true
            default: return false
            }
        }

        var label: String {
            switch self {
            case .off: return "Original sound"
            case .waitingForPlayback: return "Ready for playback"
            case .preparing, .loadingModel, .modelReady: return "Getting ready…"
            case .active: return "Enhancement is on"
            case .waitingForAudio, .bypassing, .sourceError: return "Enhancement paused"
            case .unsupportedFormat: return "Unavailable for this recording"
            case .setupFailed(.playback): return "Playback unavailable"
            case .setupFailed, .modelUnavailable: return "Enhancement unavailable"
            }
        }

        var detail: String {
            switch self {
            case .off: return "Noise reduction and volume boost are off."
            case .waitingForPlayback: return "Your choices will apply when you play a discourse."
            case .preparing, .loadingModel, .modelReady:
                return "Getting noise reduction ready. Volume boost starts once cleanup is working."
            case .active: return "Reducing recording noise. Adjust the controls as you listen."
            case .waitingForAudio, .bypassing, .sourceError:
                return "Noise reduction and volume boost are temporarily paused. Try another mode if this continues."
            case .unsupportedFormat:
                return "This recording can’t use audio enhancement. Noise reduction and volume boost are paused."
            case .setupFailed(.playback): return "Playback could not start. Try playing the discourse again."
            case .setupFailed:
                return "Enhancement couldn’t start. Try playing the discourse again. Volume boost is paused."
            case .modelUnavailable:
                return "This mode couldn’t start. Try another listening mode. Volume boost is paused."
            }
        }

        var outcome: String {
            switch self {
            case .off: return "off"
            case .waitingForPlayback: return "waiting"
            case .preparing: return "preparing"
            case .loadingModel: return "model_loading"
            case .modelReady: return "model_ready"
            case .active: return "processing"
            case .waitingForAudio: return "waiting_for_audio"
            case .bypassing: return "bypassing"
            case .unsupportedFormat: return "unsupported_format"
            case .sourceError: return "source_error"
            case .setupFailed(let failure): return "setup_\(failure.rawValue)"
            case .modelUnavailable: return "model_unavailable"
            }
        }
    }

    var isNoiseReductionEnabled: Bool = false {
        didSet {
            guard oldValue != isNoiseReductionEnabled else { return }
            settings?.noiseReduction = isNoiseReductionEnabled
            // Each replacement tap owns its model and format; its prepare callback activates them.
            noiseProcessor.setDenoiseEnabled(isNoiseReductionEnabled)
            rebuildAudioMix()
        }
    }
    var noiseReductionMode: NoiseReductionMode = .deepFilterNet {
        didSet {
            guard oldValue != noiseReductionMode else { return }
            settings?.noiseReductionMode = noiseReductionMode
            configureNoiseProcessor()
            resetProcessingEvidence()
            refreshAudioProcessingStatus()
        }
    }
    var denoiseStrength: DenoiseStrength = .medium {
        didSet {
            guard oldValue != denoiseStrength else { return }
            settings?.denoiseStrength = denoiseStrength.rawValue
            configureNoiseProcessor()
        }
    }
    /// Which DeepFilterNet voice-forward variant is active. Only affects the
    /// DeepFilterNet mode; RNNoise and Cadence ignore it.
    var voiceFocusPreset: VoiceFocusPreset = .lift {
        didSet {
            guard oldValue != voiceFocusPreset else { return }
            settings?.voiceFocusPreset = voiceFocusPreset
            configureNoiseProcessor()
        }
    }
    private let noiseProcessor: NoiseReductionProcessor

    /// Model readiness is separate from successful processing by the current tap.
    private(set) var deepFilterStatus: DeepFilterProcessor.Status = .idle
    private(set) var isAudioProcessingAttached = false
    private(set) var audioProcessingStatus: AudioProcessingStatus = .off

    /// Whether DeepFilterNet lacks confirmed processing by the current tap.
    var isDeepFilterBypassing: Bool {
        isNoiseReductionEnabled
            && noiseReductionMode == .deepFilterNet
            && !audioProcessingStatus.isActive
    }

    /// Describes current availability, independently of the listener's saved boost level.
    /// The tap also gates gain per buffer, including between status polls.
    var isBoostAvailable: Bool {
        isNoiseReductionEnabled && isAudioProcessingAttached && audioProcessingStatus.isActive
    }

    var noiseReductionAccessibilityValue: String {
        guard isNoiseReductionEnabled else { return "Off" }
        var value = "On, \(noiseReductionMode.displayName), \(denoiseStrength.label) noise reduction"
        if noiseReductionMode == .deepFilterNet {
            value += ", quiet speech \(voiceFocusPreset.displayName)"
        }
        return "\(value). \(audioProcessingStatus.label)"
    }

    // MARK: - Playback State

    weak var playbackStateService: PlaybackStateService?
    weak var downloadService: DownloadService?

    struct OriginalPlaybackActions {
        let autoPlayNext: Bool
        let smartDownload: @MainActor (String) -> Void
        let smartDelete: @MainActor (String) -> Void
        let nextDownloadedItem: @MainActor (String) -> QueueItem?
    }

    /// One uninterrupted stretch of playback, so a Watch report that arrives just
    /// after the phone resumed an older position can still move it forward.
    struct PlaySession: Equatable, Sendable {
        let discourseID: String
        let startedAt: Date
        let startPosition: TimeInterval
        /// The talk's save time before this stretch wrote its own.
        let savedBefore: Date?
    }

    @ObservationIgnored private(set) var playSession: PlaySession?

    // MARK: - Position History (Kindle-style)

    private(set) var previousPosition: TimeInterval?
    var hasPreviousPosition: Bool { previousPosition != nil }

    // MARK: - Private

    private var player: AVPlayer?
    // Queued callbacks can outlive an item, whose object address can be reused.
    private(set) var playbackGeneration: UInt64 = 0
    private var audioMixGeneration: UInt64 = 0
    private var audioMixTask: Task<Void, Never>?
    private var processingMonitor: Task<Void, Never>?
    private var audioMixFailure: AudioMixFailure?
    private var wantsPlayback = false
    private var readyItemID: ObjectIdentifier?
    // Pending original offsets are explicit restorations; ordinary saved resume is read at readiness.
    private var pendingResumePosition: TimeInterval?
    @ObservationIgnored private var previousDiagnostics = NoiseReductionProcessor.Diagnostics()
    @ObservationIgnored private var lastProcessedAt: TimeInterval?
    @ObservationIgnored private var monitoringStartedAt: TimeInterval?
    private let settings: UserSettings?
    private let originalPlaybackActions: OriginalPlaybackActions?
    private let connectsToSystem: Bool
    private let makePlayer: @MainActor () -> AVPlayer
    private let loadAudioTrack: @MainActor (AVPlayerItem) async throws -> AVAssetTrack?
    private let makeAudioMix: @MainActor (NoiseReductionProcessor, AVAssetTrack, UInt64) -> AVAudioMix?
    private static let log = Logger(subsystem: "com.agraabhi.oshodiscourses", category: "AudioProcessing")
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
    private var didManuallySeekNearEnd = false

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

    init(
        settings: UserSettings? = .shared,
        connectsToSystem: Bool = true,
        originalPlaybackActions: OriginalPlaybackActions? = nil,
        noiseProcessor: NoiseReductionProcessor = NoiseReductionProcessor(),
        makePlayer: @escaping @MainActor () -> AVPlayer = { AVPlayer() },
        loadAudioTrack: @escaping @MainActor (AVPlayerItem) async throws -> AVAssetTrack? = {
            try await $0.asset.loadTracks(withMediaType: .audio).first
        },
        makeAudioMix: @escaping @MainActor (NoiseReductionProcessor, AVAssetTrack, UInt64) -> AVAudioMix? = {
            processor, track, generation in processor.createAudioMix(for: track, generation: generation)
        }
    ) {
        self.settings = settings
        self.connectsToSystem = connectsToSystem
        self.originalPlaybackActions = originalPlaybackActions
        self.noiseProcessor = noiseProcessor
        self.makePlayer = makePlayer
        self.loadAudioTrack = loadAudioTrack
        self.makeAudioMix = makeAudioMix
        isNoiseReductionEnabled = settings?.noiseReduction ?? false
        noiseReductionMode = settings?.noiseReductionMode ?? .deepFilterNet
        denoiseStrength = DenoiseStrength(rawValue: settings?.denoiseStrength ?? "") ?? .medium
        voiceFocusPreset = settings?.voiceFocusPreset ?? .lift
        volume = max(1.0, min(Float(settings?.volumeBoost ?? 1), Self.maximumBoost))
        configureNoiseProcessor()
        // Restore the listener's preferred speed; clamp in case a stale/corrupt
        // value was stored outside the supported 0.5–2.0 range.
        playbackRate = max(0.5, min(Float(settings?.defaultPlaybackRate ?? 1), 2.0))
        refreshAudioProcessingStatus()
        if connectsToSystem {
            setupAudioSession()
            setupRemoteCommands()
        }
    }

    /// Cleanup is handled by `stop()`. Since AudioPlayerService is MainActor-isolated,
    /// we cannot safely access isolated properties from deinit in Swift 6.
    /// The AVPlayer will be deallocated with the service, which stops playback.

    // MARK: - Public API

    func play(localURL: URL, id: String, title: String, series: String) {
        let item = QueueItem(id: id, url: localURL, title: title, series: series)
        guard loadAndPlay(item: item) else { return }
        queue = [item]
        currentIndex = 0
    }

    /// `resumeAt` overrides the saved position of the starting item, e.g. for a bookmark.
    func playQueue(items: [QueueItem], startIndex: Int = 0, resumeAt position: TimeInterval? = nil) {
        guard !items.isEmpty else { return }
        let index = max(0, min(startIndex, items.count - 1))
        guard loadAndPlay(item: items[index], resumeAt: position) else { return }
        queue = items
        currentIndex = index
    }

    func togglePlayPause() {
        if isPlaying {
            pausePlayback()
        } else {
            resumePlayback()
        }
    }

    /// For remote controls: a repeated or late request leaves playback in the
    /// requested state instead of toggling it back.
    func setPlaying(_ playing: Bool) {
        if playing {
            if !isPlaying { resumePlayback() }
        } else if isPlaying || wantsPlayback {
            pausePlayback()
        }
    }

    func resumePlayback() {
        guard currentTrackId != nil, queue.indices.contains(currentIndex) else { return }
        if isPlaying, player?.timeControlStatus == .playing { return }
        wantsPlayback = true
        guard let player, player.status != .failed, player.currentItem?.status != .failed else {
            // An item that failed before its first frame has no position of its own;
            // nil lets the saved position win instead of restarting at 0.
            let position = pendingResumePosition ?? (currentTime > 0 ? currentTime : nil)
            if self.player?.status == .failed {
                detachCurrentItem()
                self.player = nil
            }
            loadAndPlay(item: queue[currentIndex], resumeAt: position)
            return
        }
        guard player.currentItem?.status == .readyToPlay else { return }
        guard activateSession() else {
            isPlaying = false
            audioMixFailure = .playback
            refreshAudioProcessingStatus()
            return
        }
        if audioMixFailure == .playback {
            audioMixFailure = nil
            if isNoiseReductionEnabled, !isAudioProcessingAttached, let item = player.currentItem {
                applyAudioMix(to: item)
            }
        }
        // A pending seek can defer play(); its default must carry the requested speed.
        player.defaultRate = playbackRate
        player.play()
        if let id = currentTrackId, !isPlaying || playSession?.discourseID != id {
            playSession = PlaySession(
                discourseID: id, startedAt: Date(), startPosition: currentTime,
                savedBefore: playbackStateService?.lastSaved(discourseId: id)
            )
        }
        isPlaying = true
        refreshAudioProcessingStatus()
        updateNowPlayingInfo()
    }

    private func pausePlayback() {
        wantsPlayback = false
        player?.pause()
        isPlaying = false
        // A Watch copy resumes from here; autosave alone would lag by up to 10 s.
        if let id = currentTrackId, currentTime.isFinite, currentTime > 0 {
            playbackStateService?.savePosition(discourseId: id, position: currentTime, duration: duration)
        }
        resetProcessingEvidence()
        refreshAudioProcessingStatus()
        updateNowPlayingInfo()
    }

    func seek(to time: TimeInterval) {
        let target = time
        guard let player else {
            // No player after a media-services reset: the next resume reloads at currentTime.
            if currentTrackId != nil, target.isFinite { currentTime = max(0, target) }
            return
        }
        // Readiness seeks to the restore position, which would undo a seek made while
        // loading (a bookmark from CarPlay or the Watch); make this the restore position.
        if currentTrackId != nil, target.isFinite,
           let item = player.currentItem, readyItemID != ObjectIdentifier(item), item.status != .failed {
            pendingResumePosition = max(0, target)
            currentTime = max(0, target)
            return
        }
        currentTime = target
        // Record where we're headed so skips accumulate from the target (not the
        // stale player clock) and the periodic observer doesn't snap us back
        // while the seek is in flight.
        pendingSeekTarget = target
        pendingSeekIssuedAt = Date()
        seekGeneration += 1
        let generation = seekGeneration
        let cmTime = CMTime(seconds: target, preferredTimescale: 600)
        let itemID = player.currentItem.map(ObjectIdentifier.init)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      generation == self.seekGeneration,
                      itemID == (self.player?.currentItem).map(ObjectIdentifier.init) else { return }
                // Only the most recent seek clears the pending target — a burst
                // of taps issues several seeks, and a stale completion must not
                // release the guard before the final one lands.
                self.pendingSeekTarget = nil
                self.pendingSeekIssuedAt = nil
                self.updateNowPlayingInfo()
            }
        }
    }

    func seekWithHistory(to time: TimeInterval) {
        if Self.isNearEndSeek(target: time, duration: duration) {
            didManuallySeekNearEnd = true
        }
        guard abs(currentTime - time) > 10 else {
            seek(to: time)
            return
        }
        previousPosition = currentTime
        seek(to: time)
    }

    nonisolated static func isNearEndSeek(target: TimeInterval, duration: TimeInterval) -> Bool {
        duration > 0 && target >= duration - 5
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
        if let pendingResumePosition { return pendingResumePosition }
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
            finishCurrentTrack(naturally: false)
        case .seek(let target):
            seek(to: target)
        }
    }

    func skipBackward(_ seconds: TimeInterval = 15) {
        seek(to: Self.skipBackwardTarget(anchor: skipAnchor, seconds: seconds))
    }

    func skipToNext() {
        guard hasNext else { return }
        guard loadAndPlay(item: queue[currentIndex + 1]) else { return }
        currentIndex += 1
    }

    /// Jump directly to a queue entry (from the Up Next list). No-op if the index
    /// is out of range or already playing.
    func playQueueItem(at index: Int) {
        guard queue.indices.contains(index), index != currentIndex else { return }
        guard loadAndPlay(item: queue[index]) else { return }
        currentIndex = index
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
        guard loadAndPlay(item: queue[currentIndex - 1]) else { return }
        currentIndex -= 1
    }

    private func finishCurrentTrack(naturally: Bool) {
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
        let endSleepArmed = connectsToSystem && SleepTimerService.shared.mode == .endOfDiscourse
        let autoNext = (originalPlaybackActions?.autoPlayNext ?? (settings?.autoPlayNext == true)) && !endSleepArmed
        var playbackContinues = false

        // Auto-play is download-only. Prefer the queue's next item; if the queue
        // is exhausted — a single-item queue (e.g. started from a bookmark), or
        // the next talk only finished downloading after playback began — fall
        // back to the next *downloaded* discourse in the same series so a
        // fully-downloaded series plays straight through regardless of how
        // playback started. This never advances to a discourse not on disk.
        if autoNext {
            // The finished talk's position was just cleared; zero keeps the next
            // load from saving its end position back as progress.
            currentTime = 0
        }
        if autoNext, hasNext {
            playbackContinues = true
            skipToNext()
        } else if autoNext,
                  let completedTrackId,
                  let next = nextDownloadedItem(after: completedTrackId) {
            playbackContinues = true
            queue.append(next)
            currentIndex = queue.count - 1
            loadAndPlay(item: next)
        } else {
            isPlaying = false
            wantsPlayback = false
            // Only snap to the end when we actually know it; duration is 0 until
            // the item is ready, and blanking to 0:00 would misreport a finish.
            if duration > 0 { currentTime = duration }
            updateNowPlayingInfo()
            currentTrackId = nil
            currentTitle = ""
            currentSeries = ""
            detachCurrentItem()
            refreshAudioProcessingStatus()
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
        if connectsToSystem { SleepTimerService.shared.discourseDidFinish() }

        // Ask only after natural completion when playback has actually stopped.
        // Skip-to-end and auto-advance are active listening moments, not pauses in
        // which a system dialog should interrupt the listener.
        if connectsToSystem, ReviewRequestService.isGoodMoment(
            completionWasNatural: naturally,
            playbackContinues: playbackContinues,
            sleepTimerWasArmed: endSleepArmed
        ) {
            ReviewRequestService.requestReviewIfAppropriate()
        }
    }

    private func markCurrentAsCompleted() {
        guard let trackId = currentTrackId else { return }
        playbackStateService?.markListenedComplete(discourseId: trackId)
        playbackStateService?.clearPosition(discourseId: trackId)
    }

    // MARK: - Smart Download / Smart Delete

    private func performSmartDelete(completedDiscourseId: String) {
        if let action = originalPlaybackActions?.smartDelete {
            action(completedDiscourseId)
            return
        }
        guard settings?.smartDelete == true else { return }
        guard let downloadService, downloadService.isDownloaded(completedDiscourseId) else { return }
        try? downloadService.deleteDownload(discourseID: completedDiscourseId)
    }

    private func performSmartDownload(afterDiscourseId: String) {
        if let action = originalPlaybackActions?.smartDownload {
            action(afterDiscourseId)
            return
        }
        guard settings?.smartDownload == true else { return }
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
        if let action = originalPlaybackActions?.nextDownloadedItem { return action(discourseId) }
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
        settings?.defaultPlaybackRate = Double(clamped)
        player?.defaultRate = clamped
        if isPlaying {
            player?.rate = clamped
        }
        updateNowPlayingInfo()
    }

    /// Highest boost offered. Above unity the peaks are limited rather than
    /// clipped, which is what lets this go past the 2x a plain multiply allowed.
    static let maximumBoost: Float = 4.0

    func setVolume(_ vol: Float) {
        let clamped = max(0.0, min(vol, Self.maximumBoost))
        volume = clamped
        settings?.volumeBoost = Double(clamped)
        // Attenuation below unity is the player's job; gain above it is the tap's.
        player?.volume = min(clamped, 1.0)
        // Gain updates preserve the current tap and its streaming history.
        noiseProcessor.setOutputGain(clamped > 1.0 ? clamped : 1.0)
    }

    func stop() {
        wantsPlayback = false
        detachCurrentItem()
        isPlaying = false
        currentTime = 0
        duration = 0
        currentTrackId = nil
        currentTitle = ""
        currentSeries = ""
        pendingSeekTarget = nil
        pendingSeekIssuedAt = nil
        didManuallySeekNearEnd = false
        player?.replaceCurrentItem(with: nil)
        player = nil
        refreshAudioProcessingStatus()
        if connectsToSystem { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil }
    }

    // MARK: - Private: Playback

    @discardableResult
    private func loadAndPlay(item: QueueItem, resumeAt position: TimeInterval? = nil) -> Bool {
        // Outgoing identity belongs to the loaded item, even if a caller has replaced its queue.
        if let outgoingId = currentTrackId, currentTime > 0 {
            playbackStateService?.savePosition(discourseId: outgoingId, position: currentTime, duration: duration)
        }
        detachCurrentItem()

        currentTrackId = item.id
        currentTitle = item.title
        currentSeries = item.series
        currentTime = 0
        duration = 0
        // Drop any in-flight seek from the outgoing track so it can't block the
        // new track's time observer.
        pendingSeekTarget = nil
        pendingSeekIssuedAt = nil
        didManuallySeekNearEnd = false
        didTriggerPreemptiveDownload = false
        pendingResumePosition = position
        wantsPlayback = true
        isPlaying = false

        let playerItem = AVPlayerItem(url: item.url)
        let observedItemID = ObjectIdentifier(playerItem)
        let generation = playbackGeneration
        statusObservation = playerItem.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.handleItemStatusChange(for: observedItemID, generation: generation)
            }
        }

        if player == nil {
            player = makePlayer()
        }
        player?.defaultRate = playbackRate
        player?.replaceCurrentItem(with: playerItem)

        player?.volume = min(volume, 1.0)
        configureNoiseProcessor()
        applyAudioMix(to: playerItem)
        return true
    }

    func handleItemStatusChange(for itemID: ObjectIdentifier, generation: UInt64) {
        guard generation == playbackGeneration,
              let item = player?.currentItem,
              ObjectIdentifier(item) == itemID,
              let trackID = currentTrackId else { return }
        if item.status == .failed {
            pausePlayback()
            removeAudioMix()
            audioMixFailure = .playback
            refreshAudioProcessingStatus()
            return
        }
        guard item.status == .readyToPlay, readyItemID != itemID else { return }
        readyItemID = itemID
        duration = item.duration.seconds.isFinite ? item.duration.seconds : 0
        let restoresExplicitPosition = pendingResumePosition != nil
        let saved = pendingResumePosition ?? playbackStateService?.getPosition(discourseId: trackID)
        pendingResumePosition = nil
        if restoresExplicitPosition, let saved, saved.isFinite, duration > 0 {
            // Exactly the end would finish at once: completion, Smart Delete, auto-advance.
            let position = max(0, min(saved, duration - 1))
            seek(to: position)
            Self.log.info("outcome=original_position_restored clamped=\(position != saved)")
        } else if let saved, saved.isFinite, saved > 0, saved < duration - 5 {
            seek(to: saved)
        }
        setupTimeObserver()
        observePlayerEnd()
        if wantsPlayback {
            resumePlayback()
            if isPlaying {
                playbackStateService?.recordPlay(discourseId: trackID)
            }
        }
    }

    private func detachCurrentItem() {
        playbackGeneration &+= 1
        player?.pause()
        removeTimeObserver()
        removeEndObserver()
        statusObservation?.invalidate()
        statusObservation = nil
        removeAudioMix()
        readyItemID = nil
        pendingResumePosition = nil
        pendingSeekTarget = nil
        pendingSeekIssuedAt = nil
        seekGeneration &+= 1
        deepFilterStatus = .idle
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
            Self.log.error("outcome=audio_session_configuration_failed")
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
        guard connectsToSystem else { return true }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            return true
        } catch {
            Self.log.error("outcome=audio_session_unavailable")
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
            wantsPlayback = false
            isPlaying = false
            resetProcessingEvidence()
            refreshAudioProcessingStatus()
            updateNowPlayingInfo()

        case .ended:
            // Reactivate the session no matter what, so the controls come back even
            // if we don't auto-resume. Then resume only if iOS grants .shouldResume
            // AND we were playing before.
            activateSession()
            let options = optionValue.map { AVAudioSession.InterruptionOptions(rawValue: $0) } ?? []
            if Self.shouldResumeAfterInterruption(wasPlaying: wasPlayingBeforeInterruption, options: options) {
                resumePlayback()
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
    func handleMediaServicesReset() {
        let resume = isPlaying || (wantsPlayback && pendingResumePosition != nil)
        let position = pendingResumePosition ?? (currentTime > 0 ? currentTime : nil)
        if let position { currentTime = position }
        detachCurrentItem()
        player = nil
        isPlaying = false
        wantsPlayback = false
        if connectsToSystem {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .spokenAudio, options: [])
            try? session.setPreferredSampleRate(48000)
        }
        Self.log.info("outcome=media_services_reset")
        if resume, currentTrackId != nil, queue.indices.contains(currentIndex) {
            loadAndPlay(item: queue[currentIndex], resumeAt: position)
        }
        refreshAudioProcessingStatus()
        updateNowPlayingInfo()
    }

    private func handleRouteChange(reasonValue: UInt?) {
        guard let reasonValue,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        switch reason {
        case .oldDeviceUnavailable:
            // Headphones/AirPods were unplugged. Apple's convention: pause rather
            // than blast audio out of the speaker.
            if isPlaying {
                pausePlayback()
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
                self?.resumePlayback()
            }
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard self != nil else { return .commandFailed }
            Task { @MainActor [weak self] in
                self?.pausePlayback()
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
                self?.seekWithHistory(to: position)
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

        // CarPlay's speed button and Siri use this; setRate clamps to 0.5–2.0.
        let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
        commandCenter.changePlaybackRateCommand.supportedPlaybackRates = rates.map { NSNumber(value: $0) }
        commandCenter.changePlaybackRateCommand.addTarget { [weak self] event in
            guard self != nil, let event = event as? MPChangePlaybackRateCommandEvent else {
                return .commandFailed
            }
            let rate = event.playbackRate
            Task { @MainActor [weak self] in
                self?.setRate(rate)
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
        guard connectsToSystem else { return }
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.nextTrackCommand.isEnabled = hasNext
        // Previous restarts the current discourse when nothing precedes it.
        commandCenter.previousTrackCommand.isEnabled = currentTrackId != nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = makeNowPlayingInfo()
    }

    func makeNowPlayingInfo() -> [String: Any] {
        var info = [String: Any]()
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPMediaItemPropertyTitle] = currentTitle
        info[MPMediaItemPropertyArtist] = "Osho"
        info[MPMediaItemPropertyAlbumTitle] = currentSeries
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = playbackRate
        if queue.indices.contains(currentIndex) {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = currentIndex
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = queue.count
        }
        if let artwork = nowPlayingArtwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        return info
    }

    // MARK: - Private: Time Observer

    private var didTriggerPreemptiveDownload = false

    private func setupTimeObserver() {
        removeTimeObserver()
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        let itemID = (player?.currentItem).map(ObjectIdentifier.init)
        let generation = playbackGeneration
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying,
                      generation == self.playbackGeneration,
                      itemID == (self.player?.currentItem).map(ObjectIdentifier.init) else { return }
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
                // A callback can be queued across a seek; sample the live clock after the hop.
                let seconds = self.player?.currentTime().seconds ?? .nan
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
        let generation = playbackGeneration
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player?.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      generation == self.playbackGeneration,
                      let observedItemID,
                      (self.player?.currentItem).map(ObjectIdentifier.init) == observedItemID else { return }
                self.finishCurrentTrack(naturally: !self.didManuallySeekNearEnd)
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
        removeAudioMix()
        guard isNoiseReductionEnabled else {
            refreshAudioProcessingStatus()
            return
        }
        noiseProcessor.setDenoiseEnabled(true)
        let generation = audioMixGeneration
        let itemID = ObjectIdentifier(item)
        setProcessingStatus(.preparing)
        startProcessingMonitor(generation: generation, itemID: itemID)
        let loadTrack = loadAudioTrack
        audioMixTask = Task { [weak self] in
            do {
                let track = try await loadTrack(item)
                guard let self, !Task.isCancelled,
                      self.isCurrentAudioMix(generation: generation, itemID: itemID) else { return }
                defer { self.audioMixTask = nil }
                guard let track else {
                    self.audioMixFailure = .noAudioTrack
                    self.refreshAudioProcessingStatus()
                    return
                }
                guard let mix = self.makeAudioMix(self.noiseProcessor, track, generation) else {
                    self.audioMixFailure = .tapCreation
                    self.refreshAudioProcessingStatus()
                    return
                }
                self.resetProcessingEvidence()
                item.audioMix = mix
                self.isAudioProcessingAttached = true
                self.refreshAudioProcessingStatus()
            } catch {
                guard let self, !Task.isCancelled,
                      self.isCurrentAudioMix(generation: generation, itemID: itemID) else { return }
                self.audioMixTask = nil
                self.audioMixFailure = .trackLoading
                self.refreshAudioProcessingStatus()
            }
        }
    }

    private func rebuildAudioMix() {
        if let item = player?.currentItem, isNoiseReductionEnabled {
            applyAudioMix(to: item)
        } else {
            removeAudioMix()
            refreshAudioProcessingStatus()
        }
    }

    private func removeAudioMix() {
        noiseProcessor.retireAudioMix(generation: audioMixGeneration)
        audioMixGeneration &+= 1
        audioMixTask?.cancel()
        audioMixTask = nil
        processingMonitor?.cancel()
        processingMonitor = nil
        player?.currentItem?.audioMix = nil
        isAudioProcessingAttached = false
        audioMixFailure = nil
        deepFilterStatus = .idle
        resetProcessingEvidence()
    }

    private func isCurrentAudioMix(generation: UInt64, itemID: ObjectIdentifier) -> Bool {
        isNoiseReductionEnabled && currentTrackId != nil
            && generation == audioMixGeneration
            && (player?.currentItem).map(ObjectIdentifier.init) == itemID
    }

    private func startProcessingMonitor(generation: UInt64, itemID: ObjectIdentifier) {
        processingMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) }
                catch { return }
                guard let self,
                      self.isCurrentAudioMix(generation: generation, itemID: itemID) else { return }
                self.refreshAudioProcessingStatus()
            }
        }
    }

    private func resetProcessingEvidence() {
        let snapshot = noiseProcessor.diagnosticsSnapshot()
        previousDiagnostics = snapshot.tapGeneration == audioMixGeneration ? snapshot : .init()
        lastProcessedAt = nil
        monitoringStartedAt = nil
    }

    /// Model readiness alone does not prove audio processing. Sample recent
    /// buffer outcomes on the control thread after mix attachment.
    func refreshAudioProcessingStatus() {
        guard isNoiseReductionEnabled else {
            deepFilterStatus = .idle
            setProcessingStatus(.off)
            return
        }
        guard currentTrackId != nil, let player else {
            deepFilterStatus = .idle
            setProcessingStatus(.waitingForPlayback)
            return
        }
        if let failure = audioMixFailure {
            deepFilterStatus = .idle
            setProcessingStatus(.setupFailed(failure))
            return
        }
        guard isAudioProcessingAttached else {
            deepFilterStatus = .idle
            setProcessingStatus(.preparing)
            return
        }

        let snapshot = noiseProcessor.diagnosticsSnapshot()
        guard snapshot.tapGeneration == audioMixGeneration else {
            previousDiagnostics = .init()
            lastProcessedAt = nil
            monitoringStartedAt = nil
            deepFilterStatus = .idle
            setProcessingStatus(.preparing)
            return
        }
        if previousDiagnostics.tapGeneration != snapshot.tapGeneration {
            previousDiagnostics = .init()
            previousDiagnostics.tapGeneration = snapshot.tapGeneration
            lastProcessedAt = nil
            monitoringStartedAt = nil
        }
        let processed = snapshot.processedBuffers &- previousDiagnostics.processedBuffers
        let invalid = snapshot.invalidBuffers &- previousDiagnostics.invalidBuffers
        let bypassed = snapshot.modelBypassedBuffers &- previousDiagnostics.modelBypassedBuffers
            &+ snapshot.disabledBuffers &- previousDiagnostics.disabledBuffers
            &+ snapshot.lockContendedBuffers &- previousDiagnostics.lockContendedBuffers
        previousDiagnostics = snapshot
        deepFilterStatus = noiseReductionMode == .deepFilterNet ? snapshot.deepFilterStatus : .idle

        if snapshot.sourceReadFailed {
            lastProcessedAt = nil
            setProcessingStatus(.sourceError)
            return
        }
        if invalid > 0 || snapshot.deepFilterStatus == .unsupportedAudioFormat {
            lastProcessedAt = nil
            setProcessingStatus(.unsupportedFormat)
            return
        }
        if case .unsupportedSampleRate = snapshot.deepFilterStatus {
            lastProcessedAt = nil
            setProcessingStatus(.unsupportedFormat)
            return
        }
        guard snapshot.isPrepared else {
            lastProcessedAt = nil
            monitoringStartedAt = nil
            setProcessingStatus(.preparing)
            return
        }
        if noiseReductionMode == .deepFilterNet {
            switch deepFilterStatus {
            case .loading:
                lastProcessedAt = nil
                setProcessingStatus(.loadingModel)
                return
            case .idle:
                lastProcessedAt = nil
                setProcessingStatus(.preparing)
                return
            case .active:
                break
            default:
                lastProcessedAt = nil
                setProcessingStatus(.modelUnavailable(deepFilterStatus))
                return
            }
        }
        guard wantsPlayback, player.timeControlStatus == .playing else {
            lastProcessedAt = nil
            monitoringStartedAt = nil
            setProcessingStatus(.waitingForPlayback)
            return
        }
        if snapshot.resetPending {
            lastProcessedAt = nil
            setProcessingStatus(.preparing)
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        if monitoringStartedAt == nil { monitoringStartedAt = now }
        if processed > 0 {
            lastProcessedAt = now
            setProcessingStatus(.active, processed: processed, bypassed: bypassed)
        } else if bypassed > 0 {
            lastProcessedAt = nil
            setProcessingStatus(.bypassing, processed: processed, bypassed: bypassed)
        } else if let lastProcessedAt, now - lastProcessedAt < 2 {
            setProcessingStatus(.active)
        } else if now - (monitoringStartedAt ?? now) >= 2 {
            setProcessingStatus(.waitingForAudio)
        } else {
            setProcessingStatus(noiseReductionMode == .deepFilterNet ? .modelReady : .preparing)
        }
    }

    private func setProcessingStatus(_ status: AudioProcessingStatus, processed: UInt64 = 0, bypassed: UInt64 = 0) {
        guard audioProcessingStatus != status else { return }
        audioProcessingStatus = status
        let method = noiseReductionMode.rawValue
        let outcome = status.outcome
        if status.isIssue {
            Self.log.error("method=\(method, privacy: .public) outcome=\(outcome, privacy: .public) processed=\(processed) bypassed=\(bypassed)")
        } else {
            Self.log.info("method=\(method, privacy: .public) outcome=\(outcome, privacy: .public) processed=\(processed) bypassed=\(bypassed)")
        }
    }

    private func configureNoiseProcessor() {
        noiseProcessor.configure(
            mode: noiseReductionMode,
            wetMix: denoiseStrength.wetMix,
            intensity: denoiseStrength.intensity,
            attenuationLimitDb: denoiseStrength.attenuationLimitDb,
            voiceFocus: voiceFocusPreset,
            denoiseEnabled: isNoiseReductionEnabled,
            outputGain: volume > 1.0 ? volume : 1.0
        )
    }
}
