import AVFoundation

/// Control facade; actual taps retain generation-owned streams rather than this
/// mutable current-context selector. Direct harness calls use a separate stream.
final class NoiseReductionProcessor: @unchecked Sendable {
    typealias Diagnostics = NoiseReductionStream.Diagnostics

    private struct Configuration {
        var mode: NoiseReductionMode = .rnnoise
        var wetMix: Float = 0.5
        var intensity: Float = 0.7
        var attenuationLimitDb: Float = 100
        var voiceFocus: VoiceFocusPreset = .focus
        var denoiseEnabled = true
        var outputGain: Float = 1

        func apply(to stream: NoiseReductionStream) {
            stream.configure(mode: mode, wetMix: wetMix, intensity: intensity,
                             attenuationLimitDb: attenuationLimitDb, voiceFocus: voiceFocus,
                             denoiseEnabled: denoiseEnabled, outputGain: outputGain)
        }
    }

    private let control = NSLock()
    private let commands = NSLock()
    private let standalone: NoiseReductionStream
    private let inactiveDeepFilter = DeepFilterProcessor()
    private let rnnoiseFactory: (Double, Int, Int) -> RNNoiseProcessor?
    private var configuration = Configuration()
    private var current: NoiseReductionTapContext?
    private var generationFence: UInt64?
    private var managesTaps = false

    init(rnnoiseFactory: @escaping (Double, Int, Int) -> RNNoiseProcessor? = { rate, frames, _ in
        RNNoiseProcessor(sourceRate: rate, maxFrames: frames)
    }) {
        self.rnnoiseFactory = rnnoiseFactory
        standalone = NoiseReductionStream(rnnoiseFactory: rnnoiseFactory)
    }

    deinit { current?.retire() }

    /// Control-thread access. Prefer the status paired with diagnosticsSnapshot
    /// when comparing generations; retaining this object pins that model only.
    var deepFilter: DeepFilterProcessor {
        control.lock()
        defer { control.unlock() }
        if let current, !current.isRetired { return current.stream.deepFilter }
        return managesTaps ? inactiveDeepFilter : standalone.deepFilter
    }

    func diagnosticsSnapshot() -> Diagnostics {
        control.lock()
        let context = current
        let managed = managesTaps
        control.unlock()
        if let context { return context.diagnosticsSnapshot() }
        return managed ? Diagnostics() : standalone.diagnosticsSnapshot()
    }

    func configure(
        mode: NoiseReductionMode, wetMix: Float, intensity: Float, attenuationLimitDb: Float,
        voiceFocus: VoiceFocusPreset, denoiseEnabled: Bool = true, outputGain: Float = 1
    ) {
        commands.lock()
        defer { commands.unlock() }
        control.lock()
        configuration = Configuration(mode: mode, wetMix: wetMix, intensity: intensity,
                                      attenuationLimitDb: attenuationLimitDb, voiceFocus: voiceFocus,
                                      denoiseEnabled: denoiseEnabled, outputGain: outputGain)
        let value = configuration
        let target = current?.stream ?? (managesTaps ? nil : standalone)
        control.unlock()
        if let target { value.apply(to: target) }
    }

    func setOutputGain(_ gain: Float) {
        commands.lock()
        defer { commands.unlock() }
        control.lock()
        configuration.outputGain = gain
        let target = current?.stream ?? (managesTaps ? nil : standalone)
        control.unlock()
        target?.setOutputGain(gain)
    }

    func setDenoiseEnabled(_ enabled: Bool) {
        commands.lock()
        defer { commands.unlock() }
        control.lock()
        configuration.denoiseEnabled = enabled
        let target = current?.stream ?? (managesTaps ? nil : standalone)
        control.unlock()
        target?.setDenoiseEnabled(enabled)
    }

    /// Generations are strictly increasing and cannot be reused after retirement.
    /// This is also the deterministic lifecycle seam used without an AVPlayer.
    func makeTapContext(generation: UInt64) -> NoiseReductionTapContext? {
        commands.lock()
        defer { commands.unlock() }
        control.lock()
        guard generationFence.map({ generation > $0 }) ?? true else { control.unlock(); return nil }
        let context = NoiseReductionTapContext(generation: generation, rnnoiseFactory: rnnoiseFactory)
        configuration.apply(to: context.stream)
        let previous = current
        generationFence = generation
        managesTaps = true
        current = context
        control.unlock()
        previous?.retire()
        return context
    }

