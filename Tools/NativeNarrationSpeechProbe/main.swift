import AVFoundation
import Foundation

private enum ProbeError: Error {
    case usage, assertion(String)
}

@main
struct NativeNarrationSpeechProbe {
    @MainActor
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.count >= 3, arguments[0] == "assemble" {
                let output = URL(fileURLWithPath: arguments[1])
                let duration = try await NativeNarrationSpeechRenderer().assemble(
                    segments: arguments.dropFirst(2).map { URL(fileURLWithPath: $0) }, to: output
                )
                var report = try inspect(output)
                report["returnedDuration"] = duration
                print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
                return
            }
            let voices = NativeNarrationSpeechRenderer.availableVoices()
            if arguments.count == 2, arguments[0] == "cancel-smoke" {
                try await cancellationSmoke(directory: URL(fileURLWithPath: arguments[1], isDirectory: true), voices: voices)
                return
            }
            if arguments == ["voices"] {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(voices), as: UTF8.self))
                return
            }
            guard arguments.count == 2, arguments[0] == "smoke" else { throw ProbeError.usage }
            let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let renderer = NativeNarrationSpeechRenderer()
            var speech: [[String: Any]] = []
            for (language, text) in [
                ("en", "This narration is prepared privately on this device. Take a quiet moment, and listen."),
                ("hi", "यह कथन इसी उपकरण पर तैयार किया गया है। एक शांत क्षण लें, और ध्यान से सुनें।"),
            ] {
                guard let voice = voices.first(where: { $0.language.hasPrefix(language + "-") }) else {
                    speech.append(["language": language, "outcome": "skipped-no-installed-voice"])
                    continue
                }
                let output = directory.appendingPathComponent("speech-\(language).m4a")
                let start = ContinuousClock.now
                do {
                    let duration = try await renderer.render(text: text, voiceID: voice.id, to: output)
                    var report = try inspect(output)
                    report["language"] = language
                    report["voiceID"] = voice.id
                    report["voiceName"] = voice.name
                    report["voiceQuality"] = voice.quality
                    report["outcome"] = "succeeded"
                    report["returnedDuration"] = duration
                    report["elapsed"] = String(describing: start.duration(to: .now))
                    speech.append(report)
                } catch {
                    print("Speech \(language) failed: \(error)")
                    speech.append([
                        "language": language, "voiceID": voice.id, "outcome": "failed",
                        "error": String(describing: error), "elapsed": String(describing: start.duration(to: .now)),
                    ])
                }
            }
            let first = directory.appendingPathComponent("tone-22050-mono.m4a")
            let second = directory.appendingPathComponent("tone-48000-stereo.m4a")
            let firstDuration = try await tone(to: first, rate: 22_050, channels: 1, seconds: 0.75, frequency: 330)
            let secondDuration = try await tone(to: second, rate: 48_000, channels: 2, seconds: 0.6, frequency: 660)
            let assembled = directory.appendingPathComponent("assembled-tones.m4a")
            let duration = try await renderer.assemble(segments: [first, second, first], to: assembled)
            guard abs(duration - (firstDuration * 2 + secondDuration)) < 0.05 else {
                throw ProbeError.assertion("Assembly duration differs from its source audio")
            }
            var assembly = try inspect(assembled)
            assembly["returnedDuration"] = duration
            assembly["sourceDuration"] = firstDuration * 2 + secondDuration
            assembly["outcome"] = "succeeded"
            let report: [String: Any] = ["installedOrdinaryVoices": voices.count, "speech": speech, "assembly": assembly]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("report.json"))
            print(String(decoding: data, as: UTF8.self))
            if speech.contains(where: { $0["outcome"] as? String == "failed" }) { exit(2) }
        } catch {
            FileHandle.standardError.write(Data("NativeNarrationSpeechProbe: \(error)\nUsage: voices | smoke OUTPUT_DIRECTORY | cancel-smoke OUTPUT_DIRECTORY | assemble OUTPUT SOURCE...\n".utf8))
            exit(1)
        }
    }

    @MainActor
    private static func cancellationSmoke(directory: URL, voices: [NarrationVoice]) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let renderer = NativeNarrationSpeechRenderer()
        var results: [[String: Any]] = []
        if let voice = voices.first(where: { $0.language.hasPrefix("en-") }) {
            let output = directory.appendingPathComponent("speech-replacement.m4a")
            let job = Task {
                try await renderer.render(
                    text: String(repeating: "Preparation happens privately on this device. Take a moment to listen. ", count: 100),
                    voiceID: voice.id, to: output
                )
            }
            do { try await waitForPartial(directory: directory, output: output) }
            catch { job.cancel(); _ = await job.result; throw error }
            let start = ContinuousClock.now
            renderer.cancel()
            do {
                _ = try await job.value
                throw ProbeError.assertion("Active synthesis returned success after cancellation")
            } catch is CancellationError {}
            try checkNoPartial(directory: directory, output: output)
            let cancellationLatency = String(describing: start.duration(to: .now))
            let duration = try await renderer.render(text: "The next narration is ready.", voiceID: voice.id, to: output)
            let snapshot = try Data(contentsOf: output)
            try await Task.sleep(for: .milliseconds(100))
            guard try Data(contentsOf: output) == snapshot else { throw ProbeError.assertion("Retired synthesis changed replacement audio") }
            results.append([
                "stage": "synthesis", "outcome": "cancelled-during-buffer-writing", "voiceID": voice.id,
                "cancellationLatency": cancellationLatency, "replacement": output.path, "replacementDuration": duration,
            ])
        } else {
            results.append(["stage": "synthesis", "outcome": "skipped-no-installed-English-voice"])
        }
        let source = directory.appendingPathComponent("source.m4a")
        _ = try await tone(to: source, rate: 44_100, channels: 1, seconds: 0.5, frequency: 440)
        let output = directory.appendingPathComponent("assembly-replacement.m4a")
        let job = Task { try await renderer.assemble(segments: Array(repeating: source, count: 1000), to: output) }
        do { try await waitForPartial(directory: directory, output: output) }
        catch { job.cancel(); _ = await job.result; throw error }
        let start = ContinuousClock.now
        job.cancel()
        do {
            _ = try await job.value
            throw ProbeError.assertion("Active export returned success after cancellation")
        } catch is CancellationError {}
        try checkNoPartial(directory: directory, output: output)
        let cancellationLatency = String(describing: start.duration(to: .now))
        let duration = try await renderer.assemble(segments: [source, source], to: output)
        results.append([
            "stage": "export", "outcome": "cancelled-during-file-writing", "cancellationLatency": cancellationLatency,
            "replacement": output.path, "replacementDuration": duration,
        ])
        let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("cancellation.json"))
        print(String(decoding: data, as: UTF8.self))
    }

    private static func waitForPartial(directory: URL, output: URL) async throws {
        let deadline = ContinuousClock.now + .seconds(45)
        while ContinuousClock.now < deadline {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            if try files.contains(where: {
                guard $0.lastPathComponent.hasPrefix(".narration-") else { return false }
                return (try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0
            }) { return }
            guard !FileManager.default.fileExists(atPath: output.path) else {
                throw ProbeError.assertion("Preparation finished before the cancellation probe observed a partial file")
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw ProbeError.assertion("No active file writer observed before probe deadline")
    }

    private static func checkNoPartial(directory: URL, output: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard !files.contains(where: { $0 == output || $0.lastPathComponent.hasPrefix(".narration-") }) else {
            throw ProbeError.assertion("Cancellation returned before removing its partial output")
        }
    }

    private static func tone(
        to url: URL, rate: Double, channels: AVAudioChannelCount, seconds: Double, frequency: Double
    ) async throws -> TimeInterval {
        let sink = NarrationSpeechBufferSink(outputURL: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: channels, interleaved: true)!
        let total = Int(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        var offset = 0
        while offset < total {
            let count = min(1024, total - offset)
            buffer.frameLength = AVAudioFrameCount(count)
            for frame in 0..<count {
                for channel in 0..<Int(channels) {
                    buffer.int16ChannelData![channel][frame * buffer.stride] = Int16(
                        sin(Double(offset + frame) * 2 * .pi * frequency / rate) * 8_000
                    )
                }
            }
            sink.receive(buffer)
            offset += count
        }
        buffer.frameLength = 0
        sink.receive(buffer)
        do {
            return try await sink.value()
        } catch {
            throw ProbeError.assertion("Tone \(rate) Hz / \(channels) channels: \(error)")
        }
    }

    private static func inspect(_ url: URL) throws -> [String: Any] {
        let file = try AVAudioFile(forReading: url)
        defer { file.close() }
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192)!
        var energy = 0.0
        var frames: Int64 = 0
        while frames < file.length {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, file.length - frames)))
            guard buffer.frameLength > 0 else { throw ProbeError.assertion("Early end of audio") }
            frames += Int64(buffer.frameLength)
            for frame in 0..<Int(buffer.frameLength) {
                let sample = Double(buffer.floatChannelData![0][frame])
                energy += sample * sample
            }
        }
        guard frames == file.length, frames > 0, energy > 0 else { throw ProbeError.assertion("Empty or truncated output") }
        return [
            "path": url.path, "frames": frames, "sampleRate": file.processingFormat.sampleRate,
            "channels": file.processingFormat.channelCount,
            "duration": Double(frames) / file.processingFormat.sampleRate,
            "rms": sqrt(energy / Double(frames)),
            "bytes": try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0,
            "codec": file.fileFormat.streamDescription.pointee.mFormatID,
        ]
    }
}
