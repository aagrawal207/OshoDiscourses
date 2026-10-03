import Foundation

@main
struct ResamplerProbe {
    static func rms(_ samples: ArraySlice<Float>) -> Double {
        sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count))
    }

    static func main() throws {
        var report: [String: Any] = [:]
        var stopband: [String: Double] = [:]
        for frequency in [11_025.0, 12_000, 14_000, 18_000] {
            let resampler = PolyphaseResampler(inputRate: 48_000, outputRate: 22_050, maxInputFrames: 48_000)
            let input = (0..<48_000).map { Float(0.5 * sin(2 * .pi * frequency * Double($0) / 48_000)) }
            var output = [Float](repeating: 0, count: 25_000)
            let count = resampler.process(input: input, count: input.count, output: &output, outputCapacity: output.count)
            stopband[String(Int(frequency))] = 20 * log10(rms(output[1000..<count]) / (0.5 / sqrt(2)))
        }
        report["stopbandGainDb"] = stopband

        var passband: [String: Double] = [:]
        for frequency in [300.0, 3_000, 5_000, 8_000, 9_500] {
            let up = PolyphaseResampler(inputRate: 22_050, outputRate: 48_000, maxInputFrames: 22_050)
            let down = PolyphaseResampler(inputRate: 48_000, outputRate: 22_050, maxInputFrames: 50_000)
            let input = (0..<22_050).map { Float(0.5 * sin(2 * .pi * frequency * Double($0) / 22_050)) }
            var mid = [Float](repeating: 0, count: 50_000)
            var output = [Float](repeating: 0, count: 25_000)
            let midCount = up.process(input: input, count: input.count, output: &mid, outputCapacity: mid.count)
            let count = down.process(input: mid, count: midCount, output: &output, outputCapacity: output.count)
            passband[String(Int(frequency))] = 20 * log10(rms(output[1000..<count]) / (0.5 / sqrt(2)))
        }
        report["roundTripGainDb"] = passband

        let up = PolyphaseResampler(inputRate: 22_050, outputRate: 48_000, maxInputFrames: 1024)
        let down = PolyphaseResampler(inputRate: 48_000, outputRate: 22_050, maxInputFrames: 2500)
        let input = (0..<1024).map { Float(0.25 * sin(Double($0) * 0.1)) }
        var mid = [Float](repeating: 0, count: 2500)
        var out = [Float](repeating: 0, count: 1200)
        let begin = ProcessInfo.processInfo.systemUptime
        for _ in 0..<1000 {
            let midCount = up.process(input: input, count: input.count, output: &mid, outputCapacity: mid.count)
            _ = down.process(input: mid, count: midCount, output: &out, outputCapacity: out.count)
        }
        report["resamplerOnlyRealTimeFactor"] = (ProcessInfo.processInfo.systemUptime - begin) / (1_024_000.0 / 22_050)
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if CommandLine.arguments.count > 1 {
            try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        print(String(data: data, encoding: .utf8)!)
    }
}
