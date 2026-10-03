import Foundation
import os

/// DeepFilterNet 3 at its trained 48 kHz clock, with source-rate conversion.
/// Model parsing is asynchronous; failures are observable, transparent passthrough.
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
        case unsupportedAudioFormat
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
            case .unsupportedAudioFormat: return "Unsupported format"
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
        let focus: VoiceFocusChain
        private var stream: DenoiserStream?
        private let silence: UnsafeMutablePointer<Float>
        private let discardedOutput: UnsafeMutablePointer<Float>

        init(handle: OpaquePointer, hopSize: Int, parameters: VoiceFocusChain.Parameters) {
            self.handle = handle
            self.hopSize = hopSize
            focus = VoiceFocusChain(
                sampleRate: DeepFilterProcessor.modelSampleRate,
                parameters: parameters
            )
            silence = .allocate(capacity: hopSize)
            silence.initialize(repeating: 0, count: hopSize)
            discardedOutput = .allocate(capacity: hopSize)
            discardedOutput.initialize(repeating: 0, count: hopSize)
        }

        deinit {
            dfb_destroy(handle)
            silence.deallocate()
            discardedOutput.deallocate()
        }

        var isConfigured: Bool { stream != nil }
        var maxFrames: Int { stream?.maxFrames ?? 0 }

        func matches(sourceRate: Double, maxFrames: Int) -> Bool {
            stream?.sourceRate == sourceRate && self.maxFrames >= maxFrames
        }

        func reconfigure(sourceRate: Double, maxFrames: Int) {
            stream = DenoiserStream(
                sourceRate: sourceRate, maxFrames: maxFrames, hopSize: hopSize,
                bufferingHops: 2, slackFrames: 64
            )
            resetStreamState()
        }

        /// Clear streaming state for a seek or track change.
        func resetStreamState() {
            stream?.reset()
            focus.reset()
            flushModelState()
        }

        /// Eight silent hops cover the model's five-frame spectral history and
        /// convolution lookahead without rebuilding the model.
        private static let flushHops = 8

        /// Upstream init() appends spectra on each call, so dfb_reset grows latency.
        /// Displace stale spectra with silence; retain the running normalisation.
        private func flushModelState() {
            guard hopSize > 0 else { return }
            var snr: Float = 0
            for _ in 0..<Self.flushHops {
                guard dfb_process_frame(handle, silence, discardedOutput, hopSize, &snr) == DFB_OK else {
                    return
                }
            }
        }

        func process(samples: UnsafeMutablePointer<Float>, count: Int) -> Bool {
            guard let stream else { return false }
            return stream.process(samples: samples, count: count) { input, output in
                var snr: Float = 0
                guard dfb_process_frame(self.handle, input, output, self.hopSize, &snr) == DFB_OK else {
                    return false
                }
                self.focus.process(frame: output, count: self.hopSize, localSnrDb: snr)
                return true
            }
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
    private var requestedChannels = 1
    private var isLoading = false
    private var loadGeneration: UInt64 = 0
    private var retired = false
    /// Set once a load attempt has completed so a failure is not retried on
    /// every track change. Cleared by `invalidate()`.
    private var hasCompletedLoadAttempt = false
    private var statusObserver: (@Sendable (Status) -> Void)?
    private let runtimeNotifications: DispatchSourceUserDataAdd

    private static let log = Logger(subsystem: "com.agraabhi.oshodiscourses", category: "DeepFilterNet")

    init() {
        runtimeNotifications = DispatchSource.makeUserDataAddSource(queue: .global(qos: .utility))
        runtimeNotifications.setEventHandler { [weak self] in self?.publishRuntimeFailure() }
        runtimeNotifications.resume()
    }

    deinit { runtimeNotifications.cancel() }

    private func publishRuntimeFailure() {
        lock.lock()
        guard status == .runtimeFailure else { lock.unlock(); return }
        let observer = statusObserver
        lock.unlock()
        Self.log.error("DeepFilterNet frame processing failed; passing audio through")
        observer?(.runtimeFailure)
    }

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

    // MARK: - Configuration

    /// Upstream blends aligned noisy/enhanced spectra to cap suppression.
    /// Its handle owns that delay; an external source-time dry mix would be wrong.
    func setAttenuationLimit(_ db: Float) {
        guard db.isFinite, db >= 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !retired else { return }
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
        guard !retired else { return }
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
            lock.lock()
            guard !retired else { lock.unlock(); return }
            // Record the latest request even when unsupported. Otherwise an
            // older in-flight load can complete afterwards and publish Active
            // with its stale, valid format.
            sourceRate = sampleRate
            self.maxFrames = maxFrames
            let observer = setStatusLocked(.unsupportedSampleRate(sampleRate))
            let value = status
            lock.unlock()
            observer?(value)
            return
        }

        lock.lock()
        guard !retired else { lock.unlock(); return }
        self.sourceRate = sampleRate
        self.maxFrames = maxFrames
        let channels = max(channelCount, 1)
        requestedChannels = channels
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
            let observer = setStatusLocked(missing > 0 ? .loading : .active)
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
        let modelURL = Self.modelURL()
        lock.lock()
        guard !retired, !isLoading else { lock.unlock(); return }
        guard sourceRate >= Self.minimumSourceRate,
              sourceRate <= Self.maximumSourceRate, maxFrames > 0 else {
            lock.unlock()
            return
        }
        guard let modelURL else {
            hasCompletedLoadAttempt = true
            let observer = setStatusLocked(.modelMissing)
            lock.unlock()
            Self.log.error("DeepFilterNet model is not present in the app bundle")
            observer?(.modelMissing)
            return
        }
        isLoading = true
        loadGeneration &+= 1
        let generation = loadGeneration
        let attenuation = attenuationLimitDb
        let params = parameters
        let rate = sourceRate
        let frames = maxFrames
        let observer = setStatusLocked(.loading)
        lock.unlock()
        observer?(.loading)

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
            guard generation == self.loadGeneration else {
                self.lock.unlock()
                return
            }
            self.isLoading = false
            self.hasCompletedLoadAttempt = true
            // `activate` may have received a newer tap format while ONNX parsing
            // was in flight. Fit the unpublished voices to the latest request,
            // not the format captured when loading began.
            let installedRate = self.sourceRate
            let installedFrames = self.maxFrames
            let installedAttenuation = self.attenuationLimitDb
            let latestFormatIsSupported = installedRate >= Self.minimumSourceRate
                && installedRate <= Self.maximumSourceRate
                && installedFrames > 0
            if !failed {
                for voice in built {
                    // A picker change during ONNX loading must affect the installed
                    // handle as well as the stored preference.
                    if dfb_set_atten_lim(voice.handle, installedAttenuation) != DFB_OK {
                        failed = true
                    }
                    voice.focus.update(parameters: self.parameters)
                    voice.focus.reset()
                    if latestFormatIsSupported,
                       !voice.matches(sourceRate: installedRate, maxFrames: installedFrames) {
                        voice.reconfigure(sourceRate: installedRate, maxFrames: installedFrames)
                    }
                }
            }
            var observer: (@Sendable (Status) -> Void)?
            var missing = 0
            if failed || built.isEmpty {
                observer = self.setStatusLocked(.initializationFailed)
            } else {
                if replaceExisting {
                    self.voices = built
                } else {
                    self.voices.append(contentsOf: built)
                }
                missing = max(0, self.requestedChannels - self.voices.count)
                observer = self.setStatusLocked(
                    latestFormatIsSupported
                        ? (missing == 0 ? .active : .loading)
                        : .unsupportedSampleRate(installedRate)
                )
            }
            let value = self.status
            let installedChannels = self.voices.count
            self.lock.unlock()

            if case .initializationFailed = value {
                Self.log.error("DeepFilterNet failed to initialize from \(path, privacy: .public)")
            } else if value.isActive {
                Self.log.info("DeepFilterNet active on \(installedChannels) channel(s) at \(installedRate, format: .fixed(precision: 0)) Hz, attenuation limit \(installedAttenuation) dB")
            }
            observer?(value)
            if missing > 0, latestFormatIsSupported {
                self.loadModel(channelCount: missing, replaceExisting: false)
            }
        }
    }

    /// Clear streaming state (after a seek or track change) without unloading.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        guard !retired else { return }
        for voice in voices where voice.isConfigured {
            voice.resetStreamState()
        }
    }

    /// Drop the model and allow a future load attempt to retry.
    func invalidate() {
        lock.lock()
        guard !retired else { lock.unlock(); return }
        loadGeneration &+= 1
        isLoading = false
        voices.removeAll()   // Voice.deinit frees the native handle
        hasCompletedLoadAttempt = false
        let observer = setStatusLocked(.idle)
        let value = status
        lock.unlock()
        observer?(value)
    }

    /// Cancel stale preparation when the tap cannot supply native Float32 PCM.
    func rejectAudioFormat() {
        lock.lock()
        guard !retired else { lock.unlock(); return }
        loadGeneration &+= 1
        isLoading = false
        hasCompletedLoadAttempt = false
        sourceRate = 0
        maxFrames = 0
        let observer = setStatusLocked(.unsupportedAudioFormat)
        lock.unlock()
        observer?(.unsupportedAudioFormat)
    }

    /// A retired tap's in-flight preparation must never start another model load.
    func retire() {
        lock.lock()
        retired = true
        loadGeneration &+= 1
        isLoading = false
        voices.removeAll()
        let observer = setStatusLocked(.idle)
        lock.unlock()
        observer?(.idle)
    }

    // MARK: - Realtime processing

    /// Denoises in place; false leaves the caller's buffer untouched.
    /// Swift buffers are preallocated and acquiring the control lock never blocks.
    @discardableResult
    func process(samples: UnsafeMutablePointer<Float>, count: Int, channelIndex: Int) -> Bool {
        guard count > 0 else { return false }
        // Never block the render thread. A load installing handles right now
        // simply means this one callback passes through.
        guard lock.try() else { return false }

        guard status.isActive, channelIndex >= 0, channelIndex < voices.count else {
            lock.unlock()
            return false
        }
        let voice = voices[channelIndex]
        guard voice.isConfigured, count <= voice.maxFrames else {
            lock.unlock()
            return false
        }

        guard voice.process(samples: samples, count: count) else {
            // Status polling sees the failure immediately; callbacks and logging
            // are delivered by a pre-created source off the render thread.
            _ = setStatusLocked(.runtimeFailure)
            lock.unlock()
            runtimeNotifications.add(data: 1)
            return false
        }

        lock.unlock()
        return true
    }
}
