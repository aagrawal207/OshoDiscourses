import Foundation

struct NarrationVoice: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let language: String
    let quality: Int
}

struct NarrationSelection: Codable, Hashable, Sendable {
    let sourceLanguage: String
    let targetLanguage: String
    let voice: NarrationVoice
}

struct NarrationSegment: Codable, Equatable, Identifiable, Sendable {
    let index: Int
    let sourceParagraphIndex: Int
    let text: String
    let audioFileName: String
    let duration: TimeInterval

    var id: Int { index }
}

/// Translated seconds belong to this rendition, never to the original recording.
struct NarrationDocument: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let discourseID: String
    let sourceDigest: String
    let selection: NarrationSelection
    let expectedSegmentCount: Int
    var segments: [NarrationSegment]
    var audioFileName: String?
    var duration: TimeInterval
    var updatedAt: Date

    var isComplete: Bool {
        expectedSegmentCount > 0 && segments.count == expectedSegmentCount
            && audioFileName != nil && duration.isFinite && duration > 0
    }

    func startTime(forSegmentAt index: Int) -> TimeInterval {
        segments.prefix(max(0, index)).reduce(0) { $0 + $1.duration }
    }

    func segmentIndex(at time: TimeInterval) -> Int? {
        guard time.isFinite, time >= 0, !segments.isEmpty else { return nil }
        var end: TimeInterval = 0
        for segment in segments {
            end += segment.duration
            if time < end { return segment.index }
        }
        return segments.last?.index
    }
}

/// Preparation is offline work; a renderer must close its files before returning.
@MainActor
protocol NarrationSpeechRendering: AnyObject {
    func render(text: String, voiceID: String, to outputURL: URL) async throws -> TimeInterval
    func assemble(segments: [URL], to outputURL: URL) async throws -> TimeInterval
    func cancel()
}
