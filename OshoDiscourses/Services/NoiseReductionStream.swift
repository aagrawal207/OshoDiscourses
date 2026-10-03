import AVFoundation
import CoreAudio
import os
import Synchronization

/// Hosts the audio tap and selectable denoising pipelines.
/// Neural processors own their trained-rate buffering and model delay.
final class NoiseReductionStream: @unchecked Sendable {

    struct Diagnostics: Sendable {
        var tapGeneration: UInt64?
        var isPrepared = false
        var preparations: UInt64 = 0
        var deepFilterStatus: DeepFilterProcessor.Status = .idle
        var processedBuffers: UInt64 = 0
        var disabledBuffers: UInt64 = 0
        var unpreparedBuffers: UInt64 = 0
        var invalidBuffers: UInt64 = 0
        var modelBypassedBuffers: UInt64 = 0
        var lockContendedBuffers: UInt64 = 0
        var sourceReadFailures: UInt64 = 0
        var sourceReadFailed = false
        var sourceDiscontinuities: UInt64 = 0
        var sourceTimeRanges: UInt64 = 0
        var sourceTimeDiscontinuities: UInt64 = 0
        var sourceTimeResets: UInt64 = 0
        var invalidSourceTimeRanges: UInt64 = 0
        var lastSourceTimeGapSeconds: Double = 0
        var resetRequests: UInt64 = 0
        var streamResets: UInt64 = 0
        /// Subset of modelBypassedBuffers while a discontinuity reset is pending.
        var resetBypassedBuffers: UInt64 = 0
        var resetPending = false
    }

    private var diagnostics = Diagnostics()
    private let lockContentions = Atomic<UInt64>(0)
    private let unpreparedCallbacks = Atomic<UInt64>(0)
    private let preparationBypasses = Atomic<UInt64>(0)
    private let sourceReadFailures = Atomic<UInt64>(0)
    private let sourceReadFailed = Atomic<Bool>(false)
    private let sourceDiscontinuities = Atomic<UInt64>(0)
    private let requestedReset = Atomic<UInt64>(0)
    private let completedReset = Atomic<UInt64>(0)
    private let maintenance: DispatchSourceUserDataAdd
    private let rnnoiseFactory: (Double, Int, Int) -> RNNoiseProcessor?
    private var hasStreamState = false
    private var retired = false

    /// A control-thread snapshot; the render path only increments fixed counters.
    func diagnosticsSnapshot() -> Diagnostics {
        lock.lock()
        var snapshot = diagnostics
        lock.unlock()
        snapshot.unpreparedBuffers = unpreparedCallbacks.load(ordering: .relaxed)
        snapshot.modelBypassedBuffers &+= preparationBypasses.load(ordering: .relaxed)
        snapshot.deepFilterStatus = deepFilter.currentStatus
        snapshot.lockContendedBuffers = lockContentions.load(ordering: .relaxed)
        snapshot.sourceReadFailures = sourceReadFailures.load(ordering: .relaxed)
        snapshot.sourceReadFailed = sourceReadFailed.load(ordering: .acquiring)
        snapshot.sourceDiscontinuities = sourceDiscontinuities.load(ordering: .relaxed)
        snapshot.resetRequests = requestedReset.load(ordering: .acquiring)
        snapshot.resetPending = snapshot.resetRequests != completedReset.load(ordering: .acquiring)
        return snapshot
    }

    private var mode: NoiseReductionMode = .rnnoise
    private var wetMix: Float = 0.5
    private var intensity: Float = 0.7
    /// DeepFilterNet's strength control: a cap on attenuation in dB.
    private var attenuationLimitDb: Float = 100

    /// DeepFilterNet's separate try-lock prevents model loading or configuration
    /// from blocking a render callback.
    let deepFilter = DeepFilterProcessor()

    /// Shared mixing/deinterleaving scratch, allocated before audio rendering.
    private var monoScratch: UnsafeMutablePointer<Float>?

