import AVFoundation
import Synchronization

/// A tap never shares mutable DSP state or counters with another generation.
final class NoiseReductionTapContext: @unchecked Sendable {
    let generation: UInt64
    let stream: NoiseReductionStream
    private let callbacks = NSLock()
    private let formatWrites = NSLock()
    private let retired = Atomic<Bool>(false)
    private let prepared = Atomic<Bool>(false)
    private let preparedRevision = Atomic<UInt64>(0)
    private let preparation: DispatchSourceUserDataAdd
    private var sourceTimeline = SourceAudioTimeline()
    private var timelineFormatRevision: UInt64 = 0
    private let sourceTimeRanges = Atomic<UInt64>(0)
    private let sourceTimeDiscontinuities = Atomic<UInt64>(0)
    private let sourceTimeResets = Atomic<UInt64>(0)
    private let invalidSourceTimeRanges = Atomic<UInt64>(0)
    private let lastSourceTimeGap = Atomic<UInt64>(0)

    // A single tap's prepare/unprepare callbacks publish this atomic mailbox.
    // The worker never holds the callback gate while allocating or loading models.
    private let formatRevision = Atomic<UInt64>(0)
    private let wantsPreparation = Atomic<Bool>(false)
    private let formatChannels = Atomic<Int>(0)
    private let formatFrames = Atomic<Int>(0)
    private let formatRate = Atomic<UInt64>(0)
    private let formatIsFloat = Atomic<Bool>(true)

    init(
        generation: UInt64,
        rnnoiseFactory: @escaping (Double, Int, Int) -> RNNoiseProcessor?,
        preparationDeliveryDidFinish: (@Sendable () -> Void)? = nil
    ) {
        self.generation = generation
        stream = NoiseReductionStream(tapGeneration: generation, rnnoiseFactory: rnnoiseFactory)
        preparation = DispatchSource.makeUserDataAddSource(
            queue: DispatchQueue(label: "com.agraabhi.oshodiscourses.tap-prepare", qos: .userInitiated)
        )
        // Keep cleanup alive after the framework releases its last tap reference.
        // Retirement breaks this cycle on the worker after native state is freed.
        preparation.setEventHandler {
            self.applyPreparation()
            preparationDeliveryDidFinish?()
        }
        preparation.resume()
    }

    deinit { preparation.cancel() }

    var isRetired: Bool { retired.load(ordering: .acquiring) }

    private var isPrepared: Bool {
        prepared.load(ordering: .acquiring)
            && preparedRevision.load(ordering: .acquiring) == formatRevision.load(ordering: .acquiring)
            && wantsPreparation.load(ordering: .acquiring) && !isRetired
    }

    func diagnosticsSnapshot() -> NoiseReductionStream.Diagnostics {
        var snapshot = stream.diagnosticsSnapshot()
        snapshot.isPrepared = isPrepared
        snapshot.sourceTimeRanges = sourceTimeRanges.load(ordering: .relaxed)
        snapshot.sourceTimeDiscontinuities = sourceTimeDiscontinuities.load(ordering: .relaxed)
        snapshot.sourceTimeResets = sourceTimeResets.load(ordering: .relaxed)
        snapshot.invalidSourceTimeRanges = invalidSourceTimeRanges.load(ordering: .relaxed)
        snapshot.lastSourceTimeGapSeconds = Double(bitPattern: lastSourceTimeGap.load(ordering: .relaxed))
        if isRetired { snapshot.deepFilterStatus = .idle }
        return snapshot
    }

    func prepare(channelCount: Int, maxFrames: Int, sampleRate: Double, isFloat32PCM: Bool = true) {
        guard formatWrites.try() else { return }
        defer { formatWrites.unlock() }
        guard !isRetired else { return }
        _ = formatRevision.wrappingAdd(1, ordering: .acquiringAndReleasing)
        prepared.store(false, ordering: .releasing)
        formatChannels.store(channelCount, ordering: .relaxed)
        formatFrames.store(maxFrames, ordering: .relaxed)
        formatRate.store(sampleRate.bitPattern, ordering: .relaxed)
        formatIsFloat.store(isFloat32PCM, ordering: .relaxed)
        wantsPreparation.store(true, ordering: .relaxed)
        _ = formatRevision.wrappingAdd(1, ordering: .releasing)
        preparation.add(data: 1)
    }

    func unprepare() {
        guard formatWrites.try() else { return }
        defer { formatWrites.unlock() }
        guard !isRetired else { return }
        _ = formatRevision.wrappingAdd(1, ordering: .acquiringAndReleasing)
        prepared.store(false, ordering: .releasing)
        wantsPreparation.store(false, ordering: .relaxed)
        _ = formatRevision.wrappingAdd(1, ordering: .releasing)
        preparation.add(data: 1)
    }

