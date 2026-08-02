import Foundation
import os

/// DeepFilterNet 3 speech enhancement, running natively through the Rust/tract
/// bridge in `Vendor/DeepFilterBridge.xcframework`.
///
/// The discourse archive is **not** 48 kHz — the Hindi talks are 22,050 Hz
/// 43 kbps MP3s — and DeepFilterNet is a 48 kHz model. So this processor
/// resamples into the model's rate and back out again. Without that the model
/// cannot run at all on most of the catalog, which is exactly why noise
/// reduction previously seemed to do nothing on those recordings.
///
/// Signal path per channel:
///
///     source rate -> upsample 48 kHz -> DeepFilterNet (480-sample hops)
///         -> VoiceFocusChain (duck / lift / emphasis) -> downsample -> source rate
///
/// Two deliberate design decisions:
///
/// 1. **No dry/wet blending.** The model exposes its own strength control —
///    `atten_lim_db`, a cap on how far it may attenuate — which is trained-in
///    and spectrally aware. Crossfading in the untouched signal would instead
///    reintroduce exactly the broadband noise the model just removed, and would
///    require sample-aligning against the model's internal lookahead.
/// 2. **Loading never blocks audio.** Parsing three ONNX graphs out of a
///    compressed archive takes ~230 ms, far too long for the render thread, so
///    it happens on a background queue and audio passes through untouched until
///    the model is installed.
///
/// Failures degrade to passthrough and are reported through `Status` so the UI
/// can tell the listener the truth about whether DeepFilterNet is actually
/// running. Nothing here ever substitutes a different denoiser silently.
final class DeepFilterProcessor: @unchecked Sendable {

    /// The rate DeepFilterNet 3 operates at. Other rates are resampled to it.
    static let modelSampleRate: Double = 48_000
    /// Rates outside this range are refused rather than resampled from
    /// implausible input.
    static let minimumSourceRate: Double = 8_000
    static let maximumSourceRate: Double = 192_000

    enum Status: Sendable, Equatable {
        /// Not requested yet.
        case idle
        /// Model load in flight; audio is passing through meanwhile.
        case loading
        /// Genuinely denoising.
        case active
        /// The model file is not in the app bundle.
        case modelMissing
        /// The bridge refused to load the model (corrupt or unreadable archive).
        case initializationFailed
        /// Source rate is implausible, so resampling was refused.
        case unsupportedSampleRate(Double)
        /// A frame failed mid-playback; audio is passing through.
        case runtimeFailure

        var isActive: Bool { self == .active }

        /// Short label for the player and Settings. Callers must be able to tell
        /// "running" apart from "silently doing nothing".
        var label: String {
            switch self {
            case .idle: return "Off"
            case .loading: return "Loading…"
            case .active: return "Active"
            case .modelMissing: return "Model missing"
            case .initializationFailed: return "Failed to load"
            case .unsupportedSampleRate: return "Unsupported rate"
            case .runtimeFailure: return "Stopped on error"
            }
        }

        /// Whether the listener is currently hearing unprocessed audio despite
        /// having selected DeepFilterNet.
        var isBypassing: Bool {
            switch self {
            case .active, .idle: return false
            default: return true
            }
        }
    }

    // MARK: - Per-channel state

    /// One model instance per audio channel. DeepFilterNet is mono, and the
    /// bridge documents that a handle must not be used concurrently, so channels
    /// never share one.
    private final class Voice {
        let handle: OpaquePointer
        let hopSize: Int
        private(set) var sourceRate: Double = 0
        private(set) var maxFrames: Int = 0

        /// nil when the source is already 48 kHz.
        private var upsampler: PolyphaseResampler?
        private var downsampler: PolyphaseResampler?
        let focus: VoiceFocusChain

        /// 48 kHz samples waiting to fill a model hop.
        private var modelIn: UnsafeMutablePointer<Float>
        private var modelInCount = 0
        private var modelInCapacity = 0
        /// Model output for one hop, at 48 kHz.
        private var frameBuffer: UnsafeMutablePointer<Float>
        /// Scratch for resampler output.
        private var upBuffer: UnsafeMutablePointer<Float>
        private var upCapacity = 0
        private var downBuffer: UnsafeMutablePointer<Float>
        private var downCapacity = 0
        /// Processed audio at source rate, waiting to be emitted.
        private var outBuffer: UnsafeMutablePointer<Float>
        private var outCount = 0
        private var outCapacity = 0
        /// Constant latency held in the output FIFO so every callback can emit
        /// as many samples as it was handed.
        private var primeCount = 0