    /// Output gain above unity, applied after whichever denoiser ran.
    private var outputGain: Float = 1
    /// Whether any processing should happen. Noise Reduction off is guaranteed
    /// to leave the source untouched, including bypassing output boost.
    private var denoiseEnabled = true
    /// One limiter per channel, so a boost raises level instead of clipping.
    private var boostLimiters: [PeakLimiter] = []
    private static let log = Logger(subsystem: "com.agraabhi.oshodiscourses", category: "NoiseReduction")

    private struct Biquad {
        var b0: Float = 1
        var b1: Float = 0
        var b2: Float = 0
        var a1: Float = 0
        var a2: Float = 0
        var z1: Float = 0
        var z2: Float = 0

        mutating func process(_ input: Float) -> Float {
            let output = b0 * input + z1
            z1 = b1 * input - a1 * output + z2
            z2 = b2 * input - a2 * output
            return output
        }

        mutating func reset() {
            z1 = 0
            z2 = 0
        }

        static func notch(frequency: Double, sampleRate: Double, q: Double) -> Self {
            let omega = 2 * Double.pi * frequency / sampleRate
            let alpha = sin(omega) / (2 * q)
            let a0 = 1 + alpha
            return Self(
                b0: Float(1 / a0),
                b1: Float(-2 * cos(omega) / a0),
                b2: Float(1 / a0),
                a1: Float(-2 * cos(omega) / a0),
                a2: Float((1 - alpha) / a0)
            )
        }

        static func highPass(frequency: Double, sampleRate: Double) -> Self {
            let omega = 2 * Double.pi * frequency / sampleRate
            let alpha = sin(omega) / (2 * 0.707)
            let cosOmega = cos(omega)
            let a0 = 1 + alpha
            return Self(
                b0: Float((1 + cosOmega) / 2 / a0),
                b1: Float(-(1 + cosOmega) / a0),
                b2: Float((1 + cosOmega) / 2 / a0),
                a1: Float(-2 * cosOmega / a0),
                a2: Float((1 - alpha) / a0)
            )
        }

        static func lowPass(frequency: Double, sampleRate: Double) -> Self {
            let omega = 2 * Double.pi * frequency / sampleRate
            let alpha = sin(omega) / (2 * 0.707)
            let cosOmega = cos(omega)
            let a0 = 1 + alpha
            return Self(
                b0: Float((1 - cosOmega) / 2 / a0),
                b1: Float((1 - cosOmega) / a0),
                b2: Float((1 - cosOmega) / 2 / a0),
                a1: Float(-2 * cosOmega / a0),
                a2: Float((1 - alpha) / a0)
            )
        }
    }

    private final class Channel {
        var rnnoise: RNNoiseProcessor?
        let scratch: UnsafeMutablePointer<Float>
        var sampleRate: Double = 48_000
        var highPass = Biquad()
        var notch50 = Biquad()
        var notch60 = Biquad()
        var notch100 = Biquad()
        var notch120 = Biquad()
        var hissLowPass = Biquad()
        var envelope: Float = 0
        var quietSamples = 0
        var gateGain: Float = 1

        init(maxFrames: Int) {
            scratch = .allocate(capacity: maxFrames)
            scratch.initialize(repeating: 0, count: maxFrames)
        }

        deinit { scratch.deallocate() }

        func resetArchiveState() {
            highPass.reset()
            notch50.reset()
            notch60.reset()
            notch100.reset()
            notch120.reset()
            hissLowPass.reset()
            envelope = 0
            quietSamples = 0
            gateGain = 1
        }

        func configureArchive(sampleRate: Double, intensity: Float) {
            self.sampleRate = sampleRate
            highPass = .highPass(frequency: 32, sampleRate: sampleRate)
            notch50 = .notch(frequency: 50, sampleRate: sampleRate, q: 35)
            notch60 = .notch(frequency: 60, sampleRate: sampleRate, q: 35)
            notch100 = .notch(frequency: 100, sampleRate: sampleRate, q: 42)
            notch120 = .notch(frequency: 120, sampleRate: sampleRate, q: 42)
            let cutoff = 14_000 - 3_500 * Double(intensity)
            hissLowPass = .lowPass(
                frequency: min(cutoff, sampleRate * 0.45),
                sampleRate: sampleRate
            )
            envelope = 0
            quietSamples = 0
            gateGain = 1
        }
    }

