import AVFoundation
import Foundation
import Observation

@MainActor
protocol NarrationVoicePreviewSpeaking: AnyObject {
    func speak(
        text: String, voiceID: String, pace: NarrationPace,
        completion: @escaping @MainActor @Sendable () -> Void
    ) throws
    func stop()
}

@MainActor
@Observable
final class NarrationVoicePreview {
    struct Failure: Equatable {
        let ownerID: UUID
        let voiceID: String
        let message: String
    }

    // Windows share one audition channel; closing an older chooser must not stop a newer one.
    static let shared = NarrationVoicePreview()

    private(set) var activeVoiceID: String?
    private(set) var ownerID: UUID?
    private(set) var failure: Failure?
    @ObservationIgnored private let speaker: any NarrationVoicePreviewSpeaking
    @ObservationIgnored private var requestID: UUID?

    init(speaker: any NarrationVoicePreviewSpeaking = NativeNarrationVoicePreviewSpeaker()) {
        self.speaker = speaker
    }

    func play(
        voice: NarrationVoice, sampleText: String?, pace: NarrationPace, ownerID: UUID,
        pausePlayback: @MainActor () -> Void
    ) {
        stop()
        let requestID = UUID()
        self.requestID = requestID
        self.ownerID = ownerID
        activeVoiceID = voice.id
        pausePlayback()

        do {
            try speaker.speak(text: Self.previewText(for: voice, sampleText: sampleText), voiceID: voice.id, pace: pace) { [weak self] in
                guard let self, self.requestID == requestID else { return }
                self.stop(ownerID: ownerID)
            }
        } catch {
            guard self.requestID == requestID else { return }
            stop()
            failure = Failure(ownerID: ownerID, voiceID: voice.id, message: error.localizedDescription)
        }
    }

    func stop(ownerID: UUID? = nil) {
        if let ownerID, self.ownerID != ownerID && failure?.ownerID != ownerID { return }
        requestID = nil
        speaker.stop()
        activeVoiceID = nil
        self.ownerID = nil
        failure = nil
    }

    static func previewText(for voice: NarrationVoice, sampleText: String?) -> String {
        if let sampleText, !sampleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return shortText(sampleText)
        }