        init(handle: OpaquePointer, hopSize: Int, parameters: VoiceFocusChain.Parameters) {
            self.handle = handle
            self.hopSize = hopSize
            focus = VoiceFocusChain(
                sampleRate: DeepFilterProcessor.modelSampleRate,
                parameters: parameters
            )
            frameBuffer = .allocate(capacity: hopSize)
            frameBuffer.initialize(repeating: 0, count: hopSize)
            // Real buffers are sized in `reconfigure`; start valid but empty.
            modelIn = .allocate(capacity: 1); modelIn.initialize(repeating: 0, count: 1)
            upBuffer = .allocate(capacity: 1); upBuffer.initialize(repeating: 0, count: 1)
            downBuffer = .allocate(capacity: 1); downBuffer.initialize(repeating: 0, count: 1)
            outBuffer = .allocate(capacity: 1); outBuffer.initialize(repeating: 0, count: 1)
        }

        deinit {
            dfb_destroy(handle)
            modelIn.deallocate()
            frameBuffer.deallocate()
            upBuffer.deallocate()
            downBuffer.deallocate()
            outBuffer.deallocate()
        }

        var isConfigured: Bool { sourceRate > 0 && maxFrames > 0 }

        func matches(sourceRate: Double, maxFrames: Int) -> Bool {
            self.sourceRate == sourceRate && self.maxFrames >= maxFrames
        }

        /// Build (or rebuild) resamplers and FIFOs for a stream format.
        func reconfigure(sourceRate: Double, maxFrames: Int) {
            self.sourceRate = sourceRate
            self.maxFrames = maxFrames
            let modelRate = Int(DeepFilterProcessor.modelSampleRate)
            let source = Int(sourceRate.rounded())

            if source == modelRate {
                upsampler = nil
                downsampler = nil
            } else {
                upsampler = PolyphaseResampler(
                    inputRate: source, outputRate: modelRate, maxInputFrames: maxFrames
                )
                downsampler = PolyphaseResampler(
                    inputRate: modelRate, outputRate: source, maxInputFrames: hopSize
                )
            }

            upCapacity = (upsampler?.maximumOutputCount(forInputCount: maxFrames) ?? maxFrames) + 8
            downCapacity = (downsampler?.maximumOutputCount(forInputCount: hopSize) ?? hopSize) + 8
            modelInCapacity = upCapacity + 2 * hopSize + 16

            // One model hop expressed at the source rate, which is the dominant
            // term in the chain's latency.
            let hopAtSourceRate = Int((Double(hopSize) * sourceRate / DeepFilterProcessor.modelSampleRate).rounded(.up))
            // Two hops plus resampler slack: enough that the FIFO never runs dry
            // between callbacks, without adding audible delay (~46 ms at 22 kHz).
            primeCount = 2 * hopAtSourceRate + 64
            outCapacity = primeCount + 2 * maxFrames + downCapacity + 64

            reallocate(&modelIn, modelInCapacity)
            reallocate(&upBuffer, upCapacity)
            reallocate(&downBuffer, downCapacity)
            reallocate(&outBuffer, outCapacity)
            resetStreamState()
        }

        private func reallocate(_ pointer: inout UnsafeMutablePointer<Float>, _ capacity: Int) {
            pointer.deallocate()
            pointer = .allocate(capacity: max(capacity, 1))
            pointer.initialize(repeating: 0, count: max(capacity, 1))
        }

        /// Clear streaming state for a seek or track change.
        func resetStreamState() {
            modelInCount = 0
            upsampler?.reset()
            downsampler?.reset()
            focus.reset()
            _ = dfb_reset(handle)
            outBuffer.update(repeating: 0, count: min(primeCount, outCapacity))
            outCount = min(primeCount, outCapacity)
        }

        /// Push `count` source-rate samples through the chain. Returns false if a
        /// model frame failed, in which case the caller must bypass.
        func push(samples: UnsafePointer<Float>, count: Int) -> Bool {
            // 1. Into the model's rate.
            var producedUp = 0
            if let upsampler {
                producedUp = upsampler.process(
                    input: samples, count: count, output: upBuffer, outputCapacity: upCapacity
                )
            } else {
                producedUp = min(count, upCapacity)
                upBuffer.update(from: samples, count: producedUp)
            }
            guard modelInCount + producedUp <= modelInCapacity else { return true }
            (modelIn + modelInCount).update(from: upBuffer, count: producedUp)
            modelInCount += producedUp

            // 2. Drain whole hops through the model, focus, and back down.
            var consumed = 0
            var snr: Float = 0
            while modelInCount - consumed >= hopSize {
                let status = dfb_process_frame(
                    handle, modelIn + consumed, frameBuffer, hopSize, &snr
                )
                guard status == DFB_OK else { return false }
                consumed += hopSize

                // The model's own local SNR estimate drives the focus chain; it
                // is what separates speech from noise in time when the two
                // overlap in frequency.
                focus.process(frame: frameBuffer, count: hopSize, localSnrDb: snr)

                var producedDown = 0
                if let downsampler {
                    producedDown = downsampler.process(
                        input: frameBuffer, count: hopSize,
                        output: downBuffer, outputCapacity: downCapacity
                    )
                } else {
                    producedDown = min(hopSize, downCapacity)
                    downBuffer.update(from: frameBuffer, count: producedDown)
                }
                if outCount + producedDown <= outCapacity {
                    (outBuffer + outCount).update(from: downBuffer, count: producedDown)
                    outCount += producedDown
                }
            }
            if consumed > 0 {
                let remaining = modelInCount - consumed
                if remaining > 0 {
                    memmove(modelIn, modelIn + consumed, remaining * MemoryLayout<Float>.size)
                }
                modelInCount = remaining
            }
            return true
        }