    private var channels: [Channel] = []
    private var maxFrames = 0
    private let lock = NSLock()

    init(tapGeneration: UInt64? = nil, rnnoiseFactory: @escaping (Double, Int, Int) -> RNNoiseProcessor? = { rate, frames, _ in
        RNNoiseProcessor(sourceRate: rate, maxFrames: frames)
    }) {
        self.rnnoiseFactory = rnnoiseFactory
        diagnostics.tapGeneration = tapGeneration
        maintenance = DispatchSource.makeUserDataAddSource(
            queue: DispatchQueue(label: "com.agraabhi.oshodiscourses.dsp-reset", qos: .userInitiated)
        )
        maintenance.setEventHandler { [weak self] in self?.performPendingReset() }
        maintenance.resume()
    }

    deinit {
        maintenance.cancel()
        teardown()
    }

    // MARK: - Lifecycle (called from tap prepare/unprepare)

    func configure(
        mode: NoiseReductionMode,
        wetMix: Float,
        intensity: Float,
        attenuationLimitDb: Float,
        voiceFocus: VoiceFocusPreset,
        denoiseEnabled: Bool = true,
        outputGain: Float = 1
    ) {
        lock.lock()
        guard !retired else { lock.unlock(); return }
        let modeChanged = self.mode != mode
        let enabling = !self.denoiseEnabled && denoiseEnabled
        self.mode = mode
        self.denoiseEnabled = denoiseEnabled
        self.outputGain = max(outputGain, 1)
        self.wetMix = min(max(wetMix, 0), 1)
        self.intensity = min(max(intensity, 0), 1)
        self.attenuationLimitDb = max(attenuationLimitDb, 0)
        for (index, ch) in channels.enumerated() {
            ch.configureArchive(sampleRate: ch.sampleRate, intensity: self.intensity)
            if modeChanged {
                ch.rnnoise?.reset()
                if mode == .rnnoise, ch.rnnoise == nil {
                    ch.rnnoise = rnnoiseFactory(ch.sampleRate, maxFrames, index)
                }
            }
        }
        let format = channels.first.map { ($0.sampleRate, self.maxFrames) }
        // Capture before unlocking: reading these properties afterwards would be
        // an unsynchronized read from whatever thread called configure.
        let attenuation = self.attenuationLimitDb
        lock.unlock()

        // DeepFilterNet keeps its own state, so drive it outside the lock.
        deepFilter.setAttenuationLimit(attenuation)
        deepFilter.setVoiceFocus(voiceFocus)
        if mode == .deepFilterNet, denoiseEnabled, modeChanged || enabling {
            if let (sampleRate, maxFrames) = format, maxFrames > 0 {
                deepFilter.activate(
                    channelCount: 1,
                    maxFrames: maxFrames,
                    sampleRate: sampleRate
                )
            }
        } else if modeChanged {
            // Leaving DeepFilterNet: clear streaming state but keep the loaded
            // model so switching back does not pay the load cost again.
            deepFilter.reset()
        }
    }

    /// Frequent volume updates must not touch the denoisers' configuration or
    /// filter histories.
    func setOutputGain(_ gain: Float) {
        lock.lock()
        guard !retired else { lock.unlock(); return }
        let next = max(gain, 1)
        if outputGain > 1, next <= 1 {
            for index in boostLimiters.indices { boostLimiters[index].reset() }
        }
        outputGain = next
        lock.unlock()
    }

    /// Update the hard passthrough boundary without activating a model against
    /// a stale tap format. A newly installed tap activates from `prepare`.
    func setDenoiseEnabled(_ enabled: Bool) {
        lock.lock()
        guard !retired else { lock.unlock(); return }
        denoiseEnabled = enabled
        lock.unlock()
    }