    /// Fences canceled requests even when their tap has not yet been constructed.
    /// A delayed retirement for an older generation cannot detach a newer one.
    func retireAudioMix(generation: UInt64) {
        commands.lock()
        defer { commands.unlock() }
        control.lock()
        if generationFence.map({ generation > $0 }) ?? true { generationFence = generation }
        managesTaps = true
        let previous = current?.generation == generation ? current : nil
        if previous != nil { current = nil }
        control.unlock()
        previous?.retire()
    }

    /// Manual discontinuities must identify their tap, just like cancellation.
    func requestDiscontinuity(generation: UInt64) {
        control.lock()
        let target = current?.generation == generation ? current : nil
        control.unlock()
        target?.requestDiscontinuity()
    }

    func createAudioMix(for track: AVAssetTrack, generation: UInt64) -> AVAudioMix? {
        guard let context = makeTapContext(generation: generation) else { return nil }
        let retained = Unmanaged.passRetained(context)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0, clientInfo: retained.toOpaque(),
            init: tapInit, finalize: tapFinalize, prepare: tapPrepare,
            unprepare: tapUnprepare, process: tapProcess
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let audioTap = tap else {
            retained.release()
            retireAudioMix(generation: generation)
            return nil
        }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = audioTap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }

    func createAudioMix(for track: AVAssetTrack) -> AVAudioMix? {
        control.lock()
        let generation = (generationFence ?? 0) &+ 1
        control.unlock()
        return createAudioMix(for: track, generation: generation)
    }

    // Direct/offline entry points never relabel their counters as a tap's data.
    func prepare(channelCount: Int, maxFrames: Int, sampleRate: Double, isFloat32PCM: Bool = true) {
        standalone.prepare(channelCount: channelCount, maxFrames: maxFrames, sampleRate: sampleRate, isFloat32PCM: isFloat32PCM)
    }

    func process(buffer: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32, sourceFlags: MTAudioProcessingTapFlags = 0) {
        standalone.process(buffer: buffer, frameCount: frameCount, sourceFlags: sourceFlags)
    }

    func processSourceAudio(
        buffer: UnsafeMutablePointer<AudioBufferList>, requestedFrames: CMItemCount,
        returnedFrames: inout CMItemCount, flags: inout MTAudioProcessingTapFlags, status: OSStatus
    ) {
        standalone.processSourceAudio(buffer: buffer, requestedFrames: requestedFrames,
                                      returnedFrames: &returnedFrames, flags: &flags, status: status)
    }

    func reset() { standalone.reset() }
    func requestDiscontinuity() { standalone.requestDiscontinuity() }
}

private func tapInit(tap: MTAudioProcessingTap, clientInfo: UnsafeMutableRawPointer?, tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>) {
    tapStorageOut.pointee = clientInfo
}

private func tapFinalize(tap: MTAudioProcessingTap) {
    let retained = Unmanaged<NoiseReductionTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
    retained.takeUnretainedValue().finalize()
    retained.release()
}

private func tapPrepare(tap: MTAudioProcessingTap, maxFrames: CMItemCount, processingFormat: UnsafePointer<AudioStreamBasicDescription>) {
    let context = Unmanaged<NoiseReductionTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    let format = processingFormat.pointee
    context.prepare(channelCount: Int(format.mChannelsPerFrame), maxFrames: Int(maxFrames), sampleRate: format.mSampleRate,
                    isFloat32PCM: format.mFormatID == kAudioFormatLinearPCM && format.mBitsPerChannel == 32
                        && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
                        && format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0)
}

private func tapUnprepare(tap: MTAudioProcessingTap) {
    Unmanaged<NoiseReductionTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().unprepare()
}

private func tapProcess(tap: MTAudioProcessingTap, numberFrames: CMItemCount, flags: MTAudioProcessingTapFlags, bufferListInOut: UnsafeMutablePointer<AudioBufferList>, numberFramesOut: UnsafeMutablePointer<CMItemCount>, flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>) {
    var sourceTimeRange = CMTimeRange.invalid
    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, &sourceTimeRange, numberFramesOut)
    // Discontinuities must survive either callback or source-read signaling.
    if status == noErr { flagsOut.pointee |= flags & kMTAudioProcessingTapFlag_StartOfStream }
    let context = Unmanaged<NoiseReductionTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    context.processSourceAudio(buffer: bufferListInOut, requestedFrames: numberFrames,
                               returnedFrames: &numberFramesOut.pointee, flags: &flagsOut.pointee, status: status,
                               sourceTimeRange: sourceTimeRange)
}
