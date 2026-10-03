import Foundation
import Testing
@testable import OshoDiscourses

struct DenoiserStreamTests {
    @Test(arguments: [8_000, 16_000, 22_050, 32_000, 44_100, 48_000, 96_000, 192_000])
    func raggedCallbacksMatchOneContinuousStream(rate: Int) {
        let input = (0..<(rate / 2)).map { index in
            Float(0.25 * sin(2 * .pi * 371 * Double(index) / Double(rate)))
        }
        let wholeStream = DenoiserStream(sourceRate: Double(rate), maxFrames: input.count, hopSize: 480)
        var whole = input
        #expect(run(wholeStream, &whole))

        let raggedStream = DenoiserStream(sourceRate: Double(rate), maxFrames: 1024, hopSize: 480)
        var ragged: [Float] = []
        let sizes = [1, 37, 1024, 480, 999, 7]
        var index = 0
        while ragged.count < input.count {
            let end = min(input.count, ragged.count + sizes[index % sizes.count])
            var block = Array(input[ragged.count..<end])
            #expect(run(raggedStream, &block), "FIFO must not underflow at \(rate) Hz")
            ragged += block
            index += 1
        }
        let difference = zip(whole, ragged).map { abs($0 - $1) }.max() ?? 0
        #expect(difference < 0.00001, "block shape changed audio by \(difference)")
    }

    @Test func failedHopLeavesCallerAudioUntouchedAndResetRecovers() {
        let stream = DenoiserStream(sourceRate: 48_000, maxFrames: 1024, hopSize: 480)
        var input = [Float](repeating: 0.25, count: 1024)
        let original = input
        let handled = input.withUnsafeMutableBufferPointer { pointer in
            stream.process(samples: pointer.baseAddress!, count: pointer.count) { _, _ in false }
        }
        #expect(!handled)
        #expect(input == original)
        stream.reset()
        #expect(run(stream, &input))
        #expect(input.prefix(stream.primeCount).allSatisfy { $0 == 0 })
        #expect(input.dropFirst(stream.primeCount).allSatisfy { $0 == 0.25 })
    }

    @Test func oversizedCallbackDoesNotConsumeStreamState() {
        let stream = DenoiserStream(sourceRate: 48_000, maxFrames: 480, hopSize: 480)
        var oversized = [Float](repeating: 0.9, count: 481)
        #expect(!run(stream, &oversized))
        #expect(oversized.allSatisfy { $0 == 0.9 })
        var first = [Float](repeating: 0.1, count: 480)
        var second = [Float](repeating: 0.2, count: 480)
        #expect(run(stream, &first))
        #expect(run(stream, &second))
        #expect(first.allSatisfy { $0 == 0 })
        #expect(second.allSatisfy { $0 == 0.1 })
    }

    private func run(_ stream: DenoiserStream, _ input: inout [Float]) -> Bool {
        input.withUnsafeMutableBufferPointer { pointer in
            stream.process(samples: pointer.baseAddress!, count: pointer.count) { source, destination in
                destination.update(from: source, count: stream.hopSize)
                return true
            }
        }
    }
}