        /// Emit `count` processed samples. Returns false if the FIFO is short,
        /// which would mean the priming estimate was wrong.
        func emit(into samples: UnsafeMutablePointer<Float>, count: Int) -> Bool {
            guard outCount >= count else { return false }
            samples.update(from: outBuffer, count: count)
            let leftover = outCount - count
            if leftover > 0 {
                memmove(outBuffer, outBuffer + count, leftover * MemoryLayout<Float>.size)
            }
            outCount = leftover
            return true
        }
    }

    // MARK: - State

    private let lock = NSLock()
    private var voices: [Voice] = []
    private var status: Status = .idle
    private var attenuationLimitDb: Float = 100
    private var parameters: VoiceFocusChain.Parameters = .focus
    private var sourceRate: Double = 0
    private var maxFrames = 0
    private var isLoading = false
    /// Set once a load attempt has completed so a failure is not retried on
    /// every track change. Cleared by `invalidate()`.
    private var hasCompletedLoadAttempt = false
    private var statusObserver: (@Sendable (Status) -> Void)?

    private static let log = Logger(subsystem: "com.agraabhi.oshodiscourses", category: "DeepFilterNet")

    init() {}

    // MARK: - Model file

    /// The bundled DeepFilterNet 3 ONNX export. Checked in both the main bundle
    /// and this class's own bundle so unit tests work whether or not they run
    /// hosted inside the app.
    static func modelURL() -> URL? {
        let candidates = [Bundle.main, Bundle(for: DeepFilterProcessor.self)]
        for bundle in candidates {
            if let url = bundle.url(forResource: "DeepFilterNet3_onnx", withExtension: "tar.gz") {
                return url
            }
            if let url = bundle.url(forResource: "DeepFilterNet3_onnx.tar", withExtension: "gz") {
                return url
            }
        }
        return nil
    }

    // MARK: - Status

    var currentStatus: Status {
        lock.lock()
        defer { lock.unlock() }
        return status
    }

    /// Observe status changes. Set once during setup, before audio starts.
    func observeStatus(_ observer: @escaping @Sendable (Status) -> Void) {
        lock.lock()
        let current = status
        statusObserver = observer
        lock.unlock()
        observer(current)
    }

    /// Must be called with the lock held; the returned observer is notified
    /// outside the lock so it can hop to the main actor safely.
    private func setStatusLocked(_ new: Status) -> (@Sendable (Status) -> Void)? {
        guard status != new else { return nil }
        status = new
        return statusObserver
    }

    private func updateStatus(_ new: Status) {
        lock.lock()
        let observer = setStatusLocked(new)
        let value = status
        lock.unlock()
        observer?(value)
    }

    // MARK: - Configuration

    /// Model strength, as the attenuation limit in dB.
    func setAttenuationLimit(_ db: Float) {
        lock.lock()
        defer { lock.unlock() }
        attenuationLimitDb = db
        for voice in voices {
            _ = dfb_set_atten_lim(voice.handle, db)
        }
    }

    /// Choose which voice-forward variant to apply after the model.
    func setVoiceFocus(_ preset: VoiceFocusPreset) {
        let params = VoiceFocusChain.Parameters.forPreset(preset)
        lock.lock()
        defer { lock.unlock() }
        parameters = params
        for voice in voices {
            voice.focus.update(parameters: params)
        }
    }

    // MARK: - Lifecycle

