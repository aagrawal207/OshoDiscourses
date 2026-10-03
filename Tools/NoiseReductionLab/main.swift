import AVFoundation
import Foundation

enum LabError: Error {
    case argument(String)
    case model(String)
}

@main
struct NoiseReductionLab {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("NoiseReductionLab: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 3 else {
            throw LabError.argument("render INPUT OUTPUT MODE [attenuation=12] [preset=focus] [start=0] [seconds=30] [wet=0.5] [block=1024] [resets=0]")
        }
        let inputURL = URL(fileURLWithPath: args[0])
        let outputURL = URL(fileURLWithPath: args[1])
        let mode = args[2]
        let attenuation = args.count > 3 ? Float(args[3])! : 12
        let preset = args.count > 4 ? VoiceFocusPreset(rawValue: args[4])! : .focus
        let start = args.count > 5 ? Double(args[5])! : 0
        let seconds = args.count > 6 ? Double(args[6])! : 30
        let wet = args.count > 7 ? Float(args[7])! : 0.5
        let blockSize = args.count > 8 ? Int(args[8])! : 1024
        let resets = args.count > 9 ? Int(args[9])! : 0

        let file = try AVAudioFile(forReading: inputURL)
        let format = file.processingFormat
        let rate = format.sampleRate
        let channels = Int(format.channelCount)
        file.framePosition = AVAudioFramePosition(start * rate)
        let frames = min(Int(seconds * rate), Int(file.length - file.framePosition))
        guard frames > 0, blockSize > 0 else { throw LabError.argument("Empty excerpt") }
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        try file.read(into: input, frameCount: AVAudioFrameCount(frames))

        let processor = NoiseReductionProcessor()
        if let selected = NoiseReductionMode(rawValue: mode) {
            processor.configure(mode: selected, wetMix: wet, intensity: 0.7,
                                attenuationLimitDb: attenuation, voiceFocus: preset)
            processor.prepare(channelCount: channels, maxFrames: blockSize, sampleRate: rate)
            if selected == .deepFilterNet {
                let deadline = ContinuousClock.now + .seconds(30)
                while processor.deepFilter.currentStatus != .active {
                    if ContinuousClock.now >= deadline {
                        throw LabError.model(processor.deepFilter.currentStatus.label)
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
        } else if mode != "raw" && mode != "rnnoise-native" {
            throw LabError.argument("Unknown mode \(mode)")
        }

        let out = try AVAudioFile(forWriting: outputURL, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ])
        let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(blockSize))!
        let native = mode == "rnnoise-native" ? rnnoise_create(nil) : nil
        defer { if let native { rnnoise_destroy(native) } }
        var nativeIn = [Float](repeating: 0, count: 480)
        var nativeOut = [Float](repeating: 0, count: 480)
        if mode == "rnnoise-native", blockSize != 480 {
            throw LabError.argument("rnnoise-native requires block=480")
        }

        for _ in 0..<resets {
            block.frameLength = AVAudioFrameCount(blockSize)
            for ch in 0..<channels {
                for i in 0..<blockSize {
                    block.floatChannelData![ch][i] = input.floatChannelData![ch][i % frames]
                }
            }
            processor.process(buffer: block.mutableAudioBufferList, frameCount: block.frameLength)
            processor.reset()
        }
        var offset = 0
        var elapsed = 0.0
        var peak: Float = 0
        var overFullScale = 0
        var blocks = 0
        var maxBlockSeconds = 0.0
        var durations: [Double] = []
        let paddedFrames = frames + Int(rate * 0.5)
        while offset < paddedFrames {
            let n = min(blockSize, paddedFrames - offset)
            block.frameLength = AVAudioFrameCount(n)
            for ch in 0..<channels {
                for i in 0..<n {
                    block.floatChannelData![ch][i] = offset + i < frames ? input.floatChannelData![ch][offset + i] : 0
                }
            }
            let begin = ProcessInfo.processInfo.systemUptime
            if let native {
                for i in 0..<480 { nativeIn[i] = i < n ? block.floatChannelData![0][i] * 32768 : 0 }
                _ = rnnoise_process_frame(native, &nativeOut, &nativeIn)
                for ch in 0..<channels {
                    for i in 0..<n { block.floatChannelData![ch][i] = nativeOut[i] / 32768 }
                }
            } else if mode != "raw" {
                processor.process(buffer: block.mutableAudioBufferList, frameCount: block.frameLength)
            }
            let dt = ProcessInfo.processInfo.systemUptime - begin
            elapsed += dt
            durations.append(dt)
            maxBlockSeconds = max(maxBlockSeconds, dt)
            blocks += 1
            for ch in 0..<channels {
                for i in 0..<n {
                    let sample = abs(block.floatChannelData![ch][i])
                    guard sample.isFinite else { throw LabError.model("Non-finite output") }
                    peak = max(peak, sample)
                    if sample >= 1 { overFullScale += 1 }
                }
            }
            try out.write(from: block)
            offset += n
        }
        durations.sort()
        let diagnostics = processor.diagnosticsSnapshot()
        let report: [String: Any] = [
            "mode": mode, "attenuationDb": attenuation, "preset": preset.rawValue,
            "input": inputURL.path, "output": outputURL.path,
            "sampleRate": rate, "channels": channels, "frames": frames,
            "startSeconds": start, "durationSeconds": Double(frames) / rate,
            "wet": wet, "blockSize": blockSize, "resets": resets,
            "processingSeconds": elapsed, "realTimeFactor": elapsed / (Double(offset) / rate),
            "peak": peak, "samplesAtOrOverFullScale": overFullScale,
            "p99BlockMs": durations[min(durations.count - 1, Int(Double(durations.count) * 0.99))] * 1000,
            "maximumBlockMs": maxBlockSeconds * 1000, "blocks": blocks,
            "deepFilterStatus": processor.deepFilter.currentStatus.label,
            "processedBuffers": diagnostics.processedBuffers,
            "modelBypassedBuffers": diagnostics.modelBypassedBuffers,
            "invalidBuffers": diagnostics.invalidBuffers,
            "lockContendedBuffers": diagnostics.lockContendedBuffers
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: outputURL.appendingPathExtension("json"))
        print(String(data: data, encoding: .utf8)!)
    }
}
