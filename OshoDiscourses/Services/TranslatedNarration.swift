import Foundation

struct NarrationVoice: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let language: String
    let quality: Int
}

/// Osho's pace lengthens the voice's pauses so each paragraph lasts about as long as in the recording.
enum NarrationPace: String, Codable, CaseIterable, Sendable {
    case osho
    case natural

    static let preferenceKey = "narration.pace"

    static var preferred: NarrationPace {
        UserDefaults.standard.string(forKey: preferenceKey).flatMap(NarrationPace.init(rawValue:)) ?? .osho
    }

    /// Osho also speaks slowly between pauses; this much keeps the system voice natural.
    var voiceRateScale: Float {
        switch self {
        case .osho: 0.88
        case .natural: 1
        }
    }

    var label: String {
        switch self {
        case .osho: "Osho's pace"
        case .natural: "Natural pace"
        }
    }
}

struct NarrationSelection: Codable, Hashable, Sendable {
    let sourceLanguage: String
    let targetLanguage: String
    let voice: NarrationVoice
    let pace: NarrationPace

    init(sourceLanguage: String, targetLanguage: String, voice: NarrationVoice, pace: NarrationPace = .natural) {
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.voice = voice
        self.pace = pace
    }

    private enum CodingKeys: String, CodingKey { case sourceLanguage, targetLanguage, voice, pace }

    // Renditions saved before pacing existed are natural pace.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceLanguage = try container.decode(String.self, forKey: .sourceLanguage)
        targetLanguage = try container.decode(String.self, forKey: .targetLanguage)
        voice = try container.decode(NarrationVoice.self, forKey: .voice)
        pace = try container.decodeIfPresent(NarrationPace.self, forKey: .pace) ?? .natural
    }
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