    /// Allocate per-channel processor state and FIFO buffers sized for this format.
    func prepare(channelCount: Int, maxFrames: Int, sampleRate: Double, isFloat32PCM: Bool = true) {
        lock.lock()
        guard !retired else { lock.unlock(); return }
        diagnostics.preparations &+= 1
        teardownLocked()
        guard isFloat32PCM, channelCount > 0, maxFrames > 0,
              sampleRate >= DeepFilterProcessor.minimumSourceRate,
              sampleRate <= DeepFilterProcessor.maximumSourceRate else {
            self.maxFrames = 0
            lock.unlock()
            deepFilter.rejectAudioFormat()
            Self.log.error("Rejected unsupported audio stream configuration")
            return
        }
        self.maxFrames = maxFrames
        var built: [Channel] = []
        built.reserveCapacity(channelCount)
        for index in 0..<channelCount {
            let ch = Channel(maxFrames: maxFrames)
            ch.configureArchive(sampleRate: sampleRate, intensity: intensity)
            if mode == .rnnoise { ch.rnnoise = rnnoiseFactory(sampleRate, maxFrames, index) }
            built.append(ch)
        }
        channels = built
        diagnostics.isPrepared = true
        monoScratch?.deallocate()
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: max(maxFrames, 1))
        scratch.initialize(repeating: 0, count: max(maxFrames, 1))
        monoScratch = scratch
        boostLimiters = (0..<max(channelCount, 1)).map { _ in
            // Tighter ceiling than the voice chain's: this is the last stage before
            // output, so there is no later resampling to reconstruct peaks above
            // these samples, and 0.7 dB matters when the point is loudness.
            PeakLimiter(sampleRate: sampleRate, ceiling: PeakLimiter.outputCeiling)
        }
        let activeMode = mode
        let denoiseActive = denoiseEnabled
        hasStreamState = false
        completedReset.store(requestedReset.load(ordering: .acquiring), ordering: .releasing)
        lock.unlock()

        Self.log.info("Prepared \(activeMode.rawValue, privacy: .public), \(channelCount) channels at \(sampleRate, format: .fixed(precision: 0)) Hz")

