import Foundation

struct SeriesDescription {
    let sourceText: String
    let year: String?
    let location: String?
    let themes: [String]
}

enum SeriesMetadata {

    static func description(for seriesName: String) -> SeriesDescription? {
        descriptions[seriesName]
    }

    static func themes(for seriesName: String) -> [String] {
        descriptions[seriesName]?.themes ?? []
    }

    static func searchableText(for seriesName: String) -> String {
        guard let desc = descriptions[seriesName] else { return seriesName }
        return "\(seriesName) \(desc.sourceText) \(desc.themes.joined(separator: " "))"
    }

    /// Pre-lowercased "name + description + themes" per series, built once.
    /// The Library search runs on every keystroke over all 261 series —
    /// rebuilding and lowercasing the concatenated string each time was
    /// wasted work. Series without metadata map to just their lowercased name.
    static let searchCorpus: [String: String] = {
        var corpus: [String: String] = [:]
        for series in Catalog.allSeries {
            corpus[series.name] = searchableText(for: series.name).lowercased()
        }
        return corpus
    }()

    // MARK: - Descriptions

    private static let descriptions: [String: SeriesDescription] = [
        // Popular English
        "Vigyan Bhairav Tantra Vol 1": SeriesDescription(
            sourceText: "The 112 meditation techniques Shiva gives Devi in the Vigyan Bhairav Tantra. Each talk takes up specific methods from this old tantra text and how to actually practice them.",
            year: "1972-73",
            location: "Mumbai",
            themes: ["meditation techniques", "tantra", "Shiva", "awareness", "consciousness"]
        ),
        "Vigyan Bhairav Tantra Vol 2": SeriesDescription(
            sourceText: "Picks up where Vol 1 left off with the remaining techniques of the Vigyan Bhairav Tantra: breathing methods, visualization, sound meditation, awareness practices.",
            year: "1972-73",
            location: "Mumbai",
            themes: ["meditation techniques", "tantra", "breathing", "visualization", "sound"]
        ),
        "Beyond Enlightenment": SeriesDescription(
            sourceText: "What happens after awakening? Consciousness beyond the mind, living an ordinary life after realization, and why knowing is not the same as knowledge.",
            year: "1986",
            location: "Pune",
            themes: ["enlightenment", "consciousness", "beyond mind", "awakening", "spiritual growth"]
        ),
        "The Mustard Seed": SeriesDescription(
            sourceText: "Jesus through the Gospel of Thomas, the gnostic text found at Nag Hammadi. Osho reads Christ's parables the way an Eastern mystic would, and they come out looking very different.",
            year: "1974",
            location: "Pune",
            themes: ["Jesus", "Gospel of Thomas", "Christianity", "mysticism", "parables"]
        ),
        "The Book of Wisdom": SeriesDescription(
            sourceText: "Atisha's Seven Points of Mind Training, a Tibetan Buddhist text on compassion and awareness. About the bodhisattva's path, and how everyday life becomes the meditation.",
            year: "1979",
            location: "Pune",
            themes: ["Atisha", "Tibetan Buddhism", "compassion", "mind training", "bodhisattva"]
        ),
        "Tao Vol 1 Absolute Tao": SeriesDescription(
            sourceText: "Lao Tzu's Tao Te Ching. The Tao that can't be put into words, the art of effortless living, and what water and emptiness have to teach.",
            year: "1975",
            location: "Pune",
            themes: ["Lao Tzu", "Tao Te Ching", "Taoism", "effortlessness", "wu-wei", "emptiness"]
        ),
        "Beyond Psychology": SeriesDescription(
            sourceText: "Talks from the world tour after Oregon. Where Western psychology stops, why therapy isn't meditation, and the difference between mind and consciousness.",
            year: "1986",
            location: "Uruguay",
            themes: ["psychology", "meditation vs therapy", "consciousness", "mind", "freedom"]
        ),
        "The Dhammapada Way of Buddha Vol 1": SeriesDescription(
            sourceText: "The Dhammapada, Gautama Buddha's collected sayings. Practical talks on suffering, desire, awareness, and the middle way.",
            year: "1979",
            location: "Pune",
            themes: ["Buddha", "Dhammapada", "Buddhism", "suffering", "middle way", "awareness"]
        ),

        // Beginner English
        "A Bird on the Wing": SeriesDescription(
            sourceText: "Eleven Zen stories. Each one is a koan that refuses to make rational sense, and that's the point: awakening comes as a jolt, not a conclusion.",
            year: "1974",
            location: "Mumbai",
            themes: ["Zen", "koans", "stories", "awakening", "paradox", "beginner friendly"]
        ),
        "Ancient Music In The Pines": SeriesDescription(
            sourceText: "Zen stories about listening to existence. Silence, the music between sounds, and what it's like to simply be present.",
            year: "1976",
            location: "Pune",
            themes: ["Zen", "silence", "listening", "presence", "nature", "music"]
        ),
        "A Sudden Clash of Thunder": SeriesDescription(
            sourceText: "Zen stories about the moment of awakening. It arrives like thunder, sudden and uninvited, not as the last step of a gradual climb.",
            year: "1976",
            location: "Pune",
            themes: ["Zen", "sudden awakening", "satori", "stories", "discontinuity"]
        ),
        "Come Come Yet Again Come": SeriesDescription(
            sourceText: "Named after Rumi's poem of unconditional welcome. Sufi stories on love, devotion, and surrender. Whatever your past, the door stays open.",
            year: "1980",
            location: "Pune",
            themes: ["Sufism", "Rumi", "love", "devotion", "acceptance", "welcome"]
        ),
        "Be Still and Know": SeriesDescription(
            sourceText: "'Be still and know that I am God.' Talks on stillness as the doorway to knowing, and why belief is a poor substitute for experience.",
            year: "1979",
            location: "Pune",
            themes: ["stillness", "silence", "knowing", "meditation", "God", "experience"]
        ),
        "The Hidden Harmony": SeriesDescription(
            sourceText: "The surviving fragments of Heraclitus, the pre-Socratic Greek. Opposites that turn out to be one, a world in constant flow, and the logos.",
            year: "1974",
            location: "Pune",
            themes: ["Heraclitus", "Greek philosophy", "opposites", "change", "logos", "unity"]
        ),
        "Ah This": SeriesDescription(
            sourceText: "Zen talks circling one recognition: what you're looking for is already here. 'Ah, this!' The ordinary turns out to be the extraordinary.",
            year: "1980",
            location: "Pune",
            themes: ["Zen", "here and now", "ordinary mind", "recognition", "simplicity"]
        ),
        "And the Flowers Showered": SeriesDescription(
            sourceText: "Eleven Zen stories of disciples suddenly flowering into awakening. In each one the mind drops in a different way, without effort.",
            year: "1974",
            location: "Pune",
            themes: ["Zen", "stories", "awakening", "flowering", "effortlessness", "grace"]
        ),

        // Popular Hindi
        "Ashtavakra Maha Geeta": SeriesDescription(
            sourceText: "The Ashtavakra Gita (Ashtavakra Samhita), a dialogue between the sage Ashtavakra and King Janaka about the Self, reality, and liberation. Possibly the most direct Advaita teaching there is.",
            year: "1976",
            location: "Pune",
            themes: ["Ashtavakra", "Advaita", "self-realization", "Janaka", "liberation", "non-duality"]
        ),
        "Geeta Darshan Vol 1-2": SeriesDescription(
            sourceText: "The Bhagavad Gita read as an inner dialogue. The battlefield is your own conflict, and Krishna and Arjuna argue out action, renunciation, and the paths of yoga.",
            year: "1970-71",
            location: "Mumbai",
            themes: ["Bhagavad Gita", "Krishna", "Arjuna", "karma yoga", "dharma", "action"]
        ),
        "Tao Upanishad": SeriesDescription(
            sourceText: "Lao Tzu's Tao Te Ching in Hindi. Effortlessness, flowing with nature, the wisdom of the valley, and how doing nothing gets everything done.",
            year: "1971-72",
            location: "Mumbai",
            themes: ["Lao Tzu", "Tao", "effortlessness", "nature", "wu-wei", "Hindi"]
        ),
        "Bhakti Sutra": SeriesDescription(
            sourceText: "Narada's Bhakti Sutras, his aphorisms on devotion. Love and surrender as a path, how divine love differs from attachment, and where bhakti finally leads.",
            year: "1976",
            location: "Pune",
            themes: ["Narada", "bhakti", "devotion", "love", "surrender", "Hindi"]
        ),
        "Athato Bhakti Jigyasa": SeriesDescription(
            sourceText: "An inquiry into devotion. Bhakti as a spiritual path: love as a method, the lover and the beloved, and the ego dissolving through surrender.",
            year: "1978",
            location: "Pune",
            themes: ["bhakti", "devotion", "inquiry", "love", "ego dissolution", "Hindi"]
        ),
        "Sahaj Yog": SeriesDescription(
            sourceText: "Natural, spontaneous yoga. Meditation without technique, living in the flow, growth that arises on its own instead of being forced.",
            year: "1970",
            location: "Mumbai",
            themes: ["sahaj", "natural yoga", "spontaneity", "effortless meditation", "Hindi"]
        ),
        "Shiv Sutra": SeriesDescription(
            sourceText: "The Shiva Sutras of Kashmir Shaivism, attributed to the sage Vasugupta. The nature of consciousness, methods of awakening, and recognizing what you already are.",
            year: "1974",
            location: "Pune",
            themes: ["Shiva Sutras", "Kashmir Shaivism", "consciousness", "Vasugupta", "recognition", "Hindi"]
        ),

        // Beginner Hindi
        "Main Mrityu Sikhata Hun": SeriesDescription(
            sourceText: "'I teach death.' Death as a doorway: facing mortality changes how you live, and dying consciously is the last meditation.",
            year: "1969",
            location: "Mumbai",
            themes: ["death", "awareness", "mortality", "conscious dying", "transformation", "Hindi"]
        ),
        "Dhyan Sutra": SeriesDescription(
            sourceText: "Practical meditation instruction. Posture, breathing, watching thoughts, and techniques for anyone just starting out.",
            year: "1970",
            location: "Mumbai",
            themes: ["meditation", "practical instructions", "beginner", "techniques", "Hindi"]
        ),
        "Antar Ki Khoj": SeriesDescription(
            sourceText: "The inner search. Turning inward, from the noise of the outer world to inner silence. A gentle place to start with meditation and self-inquiry.",
            year: "1970",
            location: "Mumbai",
            themes: ["inner search", "meditation", "silence", "self-inquiry", "beginner", "Hindi"]
        ),
        "Agyat Ki Aur": SeriesDescription(
            sourceText: "Toward the unknown. On the courage to drop the safety of knowledge and belief and step into uncertainty, because that's where truth is.",
            year: "1970",
            location: "Mumbai",
            themes: ["unknown", "courage", "uncertainty", "truth seeking", "Hindi"]
        ),
        "Amrit Ki Disha": SeriesDescription(
            sourceText: "The direction of nectar, of immortality. Talks on the consciousness in you that doesn't die, and tasting it through meditation and awareness.",
            year: "1969",
            location: "Mumbai",
            themes: ["immortality", "nectar", "consciousness", "awareness", "Hindi"]
        ),
        "Naye Samaj Ki Khoj": SeriesDescription(
            sourceText: "In search of a new society. Society doesn't change by decree, it changes when individuals do. Talks on what a new human consciousness could build.",
            year: "1969",
            location: "Mumbai",
            themes: ["society", "transformation", "new man", "consciousness", "Hindi"]
        ),
        "Jeevan Kranti Ke Sutra": SeriesDescription(
            sourceText: "Sutras for a revolution in living. Practical principles for changing your daily life from the inside, through awareness, love, and meditation.",
            year: "1969",
            location: "Mumbai",
            themes: ["revolution", "transformation", "practical", "daily life", "Hindi"]
        ),

        // Additional well-known series
        "Bodhidharma The Greatest Zen Master": SeriesDescription(
            sourceText: "Bodhidharma, the man who carried Zen from India to China. Mind, emptiness, direct pointing, and his famous nine years of gazing at a wall.",
            year: "1987",
            location: "Pune",
            themes: ["Bodhidharma", "Zen", "China", "wall-gazing", "direct pointing", "emptiness"]
        ),
        "Christianity and Zen": SeriesDescription(
            sourceText: "Christian mysticism and Zen Buddhism side by side. They meet in silence. They part ways over theology, ritual, and how each approaches the divine.",
            year: "1987",
            location: "Pune",
            themes: ["Christianity", "Zen", "mysticism", "comparison", "silence"]
        ),
    ]
}
