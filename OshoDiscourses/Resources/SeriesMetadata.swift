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

    // MARK: - Descriptions

    private static let descriptions: [String: SeriesDescription] = [
        // Popular English
        "Vigyan Bhairav Tantra Vol 1": SeriesDescription(
            sourceText: "Discourses on the ancient Shiva Sutra text, 112 meditation techniques given by Shiva to Devi. Each discourse explains and guides through specific meditation methods from this foundational tantra scripture.",
            year: "1972-73",
            location: "Mumbai",
            themes: ["meditation techniques", "tantra", "Shiva", "awareness", "consciousness"]
        ),
        "Vigyan Bhairav Tantra Vol 2": SeriesDescription(
            sourceText: "Continuation of discourses on the 112 meditation techniques from the ancient Vigyan Bhairav Tantra. Covers breathing methods, visualization, sound meditation, and awareness practices.",
            year: "1972-73",
            location: "Mumbai",
            themes: ["meditation techniques", "tantra", "breathing", "visualization", "sound"]
        ),
        "Beyond Enlightenment": SeriesDescription(
            sourceText: "Talks exploring what happens after spiritual awakening. Addresses the nature of consciousness beyond the mind, living in the world after realization, and the difference between knowledge and knowing.",
            year: "1986",
            location: "Pune",
            themes: ["enlightenment", "consciousness", "beyond mind", "awakening", "spiritual growth"]
        ),
        "The Mustard Seed": SeriesDescription(
            sourceText: "Discourses on the sayings of Jesus from the Gospel of Thomas, a gnostic text discovered at Nag Hammadi. Interprets Christ's parables through the lens of Eastern mysticism.",
            year: "1974",
            location: "Pune",
            themes: ["Jesus", "Gospel of Thomas", "Christianity", "mysticism", "parables"]
        ),
        "The Book of Wisdom": SeriesDescription(
            sourceText: "Discourses on Atisha's Seven Points of Mind Training, a Tibetan Buddhist text on compassion and awareness. Covers the path of the bodhisattva and transforming everyday life into meditation.",
            year: "1979",
            location: "Pune",
            themes: ["Atisha", "Tibetan Buddhism", "compassion", "mind training", "bodhisattva"]
        ),
        "Tao Vol 1 Absolute Tao": SeriesDescription(
            sourceText: "Discourses on Lao Tzu's Tao Te Ching. Explores the nature of the Tao as the ultimate reality beyond words, the art of effortless living, and the wisdom of water and emptiness.",
            year: "1975",
            location: "Pune",
            themes: ["Lao Tzu", "Tao Te Ching", "Taoism", "effortlessness", "wu-wei", "emptiness"]
        ),
        "Beyond Psychology": SeriesDescription(
            sourceText: "Talks during the world tour after leaving Oregon. Covers the limits of Western psychology, moving from therapy to meditation, and the difference between the mind and consciousness.",
            year: "1986",
            location: "Uruguay",
            themes: ["psychology", "meditation vs therapy", "consciousness", "mind", "freedom"]
        ),
        "The Dhammapada Way of Buddha Vol 1": SeriesDescription(
            sourceText: "Discourses on the Dhammapada, the collected sayings of Gautama Buddha. Each talk illuminates Buddha's practical teachings on suffering, desire, awareness, and the middle way.",
            year: "1979",
            location: "Pune",
            themes: ["Buddha", "Dhammapada", "Buddhism", "suffering", "middle way", "awareness"]
        ),

        // Beginner English
        "A Bird on the Wing": SeriesDescription(
            sourceText: "Eleven Zen stories explored through discourse. Each story is a koan that points beyond the rational mind toward sudden awakening and the absurd nature of enlightenment.",
            year: "1974",
            location: "Mumbai",
            themes: ["Zen", "koans", "stories", "awakening", "paradox", "beginner friendly"]
        ),
        "Ancient Music In The Pines": SeriesDescription(
            sourceText: "Discourses on Zen stories and the art of listening to existence. Explores silence, the music that exists between sounds, and the meditative quality of simply being present.",
            year: "1976",
            location: "Pune",
            themes: ["Zen", "silence", "listening", "presence", "nature", "music"]
        ),
        "A Sudden Clash of Thunder": SeriesDescription(
            sourceText: "Discourses on Zen stories exploring the moment of awakening — sudden, unexpected, like thunder. How enlightenment is not gradual but a discontinuous leap.",
            year: "1976",
            location: "Pune",
            themes: ["Zen", "sudden awakening", "satori", "stories", "discontinuity"]
        ),
        "Come Come Yet Again Come": SeriesDescription(
            sourceText: "Named after Rumi's poem of unconditional welcome. Discourses on Sufi stories and the path of love, devotion, and surrender. Emphasizes that the door is always open regardless of past.",
            year: "1980",
            location: "Pune",
            themes: ["Sufism", "Rumi", "love", "devotion", "acceptance", "welcome"]
        ),
        "Be Still and Know": SeriesDescription(
            sourceText: "Discourses on the biblical phrase 'Be still and know that I am God.' Explores stillness as the doorway to knowing, the difference between belief and experience, and inner silence.",
            year: "1979",
            location: "Pune",
            themes: ["stillness", "silence", "knowing", "meditation", "God", "experience"]
        ),
        "The Hidden Harmony": SeriesDescription(
            sourceText: "Discourses on the fragments of Heraclitus, the pre-Socratic Greek philosopher. Explores the unity of opposites, the ever-flowing nature of existence, and the logos.",
            year: "1974",
            location: "Pune",
            themes: ["Heraclitus", "Greek philosophy", "opposites", "change", "logos", "unity"]
        ),
        "Ah This": SeriesDescription(
            sourceText: "Discourses on Zen, centering on the realization expressed as 'Ah, this!' — the recognition that what you seek is already here. Points to the ordinary as the extraordinary.",
            year: "1980",
            location: "Pune",
            themes: ["Zen", "here and now", "ordinary mind", "recognition", "simplicity"]
        ),
        "And the Flowers Showered": SeriesDescription(
            sourceText: "Eleven Zen stories about disciples who suddenly flower into awakening. Each story shows a different way the mind drops and understanding arises without effort.",
            year: "1974",
            location: "Pune",
            themes: ["Zen", "stories", "awakening", "flowering", "effortlessness", "grace"]
        ),

        // Popular Hindi
        "Ashtavakra Maha Geeta": SeriesDescription(
            sourceText: "Discourses on the Ashtavakra Gita (Ashtavakra Samhita), a dialogue between sage Ashtavakra and King Janaka on the nature of the Self, reality, and liberation. Considered among the most direct teachings on Advaita.",
            year: "1976",
            location: "Pune",
            themes: ["Ashtavakra", "Advaita", "self-realization", "Janaka", "liberation", "non-duality"]
        ),
        "Geeta Darshan Vol 1-2": SeriesDescription(
            sourceText: "Discourses on the Bhagavad Gita. Krishna's teaching to Arjuna interpreted as an inner dialogue — the battlefield as a metaphor for inner conflict, action versus renunciation, and the paths of yoga.",
            year: "1970-71",
            location: "Mumbai",
            themes: ["Bhagavad Gita", "Krishna", "Arjuna", "karma yoga", "dharma", "action"]
        ),
        "Tao Upanishad": SeriesDescription(
            sourceText: "Hindi discourses on Lao Tzu's Tao Te Ching. The path of effortlessness, flowing with nature, the wisdom of the valley, and how doing nothing leads to everything being done.",
            year: "1971-72",
            location: "Mumbai",
            themes: ["Lao Tzu", "Tao", "effortlessness", "nature", "wu-wei", "Hindi"]
        ),
        "Bhakti Sutra": SeriesDescription(
            sourceText: "Discourses on Narada's Bhakti Sutras — aphorisms on devotion. The path of love and surrender, the nature of divine love versus attachment, and how bhakti leads to liberation.",
            year: "1976",
            location: "Pune",
            themes: ["Narada", "bhakti", "devotion", "love", "surrender", "Hindi"]
        ),
        "Athato Bhakti Jigyasa": SeriesDescription(
            sourceText: "An inquiry into devotion. Explores the nature of bhakti (devotion) as a spiritual path — love as a method, the relationship between lover and beloved, and the dissolution of the ego through surrender.",
            year: "1978",
            location: "Pune",
            themes: ["bhakti", "devotion", "inquiry", "love", "ego dissolution", "Hindi"]
        ),
        "Sahaj Yog": SeriesDescription(
            sourceText: "Discourses on natural or spontaneous yoga — the effortless path that arises from within. Covers meditation without technique, living in the flow, and the spontaneity of spiritual growth.",
            year: "1970",
            location: "Mumbai",
            themes: ["sahaj", "natural yoga", "spontaneity", "effortless meditation", "Hindi"]
        ),
        "Shiv Sutra": SeriesDescription(
            sourceText: "Discourses on Shiva Sutras, an ancient Kashmir Shaivism text attributed to sage Vasugupta. Explores the nature of consciousness, methods of awakening, and the recognition of one's divine nature.",
            year: "1974",
            location: "Pune",
            themes: ["Shiva Sutras", "Kashmir Shaivism", "consciousness", "Vasugupta", "recognition", "Hindi"]
        ),

        // Beginner Hindi
        "Main Mrityu Sikhata Hun": SeriesDescription(
            sourceText: "I teach death. Discourses on understanding death as a doorway — how awareness of mortality transforms life, the art of dying consciously, and death as the ultimate meditation.",
            year: "1969",
            location: "Mumbai",
            themes: ["death", "awareness", "mortality", "conscious dying", "transformation", "Hindi"]
        ),
        "Dhyan Sutra": SeriesDescription(
            sourceText: "Meditation sutras — practical instructions on how to meditate. Covers posture, breathing, watching thoughts, and various techniques for beginners entering the world of meditation.",
            year: "1970",
            location: "Mumbai",
            themes: ["meditation", "practical instructions", "beginner", "techniques", "Hindi"]
        ),
        "Antar Ki Khoj": SeriesDescription(
            sourceText: "The inner search. Talks on turning inward, the journey from the outer world to inner silence. A beginner-friendly introduction to meditation and self-inquiry.",
            year: "1970",
            location: "Mumbai",
            themes: ["inner search", "meditation", "silence", "self-inquiry", "beginner", "Hindi"]
        ),
        "Agyat Ki Aur": SeriesDescription(
            sourceText: "Toward the unknown. Discourses on the courage to step into the unknown, dropping the security of knowledge and belief, and embracing uncertainty as the path to truth.",
            year: "1970",
            location: "Mumbai",
            themes: ["unknown", "courage", "uncertainty", "truth seeking", "Hindi"]
        ),
        "Amrit Ki Disha": SeriesDescription(
            sourceText: "The direction of nectar/immortality. Talks on the deathless consciousness within, how to taste the nectar of existence through meditation and awareness.",
            year: "1969",
            location: "Mumbai",
            themes: ["immortality", "nectar", "consciousness", "awareness", "Hindi"]
        ),
        "Naye Samaj Ki Khoj": SeriesDescription(
            sourceText: "In search of a new society. Talks on transforming society through individual transformation — how a new human consciousness can create a new civilization.",
            year: "1969",
            location: "Mumbai",
            themes: ["society", "transformation", "new man", "consciousness", "Hindi"]
        ),
        "Jeevan Kranti Ke Sutra": SeriesDescription(
            sourceText: "Sutras for life revolution. Practical principles for radical inner transformation — how to revolutionize your daily life through awareness, love, and meditation.",
            year: "1969",
            location: "Mumbai",
            themes: ["revolution", "transformation", "practical", "daily life", "Hindi"]
        ),

        // Additional well-known series
        "Bodhidharma The Greatest Zen Master": SeriesDescription(
            sourceText: "Discourses on Bodhidharma, who brought Zen from India to China. Explores his teachings on mind, emptiness, direct pointing, and the famous 'wall-gazing' meditation.",
            year: "1987",
            location: "Pune",
            themes: ["Bodhidharma", "Zen", "China", "wall-gazing", "direct pointing", "emptiness"]
        ),
        "Christianity and Zen": SeriesDescription(
            sourceText: "A comparison between Christian mysticism and Zen Buddhism. Explores where they meet in silence and where they diverge in theology, ritual, and approach to the divine.",
            year: "1987",
            location: "Pune",
            themes: ["Christianity", "Zen", "mysticism", "comparison", "silence"]
        ),
    ]
}