        if activeMode == .deepFilterNet, denoiseActive {
            // One instance, not one per channel: the model is fed a mono mix.
            deepFilter.activate(
                channelCount: 1,
                maxFrames: maxFrames,
                sampleRate: sampleRate
            )
        }
    }

    /// Synchronous control-thread reset. Render callbacks use requestDiscontinuity.
    func reset() {
        lock.lock()
        guard !retired else { lock.unlock(); return }
        resetLocked()
        completedReset.store(requestedReset.load(ordering: .acquiring), ordering: .releasing)
        lock.unlock()
    }

    private func resetLocked() {
        for ch in channels {
            ch.rnnoise?.reset()
            ch.resetArchiveState()
            ch.scratch.update(repeating: 0, count: maxFrames)
        }
        monoScratch?.update(repeating: 0, count: maxFrames)
        for index in boostLimiters.indices { boostLimiters[index].reset() }
        deepFilter.reset()
        hasStreamState = false
        diagnostics.streamResets &+= 1
    }

    /// Requests a clean processing boundary without acquiring processor locks.
    /// Native state is cleared by the pre-created maintenance source.
    func requestDiscontinuity() {
        _ = requestedReset.wrappingAdd(1, ordering: .acquiringAndReleasing)
        maintenance.add(data: 1)
    }

    private func performPendingReset() {
        lock.lock()
        defer { lock.unlock() }
        guard !retired else { return }
        guard requestedReset.load(ordering: .acquiring) != completedReset.load(ordering: .acquiring) else { return }
        if hasStreamState { resetLocked() }
        // No samples can enter while this lock is held, so one reset covers all
        // boundaries that arrived while the worker was clearing model history.
        completedReset.store(requestedReset.load(ordering: .acquiring), ordering: .releasing)
    }

    private func teardown() {
        lock.lock()
        defer { lock.unlock() }
        teardownLocked()
    }

    private func teardownLocked() {
        channels.removeAll()   // Channel.deinit frees C state + buffers
        monoScratch?.deallocate()
        monoScratch = nil
        hasStreamState = false
        diagnostics.isPrepared = false
    }

    func unprepare() {
        lock.lock()
        diagnostics.isPrepared = false
        lock.unlock()
        requestDiscontinuity()
    }

    func retire() {
        lock.lock()
        retired = true
        teardownLocked()
        completedReset.store(requestedReset.load(ordering: .acquiring), ordering: .releasing)
        lock.unlock()
        maintenance.cancel()
        deepFilter.retire()
    }

    func recordSkippedCallback() {
        _ = lockContentions.wrappingAdd(1, ordering: .relaxed)
        requestDiscontinuity()
    }

    // MARK: - Realtime processing

    func process(
        buffer: UnsafeMutablePointer<AudioBufferList>,
        frameCount: UInt32,
        sourceFlags: MTAudioProcessingTapFlags = 0,
        processingAllowed: Bool = true
    ) {
        if sourceFlags & kMTAudioProcessingTapFlag_StartOfStream != 0 {
            _ = sourceDiscontinuities.wrappingAdd(1, ordering: .relaxed)
            _ = requestedReset.wrappingAdd(1, ordering: .acquiringAndReleasing)
        }
        let n = Int(frameCount)
        if !processingAllowed, n > 0 {
            _ = preparationBypasses.wrappingAdd(1, ordering: .relaxed)
            return
        }
        guard n > 0 else {
            if requestedReset.load(ordering: .acquiring) != completedReset.load(ordering: .acquiring) {
                maintenance.add(data: 1)
            }
            return
        }

        // Audio callbacks never wait for preparation or configuration to finish.
        guard lock.try() else {
            _ = lockContentions.wrappingAdd(1, ordering: .relaxed)
            requestDiscontinuity()
            return
        }
        defer { lock.unlock() }
        guard !retired else { return }
        let generation = requestedReset.load(ordering: .acquiring)
        if generation != completedReset.load(ordering: .acquiring) {
            if hasStreamState {
                diagnostics.modelBypassedBuffers &+= 1
                diagnostics.resetBypassedBuffers &+= 1
                maintenance.add(data: 1)
                return
            }
            // prepare (or a completed reset) already cleared everything. The first
            // StartOfStream needs no native work or additional priming interval.
            completedReset.store(generation, ordering: .releasing)
        }
        guard !channels.isEmpty else {
            _ = unpreparedCallbacks.wrappingAdd(1, ordering: .relaxed)
            return
        }
        guard denoiseEnabled else {
            diagnostics.disabledBuffers &+= 1
            return
        }
        guard n <= maxFrames else {
            diagnostics.invalidBuffers &+= 1
            requestDiscontinuity()
            return
        }

        let bufferList = UnsafeMutableAudioBufferListPointer(buffer)
        var totalChannels = 0
        for audioBuffer in bufferList {
            let count = Int(audioBuffer.mNumberChannels)
            guard count > 0, audioBuffer.mData != nil,
                  Int(audioBuffer.mDataByteSize) >= n * count * MemoryLayout<Float>.size else {
                diagnostics.invalidBuffers &+= 1
                requestDiscontinuity()
                return
            }
            totalChannels += count
        }
        guard totalChannels == channels.count else {
            diagnostics.invalidBuffers &+= 1
            requestDiscontinuity()
            return
        }

        // DeepFilterNet works on one mono mix rather than each channel in turn,
        // so it is handled as a whole buffer list instead of channel by channel.
        var processed = true
        if mode == .deepFilterNet {
            processed = processDeepFilterNet(bufferList, count: n)
        } else {
            hasStreamState = true
            var channelIndex = 0
            for bufIdx in 0..<bufferList.count {
                let audioBuffer = bufferList[bufIdx]
                let chans = Int(audioBuffer.mNumberChannels)
                guard let raw = audioBuffer.mData else { continue }
                let samples = raw.assumingMemoryBound(to: Float.self)
                for lane in 0..<chans {
                    let input = channels[channelIndex].scratch
                    for frame in 0..<n { input[frame] = samples[frame * chans + lane] }
                    var handled = true
                    switch mode {
                    case .rnnoise:
                        handled = channels[channelIndex].rnnoise?.process(samples: input, count: n, wetMix: wetMix) == true
                    case .cadence:
                        processCadence(samples: input, count: n, channel: channels[channelIndex])
                    case .deepFilterNet:
                        break
                    }
                    processed = handled && processed
                    channelIndex += 1
                }
            }
        }
        if processed { hasStreamState = true }
        if requestedReset.load(ordering: .acquiring) != generation {
            processed = false
            diagnostics.resetBypassedBuffers &+= 1
        }

        // Commit only a complete, current-generation result. Failure in a later
        // channel or a concurrent boundary must leave every source channel raw.
        if processed {
            if mode == .deepFilterNet {
                let output = monoScratch!
                for audioBuffer in bufferList {
                    let samples = audioBuffer.mData!.assumingMemoryBound(to: Float.self)
                    let chans = Int(audioBuffer.mNumberChannels)
                    for frame in 0..<n {
                        for lane in 0..<chans { samples[frame * chans + lane] = output[frame] }
                    }
                }
            } else {
                var channelIndex = 0
                for audioBuffer in bufferList {
                    let samples = audioBuffer.mData!.assumingMemoryBound(to: Float.self)
                    let chans = Int(audioBuffer.mNumberChannels)
                    for lane in 0..<chans {
                        let output = channels[channelIndex].scratch
                        for frame in 0..<n { samples[frame * chans + lane] = output[frame] }
                        channelIndex += 1
                    }
                }
            }
            diagnostics.processedBuffers &+= 1
            applyOutputBoost(bufferList, count: n)
        } else {
            diagnostics.modelBypassedBuffers &+= 1
            if hasStreamState { requestDiscontinuity() }
        }
    }

    /// Source-read errors return no audio; any source memory from a failed read is
    /// undefined. Recovery starts from cleared processing history.
    func processSourceAudio(
        buffer: UnsafeMutablePointer<AudioBufferList>,
        requestedFrames: CMItemCount,
        returnedFrames: inout CMItemCount,
        flags: inout MTAudioProcessingTapFlags,
        status: OSStatus,
        processingAllowed: Bool = true
    ) {
        guard status == noErr, returnedFrames >= 0, returnedFrames <= requestedFrames,
              returnedFrames <= CMItemCount(UInt32.max) else {
            returnedFrames = 0
            flags = 0
            _ = sourceReadFailures.wrappingAdd(1, ordering: .relaxed)
            sourceReadFailed.store(true, ordering: .releasing)
            requestDiscontinuity()
            return
        }
        sourceReadFailed.store(false, ordering: .releasing)
        process(buffer: buffer, frameCount: UInt32(returnedFrames), sourceFlags: flags, processingAllowed: processingAllowed)
    }

    /// Raises level above the system maximum without clipping.
    ///
    /// `AVAudioMix`'s own volume is not used for this. Its behaviour above 1.0 is
    /// not dependable, and more importantly a plain multiply cannot make this
    /// material louder: the archive already peaks at 0 dBFS, so gain alone only
    /// clips. Limiting the peaks is what turns gain into loudness — the recordings
    /// carry roughly 14 dB of crest factor, and that is the headroom a boost is
    /// actually spending.
    ///
    /// Applied here rather than in `VoiceFocusChain` so it works with every
    /// denoiser. Raw playback deliberately bypasses this stage.
    private func applyOutputBoost(
        _ bufferList: UnsafeMutableAudioBufferListPointer,
        count n: Int
    ) {
        let gain = outputGain
        guard gain > 1.0001 else { return }
        var channelIndex = 0
        for index in 0..<bufferList.count {
            let audioBuffer = bufferList[index]
            guard let raw = audioBuffer.mData else { continue }
            let chans = Int(audioBuffer.mNumberChannels)
            let samples = raw.assumingMemoryBound(to: Float.self)
            for lane in 0..<chans {
                var limiter = boostLimiters[channelIndex]
                for frame in 0..<n {
                    let offset = frame * chans + lane
                    samples[offset] = limiter.process(samples[offset] * gain)
                }
                boostLimiters[channelIndex] = limiter
                channelIndex += 1
            }
        }
    }

    /// Denoise a whole buffer list with DeepFilterNet, collapsing multi-channel
    /// audio to a single mono mix first.
    ///
    /// The archive is spoken word delivered as 22,050 Hz joint stereo: measured on
    /// Maha Geeta #5 the two channels differ by only -18.4 dB, so it is
    /// near-dual-mono in a stereo container. Running the model per channel meant
    /// two model instances and twice the inference — about 0.246 of real time —
    /// to reproduce nearly the same signal twice.
    ///
    /// Collapsing also removes an artifact the per-channel version could produce:
    /// two independent gates ducking at slightly different moments make the stereo
    /// image wander, which is worse than having no width at all on a voice
    /// recording.
    ///
    /// The mix is written back to every channel, so the output stays the shape the
    /// tap handed us.
    private func processDeepFilterNet(
        _ bufferList: UnsafeMutableAudioBufferListPointer,
        count n: Int
    ) -> Bool {
        guard let scratch = monoScratch, n <= maxFrames else { return false }
        scratch.update(repeating: 0, count: n)
        for index in 0..<bufferList.count {
            let audioBuffer = bufferList[index]
            guard let raw = audioBuffer.mData else { continue }
            let chans = Int(audioBuffer.mNumberChannels)
            let samples = raw.assumingMemoryBound(to: Float.self)
            for frame in 0..<n {
                for lane in 0..<chans { scratch[frame] += samples[frame * chans + lane] }
            }
        }
        let scale = 1 / Float(channels.count)
        for frame in 0..<n { scratch[frame] *= scale }

        // A false return means the model is not ready and left the mix alone. The
        // original channels must then be left alone too, rather than replaced with
        // an unprocessed downmix that would collapse the source's own width.
        return deepFilter.process(samples: scratch, count: n, channelIndex: 0)
    }

    private func processCadence(samples: UnsafeMutablePointer<Float>, count: Int, channel ch: Channel) {
        let sampleRate = Float(ch.sampleRate)
        let envelopeAttack = exp(-1 / (0.008 * sampleRate))
        let envelopeRelease = exp(-1 / (0.22 * sampleRate))
        let gateOpen = exp(-1 / (0.006 * sampleRate))
        let gateClose = exp(-1 / (0.35 * sampleRate))
        let quietHold = Int(sampleRate * (0.22 + 0.18 * (1 - intensity)))
        let quietThreshold: Float = 0.009
        let quietGain = 1 - 0.82 * intensity

        for index in 0..<count {
            let dry = samples[index]
            var filtered = ch.highPass.process(dry)
            filtered = ch.notch50.process(filtered)
            filtered = ch.notch60.process(filtered)
            filtered = ch.notch100.process(filtered)
            filtered = ch.notch120.process(filtered)
            filtered = ch.hissLowPass.process(filtered)

            let level = abs(filtered)
            let envelopeCoefficient = level > ch.envelope ? envelopeAttack : envelopeRelease
            ch.envelope = level + envelopeCoefficient * (ch.envelope - level)

            if ch.envelope < quietThreshold {
                ch.quietSamples += 1
            } else {
                ch.quietSamples = 0
            }

            let targetGain: Float = ch.quietSamples >= quietHold ? quietGain : 1
            let gateCoefficient = targetGain > ch.gateGain ? gateOpen : gateClose
            ch.gateGain = targetGain + gateCoefficient * (ch.gateGain - targetGain)

            let processed = filtered * ch.gateGain
            samples[index] = dry + intensity * (processed - dry)
        }
    }

}