    /// Prepare for a stream. Loads the model on a background queue the first
    /// time; returns immediately so the caller (a tap prepare callback) never
    /// waits on ONNX parsing.
    func activate(channelCount: Int, maxFrames: Int, sampleRate: Double) {
        guard sampleRate >= Self.minimumSourceRate,
              sampleRate <= Self.maximumSourceRate,
              maxFrames > 0 else {
            Self.log.error("Refusing implausible source rate \(sampleRate, format: .fixed(precision: 0)) Hz")
            updateStatus(.unsupportedSampleRate(sampleRate))
            return
        }

        lock.lock()
        self.sourceRate = sampleRate
        self.maxFrames = maxFrames
        let channels = max(channelCount, 1)
        if !voices.isEmpty {
            // Already loaded: re-fit resamplers/FIFOs to this stream and clear
            // streaming state for the new position.
            for voice in voices {
                if !voice.matches(sourceRate: sampleRate, maxFrames: maxFrames) {
                    voice.reconfigure(sourceRate: sampleRate, maxFrames: maxFrames)
                } else {
                    voice.resetStreamState()
                }
            }
            let missing = channels - voices.count
            let observer = status.isActive ? nil : setStatusLocked(.active)
            let value = status
            lock.unlock()
            observer?(value)
            if missing > 0 {
                loadModel(channelCount: missing, replaceExisting: false)
            }
            return
        }
        if isLoading || hasCompletedLoadAttempt {
            lock.unlock()
            return
        }
        lock.unlock()

        loadModel(channelCount: channels, replaceExisting: true)
    }

    private func loadModel(channelCount: Int, replaceExisting: Bool) {
        guard let modelURL = Self.modelURL() else {
            Self.log.error("DeepFilterNet model is not present in the app bundle")
            lock.lock()
            hasCompletedLoadAttempt = true
            lock.unlock()
            updateStatus(.modelMissing)
            return
        }

        lock.lock()
        isLoading = true
        let attenuation = attenuationLimitDb
        let params = parameters
        let rate = sourceRate
        let frames = maxFrames
        lock.unlock()
        updateStatus(.loading)

        // Build handles off the audio path, then install them under the lock so
        // the render thread only ever sees a fully constructed set.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var built: [Voice] = []
            var failed = false
            let path = modelURL.path

            for _ in 0..<channelCount {
                guard let handle = dfb_create(path, attenuation) else {
                    failed = true
                    break
                }
                let hop = dfb_hop_size(handle)
                let modelRate = dfb_sample_rate(handle)
                guard hop > 0, Double(modelRate) == Self.modelSampleRate else {
                    Self.log.error("Unexpected model geometry: hop \(hop), rate \(modelRate)")
                    dfb_destroy(handle)
                    failed = true
                    break
                }
                let voice = Voice(handle: handle, hopSize: hop, parameters: params)
                voice.reconfigure(sourceRate: rate, maxFrames: frames)
                built.append(voice)
            }

            self.lock.lock()
            self.isLoading = false
            self.hasCompletedLoadAttempt = true
            var observer: (@Sendable (Status) -> Void)?
            if failed || built.isEmpty {
                observer = self.setStatusLocked(.initializationFailed)
            } else {
                if replaceExisting {
                    self.voices = built
                } else {
                    self.voices.append(contentsOf: built)
                }
                observer = self.setStatusLocked(.active)
            }
            let value = self.status
            self.lock.unlock()

            if case .initializationFailed = value {
                Self.log.error("DeepFilterNet failed to initialize from \(path, privacy: .public)")
            } else {
                Self.log.info("DeepFilterNet active on \(channelCount) channel(s) at \(rate, format: .fixed(precision: 0)) Hz")
            }
            observer?(value)
        }
    }

    /// Clear streaming state (after a seek or track change) without unloading.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        for voice in voices where voice.isConfigured {
            voice.resetStreamState()
        }
    }

    /// Drop the model and allow a future load attempt to retry.
    func invalidate() {
        lock.lock()
        voices.removeAll()   // Voice.deinit frees the native handle
        hasCompletedLoadAttempt = false
        let observer = setStatusLocked(.idle)
        let value = status
        lock.unlock()
        observer?(value)
    }

    // MARK: - Realtime processing

    /// Denoise one channel in place.
    ///
    /// Returns false when the caller must leave the audio alone (model still
    /// loading, unavailable, or a frame failed) — the samples are untouched in
    /// that case. Runs on the audio render thread: no allocation, and it never
    /// waits on the lock.
    @discardableResult
    func process(samples: UnsafeMutablePointer<Float>, count: Int, channelIndex: Int) -> Bool {
        guard count > 0 else { return false }
        // Never block the render thread. A load installing handles right now
        // simply means this one callback passes through.
        guard lock.try() else { return false }

        guard status.isActive, channelIndex < voices.count else {
            lock.unlock()
            return false
        }
        let voice = voices[channelIndex]
        guard voice.isConfigured, count <= voice.maxFrames else {
            lock.unlock()
            return false
        }

        guard voice.push(samples: samples, count: count) else {
            // Stop touching audio rather than emitting garbage, and surface it.
            let observer = setStatusLocked(.runtimeFailure)
            let value = status
            lock.unlock()
            Self.log.error("DeepFilterNet frame processing failed; passing audio through")
            observer?(value)
            return false
        }

        guard voice.emit(into: samples, count: count) else {
            // Priming should make this unreachable; pass through rather than
            // inserting a gap.
            lock.unlock()
            return false
        }

        lock.unlock()
        return true
    }
}