    /// Control-thread retirement serializes with an already admitted callback.
    /// Cleanup stays on this context's worker, including any in-flight preparation.
    func retire() {
        callbacks.lock()
        retired.store(true, ordering: .releasing)
        prepared.store(false, ordering: .releasing)
        callbacks.unlock()
        preparation.add(data: 1)
    }

    /// Finalize is already ordered after this tap's callbacks by the framework.
    func finalize() {
        retired.store(true, ordering: .releasing)
        prepared.store(false, ordering: .releasing)
        preparation.add(data: 1)
    }

    func requestDiscontinuity() {
        guard !isRetired else { return }
        stream.requestDiscontinuity()
    }

    func processSourceAudio(
        buffer: UnsafeMutablePointer<AudioBufferList>, requestedFrames: CMItemCount,
        returnedFrames: inout CMItemCount, flags: inout MTAudioProcessingTapFlags, status: OSStatus,
        sourceTimeRange: CMTimeRange? = nil
    ) {
        // Even a retired tap must not expose undefined memory from a failed read.
        let validRead = status == noErr && returnedFrames >= 0
            && returnedFrames <= requestedFrames && returnedFrames <= CMItemCount(UInt32.max)
        guard callbacks.try() else {
            if !validRead { returnedFrames = 0; flags = 0 }
            if !isRetired { stream.recordSkippedCallback() }
            return
        }
        defer { callbacks.unlock() }
        guard !isRetired else {
            if !validRead { returnedFrames = 0; flags = 0 }
            return
        }
        let revision = formatRevision.load(ordering: .acquiring)
        if !validRead || revision != timelineFormatRevision || flags & kMTAudioProcessingTapFlag_StartOfStream != 0 {
            sourceTimeline.reset()
            timelineFormatRevision = revision
        }
        if validRead, returnedFrames > 0, let sourceTimeRange {
            let observation = sourceTimeline.consume(
                sourceTimeRange, sampleRate: Double(bitPattern: formatRate.load(ordering: .relaxed))
            )
            if observation.validRange {
                _ = sourceTimeRanges.wrappingAdd(1, ordering: .relaxed)
            } else {
                _ = invalidSourceTimeRanges.wrappingAdd(1, ordering: .relaxed)
            }
            if observation.timedDiscontinuity {
                _ = sourceTimeDiscontinuities.wrappingAdd(1, ordering: .relaxed)
                lastSourceTimeGap.store(observation.gapSeconds.bitPattern, ordering: .relaxed)
            }
            if observation.requiresReset {
                _ = sourceTimeResets.wrappingAdd(1, ordering: .relaxed)
                flags |= kMTAudioProcessingTapFlag_StartOfStream
            }
        }
        stream.processSourceAudio(
            buffer: buffer, requestedFrames: requestedFrames, returnedFrames: &returnedFrames,
            flags: &flags, status: status, processingAllowed: isPrepared
        )
    }

    private func applyPreparation() {
        while true {
            if isRetired {
                stream.retire()
                preparation.setEventHandler(handler: nil)
                preparation.cancel()
                return
            }
            let revision = formatRevision.load(ordering: .acquiring)
            guard revision.isMultiple(of: 2) else { preparation.add(data: 1); return }
            let wanted = wantsPreparation.load(ordering: .relaxed)
            let channels = formatChannels.load(ordering: .relaxed)
            let frames = formatFrames.load(ordering: .relaxed)
            let rate = Double(bitPattern: formatRate.load(ordering: .relaxed))
            let floatPCM = formatIsFloat.load(ordering: .relaxed)
            guard revision == formatRevision.load(ordering: .acquiring) else { continue }
            // Adds received inside a handler can cause another delivery after its
            // loop already applied the latest revision, including failed formats.
            guard revision != preparedRevision.load(ordering: .acquiring) else { return }
            if wanted {
                stream.prepare(channelCount: channels, maxFrames: frames, sampleRate: rate, isFloat32PCM: floatPCM)
            } else {
                stream.unprepare()
            }
            let valid = stream.diagnosticsSnapshot().isPrepared
            guard !isRetired else { continue }
            guard revision == formatRevision.load(ordering: .acquiring) else { continue }
            preparedRevision.store(revision, ordering: .releasing)
            prepared.store(wanted && valid, ordering: .releasing)
            // A concurrent unprepare/retirement must win even at publication.
            if isRetired || revision != formatRevision.load(ordering: .acquiring) {
                prepared.store(false, ordering: .releasing)
                continue
            }
            return
        }
    }
}