        let language = Locale.Language(identifier: voice.language).languageCode?.identifier
        let phrase: String
        switch language {
        case "en": phrase = "Take a moment to listen. Let your thoughts settle, and be here now."
        case "hi": phrase = "एक पल शांत होकर सुनें। अपने विचारों को ठहरने दें और इस क्षण में रहें।"
        case "fr": phrase = "Prenez un moment pour écouter. Laissez vos pensées se poser et soyez ici, maintenant."
        case "es": phrase = "Tómate un momento para escuchar. Deja que tus pensamientos se calmen y vive este momento."
        case "de": phrase = "Nimm dir einen Moment zum Zuhören. Lass deine Gedanken zur Ruhe kommen und sei hier und jetzt."
        case "it": phrase = "Prenditi un momento per ascoltare. Lascia riposare i pensieri e vivi questo momento."
        case "pt": phrase = "Reserve um momento para ouvir. Deixe os pensamentos se acalmarem e esteja aqui, agora."
        case "ja": phrase = "少しの間、静かに耳を傾けてください。心を落ち着けて、今この瞬間を感じてください。"
        case "ko": phrase = "잠시 조용히 귀를 기울여 보세요. 생각을 가라앉히고 지금 이 순간에 머물러 보세요."
        case "zh":
            phrase = NarrationLanguageSupport.languageAndScript(for: voice.language) == "zh-hant"
                ? "靜靜地聆聽片刻。讓思緒平靜下來，感受此時此刻。"
                : "静静地聆听片刻。让思绪平静下来，感受此时此刻。"
        case "ar": phrase = "خذ لحظة للاستماع. دع أفكارك تهدأ، وكن هنا الآن."
        case "ru": phrase = "Уделите минуту тому, чтобы послушать. Пусть мысли успокоятся. Будьте здесь и сейчас."
        case "nl": phrase = "Neem even de tijd om te luisteren. Laat je gedachten tot rust komen en wees hier, nu."
        case "sv": phrase = "Ta en stund och lyssna. Låt tankarna komma till ro och var här och nu."
        case "da": phrase = "Tag et øjeblik til at lytte. Lad tankerne falde til ro, og vær her lige nu."
        case "nb", "nn", "no": phrase = "Ta deg tid til å lytte. La tankene falle til ro, og vær her og nå."
        case "fi": phrase = "Kuuntele hetki rauhassa. Anna ajatusten asettua ja ole tässä hetkessä."
        case "pl": phrase = "Posłuchaj przez chwilę. Pozwól myślom się uspokoić i bądź tu i teraz."
        case "tr": phrase = "Bir an durup dinleyin. Düşüncelerinizin sakinleşmesine izin verin ve bu anda kalın."
        case "el": phrase = "Αφιερώστε μια στιγμή για να ακούσετε. Αφήστε τις σκέψεις να ηρεμήσουν και μείνετε στο παρόν."
        case "he": phrase = "קחו רגע להקשיב. הניחו למחשבות להירגע והיו כאן ועכשיו."
        case "th": phrase = "ลองหยุดฟังสักครู่ ปล่อยให้ความคิดสงบลง และอยู่กับปัจจุบัน"
        case "id": phrase = "Luangkan waktu sejenak untuk mendengarkan. Biarkan pikiran tenang dan hadir di saat ini."
        case "vi": phrase = "Hãy dành một chút thời gian để lắng nghe. Để tâm trí lắng xuống và sống trong hiện tại."
        case "uk": phrase = "Зупиніться на мить і послухайте. Нехай думки заспокояться. Будьте тут і зараз."
        case "cs": phrase = "Na chvíli se zaposlouchejte. Nechte myšlenky zklidnit a buďte tady a teď."
        case "ro": phrase = "Ascultă pentru o clipă. Lasă gândurile să se liniștească și fii aici, acum."
        case "hu": phrase = "Figyelj egy pillanatig. Hagyd, hogy elcsendesedjenek a gondolataid, és légy jelen."
        case "ca": phrase = "Pren-te un moment per escoltar. Deixa que els pensaments es calmin i viu aquest moment."
        default: phrase = voice.name.isEmpty ? voice.language : voice.name
        }
        return shortText(phrase)
    }

    private static func shortText(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class NativeNarrationVoicePreviewSpeaker: NarrationVoicePreviewSpeaking {
    private var synthesizer: AVSpeechSynthesizer?
    private var delegate: NarrationVoicePreviewDelegate?

    func speak(
        text: String, voiceID: String, pace: NarrationPace,
        completion: @escaping @MainActor @Sendable () -> Void
    ) throws {
        stop()
        guard NativeNarrationSpeechRenderer.availableVoices().contains(where: { $0.id == voiceID }),
              let voice = AVSpeechSynthesisVoice(identifier: voiceID), voice.identifier == voiceID else {
            throw NativeNarrationSpeechError.voiceUnavailable
        }

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [])
        try session.setActive(true)
        #endif

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * pace.voiceRateScale
        utterance.prefersAssistiveTechnologySettings = false
        let synthesizer = AVSpeechSynthesizer()
        let delegate = NarrationVoicePreviewDelegate(completion: completion)
        synthesizer.delegate = delegate
        self.synthesizer = synthesizer
        self.delegate = delegate
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer?.delegate = nil
        synthesizer?.stopSpeaking(at: .immediate)
        synthesizer = nil
        delegate = nil
    }
}

private final class NarrationVoicePreviewDelegate: NSObject, AVSpeechSynthesizerDelegate {
    private let completion: @MainActor @Sendable () -> Void

    init(completion: @escaping @MainActor @Sendable () -> Void) {
        self.completion = completion
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [completion] in completion() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [completion] in completion() }
    }
}

enum NarrationVoicePreferences {
    static func preferredVoiceID(
        for language: String, voices: [NarrationVoice], defaults: UserDefaults = .standard
    ) -> String? {
        guard let key = preferenceKey(for: language), let id = defaults.string(forKey: key),
              NarrationLanguageSupport.compatibleVoices(voices, targetLanguage: language).contains(where: { $0.id == id }) else {
            return nil
        }
        return id
    }

    static func setPreferredVoiceID(_ voiceID: String?, for language: String, defaults: UserDefaults = .standard) {
        guard let key = preferenceKey(for: language) else { return }
        if let voiceID, !voiceID.isEmpty {
            defaults.set(voiceID, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func preferenceKey(for language: String) -> String? {
        guard !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let key = NarrationLanguageSupport.languageAndScript(for: language)
        return key.isEmpty ? nil : "narration.preferredVoice.\(key)"
    }
}
