import Foundation

// MARK: - Series Info

struct SeriesInfo: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let filePrefix: String
    let count: Int
    let language: Language
    let urlType: URLType
    let slug: String?
    let fileTitle: String?
    let folderName: String?

    init(
        name: String,
        filePrefix: String,
        count: Int,
        language: Language,
        urlType: URLType,
        slug: String? = nil,
        fileTitle: String? = nil,
        folderName: String? = nil
    ) {
        self.id = "\(language.rawValue)-\(filePrefix)"
        self.name = name
        self.filePrefix = filePrefix
        self.count = count
        self.language = language
        self.urlType = urlType
        self.slug = slug
        self.fileTitle = fileTitle
        self.folderName = folderName
    }

    enum Language: String, CaseIterable, Sendable {
        case hindi
        case english
    }

    enum URLType: String, Sendable {
        case underscore
        case slug
        case oshoPrefix = "osho-prefix"
    }
}

// MARK: - Catalog Discourse (value type for URL generation, distinct from SwiftData @Model Discourse)

struct CatalogDiscourse: Identifiable, Hashable, Sendable {
    let id: String
    let seriesName: String
    let number: Int
    let audioURL: String
    let language: SeriesInfo.Language

    var displayTitle: String {
        "\(seriesName) - #\(number)"
    }
}

// MARK: - URL Builder

private let englishNewAudioBase = "https://www.oshoworld.com/wp-content/uploads/newAudios"
private let englishOshoBase = "https://www.oshoworld.com/wp-content/uploads/2020/11/English Audio"
private let hindiBase = "https://www.oshoworld.com/wp-content/uploads/2020/11/Hindi Audio"

func buildAudioURL(series: SeriesInfo, discourseNumber: Int) -> String {
    let padWidth = series.count >= 100 ? 3 : 2
    let num = String(format: "%0\(padWidth)d", discourseNumber)

    switch series.urlType {
    case .underscore:
        let baseName = series.folderName ?? series.filePrefix.trimmingTrailingSeparators()
        let folder = "\(baseName)_(\(series.count))"
        let needsSeparator = !(series.filePrefix.hasSuffix("_") || series.filePrefix.hasSuffix("-"))
        let separator = needsSeparator ? "_" : ""
        let file = "\(series.filePrefix)\(separator)\(num).mp3"
        return "\(englishNewAudioBase)/\(folder)/\(file)"

    case .slug:
        guard let slug = series.slug, let fileTitle = series.fileTitle else {
            return ""
        }
        let file = "\(fileTitle) \(num).mp3"
        return "\(englishNewAudioBase)/\(slug)/\(file)"

    case .oshoPrefix:
        let base = series.language == .hindi ? hindiBase : englishOshoBase
        let file = "OSHO-\(series.filePrefix)_\(num).mp3"
        return "\(base)/\(file)"
    }
}

private extension String {
    func trimmingTrailingSeparators() -> String {
        var result = self
        while result.hasSuffix("_") || result.hasSuffix("-") {
            result.removeLast()
        }
        return result
    }
}

// MARK: - Catalog

enum Catalog {

    static let allSeries: [SeriesInfo] = englishUnderscoreSeries + englishSlugSeries + englishOshoPrefixSeries + hindiSeriesList

    static var englishSeries: [SeriesInfo] {
        allSeries.filter { $0.language == .english }
    }

    static var hindiSeries: [SeriesInfo] {
        allSeries.filter { $0.language == .hindi }
    }

    static func allDiscourses() -> [CatalogDiscourse] {
        allSeries.flatMap { series in
            (1...series.count).map { num in
                let url = buildAudioURL(series: series, discourseNumber: num)
                return CatalogDiscourse(
                    id: "\(series.id)-\(num)",
                    seriesName: series.name,
                    number: num,
                    audioURL: url,
                    language: series.language
                )
            }
        }
    }

    static func discourses(for series: SeriesInfo) -> [CatalogDiscourse] {
        (1...series.count).map { num in
            let url = buildAudioURL(series: series, discourseNumber: num)
            return CatalogDiscourse(
                id: "\(series.id)-\(num)",
                seriesName: series.name,
                number: num,
                audioURL: url,
                language: series.language
            )
        }
    }

    static let discourseLookup: [String: (discourse: CatalogDiscourse, series: SeriesInfo)] = {
        var dict = [String: (CatalogDiscourse, SeriesInfo)]()
        for series in allSeries {
            for disc in discourses(for: series) {
                dict[disc.id] = (disc, series)
            }
        }
        return dict
    }()

    // MARK: - Curated Lists

    static let popularEnglishNames: [String] = [
        "Vigyan Bhairav Tantra Vol 1",
        "Vigyan Bhairav Tantra Vol 2",
        "Beyond Enlightenment",
        "The Mustard Seed",
        "The Book of Wisdom",
        "Tao Vol 1 Absolute Tao",
        "Beyond Psychology",
        "The Dhammapada Way of Buddha Vol 1",
    ]

    static let beginnerEnglishNames: [String] = [
        "A Bird on the Wing",
        "Ancient Music In The Pines",
        "A Sudden Clash of Thunder",
        "Come Come Yet Again Come",
        "Be Still and Know",
        "The Hidden Harmony",
        "Ah This",
        "And the Flowers Showered",
    ]

    static let popularHindiNames: [String] = [
        "Ashtavakra Maha Geeta",
        "Geeta Darshan Vol 1-2",
        "Tao Upanishad",
        "Bhakti Sutra",
        "Athato Bhakti Jigyasa",
        "Sahaj Yog",
        "Shiv Sutra",
    ]

    static let beginnerHindiNames: [String] = [
        "Main Mrityu Sikhata Hun",
        "Dhyan Sutra",
        "Antar Ki Khoj",
        "Agyat Ki Aur",
        "Amrit Ki Disha",
        "Naye Samaj Ki Khoj",
        "Jeevan Kranti Ke Sutra",
    ]

    static var popularEnglish: [SeriesInfo] {
        popularEnglishNames.compactMap { name in allSeries.first { $0.name == name } }
    }

    static var beginnerEnglish: [SeriesInfo] {
        beginnerEnglishNames.compactMap { name in allSeries.first { $0.name == name } }
    }

    static var popularHindi: [SeriesInfo] {
        popularHindiNames.compactMap { name in allSeries.first { $0.name == name } }
    }

    static var beginnerHindi: [SeriesInfo] {
        beginnerHindiNames.compactMap { name in allSeries.first { $0.name == name } }
    }
}

// MARK: - English Underscore Series

private let englishUnderscoreSeries: [SeriesInfo] = [
    SeriesInfo(name: "A Bird on the Wing", filePrefix: "A_Bird_on_the_Wing__", count: 11, language: .english, urlType: .underscore, folderName: "A_Bird_on_the_Wing"),
    SeriesInfo(name: "A Sudden Clash of Thunder", filePrefix: "A_Sudden_Clash_of_Thunder", count: 10, language: .english, urlType: .underscore),
    SeriesInfo(name: "Ah This", filePrefix: "Ah_This", count: 8, language: .english, urlType: .underscore),
    SeriesInfo(name: "Ancient Music In The Pines", filePrefix: "Ancient_Music_In_The_Pines", count: 9, language: .english, urlType: .underscore),
    SeriesInfo(name: "And the Flowers Showered", filePrefix: "And_the_Flowers_Showerd", count: 11, language: .english, urlType: .underscore),
    SeriesInfo(name: "Be Still and Know", filePrefix: "Be_Still_and_Know", count: 10, language: .english, urlType: .underscore),
    SeriesInfo(name: "Beyond Enlightenment", filePrefix: "Beyond_Enlightenment", count: 32, language: .english, urlType: .underscore),
    SeriesInfo(name: "Beyond Psychology", filePrefix: "Beyond_Psychology", count: 44, language: .english, urlType: .underscore),
    SeriesInfo(name: "Bodhidharma The Greatest Zen Master", filePrefix: "Bodhidharma_The_Greatest_Zen_Master", count: 20, language: .english, urlType: .underscore),
    SeriesInfo(name: "Christianity and Zen", filePrefix: "Christianity_and_Zen", count: 8, language: .english, urlType: .underscore),
    SeriesInfo(name: "Come Come Yet Again Come", filePrefix: "Come_Come_Yet_Again_Come", count: 15, language: .english, urlType: .underscore),
    SeriesInfo(name: "Come Follow to You Vol 1", filePrefix: "Come_Follow_to_You_Vol_1-", count: 10, language: .english, urlType: .underscore, folderName: "Come_Follow_to_You_Vol_1"),
    SeriesInfo(name: "Come Follow to You Vol 2", filePrefix: "Come_Follow_to_You_Vol_2-", count: 11, language: .english, urlType: .underscore, folderName: "Come_Follow_to_You_Vol_2"),
    SeriesInfo(name: "Come Follow to You Vol 3", filePrefix: "Come_Follow_to_You_Vol_3-", count: 10, language: .english, urlType: .underscore, folderName: "Come_Follow_to_You_Vol_3"),
    SeriesInfo(name: "Come Follow to You Vol 4", filePrefix: "Come_Follow_to_You_Vol_4-", count: 11, language: .english, urlType: .underscore, folderName: "Come_Follow_to_You_Vol_4"),
    SeriesInfo(name: "Communism And Zen Fire Zen Wind", filePrefix: "Communism_And_Zen__Fire__Zen_Wind", count: 7, language: .english, urlType: .underscore),
    SeriesInfo(name: "Dang Dang Doko Dang", filePrefix: "Dang_Dang_Doko_Dang", count: 10, language: .english, urlType: .underscore),
    SeriesInfo(name: "Ecstasy Forgotten Language", filePrefix: "Ecstasy_Forgotten_Language", count: 10, language: .english, urlType: .underscore),
    SeriesInfo(name: "Fish In the Sea Is Not Thirsty", filePrefix: "Fish_In_the_Sea_Is_Not_Thirsty", count: 15, language: .english, urlType: .underscore),
    SeriesInfo(name: "From Bondage to Freedom", filePrefix: "From_Bondage_to_Freedom", count: 43, language: .english, urlType: .underscore),
    SeriesInfo(name: "Vigyan Bhairav Tantra Vol 1", filePrefix: "Vigyan_Bhairav_Tantra_Vol_1", count: 40, language: .english, urlType: .underscore),
    SeriesInfo(name: "Vigyan Bhairav Tantra Vol 2", filePrefix: "Vigyan_Bhairav_Tantra_Vol_2", count: 40, language: .english, urlType: .underscore),
]

// MARK: - English Slug Series

private let englishSlugSeries: [SeriesInfo] = [
    // Buddha and Buddhist Masters
    SeriesInfo(name: "The Book of Wisdom", filePrefix: "The_Book_Of_Wisdom", count: 28, language: .english, urlType: .slug, slug: "the-book-of-wisdom-buddha-series", fileTitle: "The Book Of Wisdom"),
    SeriesInfo(name: "The Dhammapada Way of Buddha Vol 1", filePrefix: "Dhammapada_Way_Of_Buddha_Vol_1", count: 10, language: .english, urlType: .slug, slug: "the-dhammapada-way-of-buddha-vol-1-series", fileTitle: "Dhammapada Way Of Buddha Vol 1"),
    SeriesInfo(name: "The Dhammapada Way of Buddha Vol 2", filePrefix: "Dhammapada_Way_Of_Buddha_Vol_2", count: 10, language: .english, urlType: .slug, slug: "the-dhammapada-way-of-buddha-vol-2-series", fileTitle: "Dhammapada Way Of Buddha Vol 2"),
    SeriesInfo(name: "The Dhammapada Way of Buddha Vol 3", filePrefix: "Dhammapada_Way_Of_Buddha_Vol_3", count: 10, language: .english, urlType: .slug, slug: "the-dhammapada-way-of-buddha-vol-3-series", fileTitle: "Dhammapada Way Of Buddha Vol 3"),
    SeriesInfo(name: "The Dhammapada Way of Buddha Vol 4", filePrefix: "Dhammapada_Way_Of_Buddha_Vol_4", count: 10, language: .english, urlType: .slug, slug: "the-dhammapada-way-of-buddha-vol-4-series", fileTitle: "Dhammapada Way Of Buddha Vol 4"),
    SeriesInfo(name: "The Dhammapada Way of Buddha Vol 5", filePrefix: "Dhammapada_Way_Of_Buddha_Vol_5", count: 10, language: .english, urlType: .slug, slug: "the-dhammapada-way-of-buddha-vol-5-series", fileTitle: "Dhammapada Way Of Buddha Vol 5"),
    SeriesInfo(name: "The Dhammapada Way of Buddha Vol 6", filePrefix: "Dhammapada_Way_Of_Buddha_Vol_6", count: 10, language: .english, urlType: .slug, slug: "the-dhammapada-way-of-buddha-vol-6-series", fileTitle: "Dhammapada Way Of Buddha Vol 6"),
    SeriesInfo(name: "The Dhammapada Way of Buddha Vol 7", filePrefix: "Dhammapada_Way_Of_Buddha_Vol_7", count: 10, language: .english, urlType: .slug, slug: "the-dhammapada-way-of-buddha-vol-7-series", fileTitle: "Dhammapada Way Of Buddha Vol 7"),
    SeriesInfo(name: "The Dhammapada Way of Buddha Vol 8", filePrefix: "Dhammapada_Way_Of_Buddha_Vol_8", count: 13, language: .english, urlType: .slug, slug: "the-dhammapada-way-of-buddha-vol-8-series", fileTitle: "Dhammapada Way Of Buddha Vol 8"),
    SeriesInfo(name: "The Dhammapada Way of Buddha Vol 9", filePrefix: "Dhammapada_Way_Of_Buddha_Vol_9", count: 10, language: .english, urlType: .slug, slug: "the-dhammapada-way-of-buddha-vol-9-series", fileTitle: "Dhammapada Way Of Buddha Vol 9"),
    SeriesInfo(name: "The Dhammapada Way of Buddha Vol 10", filePrefix: "Dhammapada_Way_Of_Buddha_Vol_10", count: 13, language: .english, urlType: .slug, slug: "the-dhammapada-way-of-buddha-vol-10-series", fileTitle: "Dhammapada Way Of Buddha Vol 10"),
    SeriesInfo(name: "The Dhammapada Way of Buddha Vol 11", filePrefix: "Dhammapada_Way_Of_Buddha_Vol_11", count: 10, language: .english, urlType: .slug, slug: "the-dhammapada-way-of-buddha-vol-11-series", fileTitle: "Dhammapada Way Of Buddha Vol 11"),
    SeriesInfo(name: "The Dhammapada Way of Buddha Vol 12", filePrefix: "Dhammapada_Way_Of_Buddha_Vol_12", count: 10, language: .english, urlType: .slug, slug: "the-dhammapada-way-of-buddha-vol-12-series", fileTitle: "Dhammapada Way Of Buddha Vol 12"),
    SeriesInfo(name: "The Diamond Sutra", filePrefix: "The_Diamond_Sutra", count: 11, language: .english, urlType: .slug, slug: "the-diamond-sutra-series", fileTitle: "The Diamond Sutra"),
    SeriesInfo(name: "The Discipline of Transcendence Vol 1", filePrefix: "The_Discipline_Of_Transcendence_Vol_1", count: 10, language: .english, urlType: .slug, slug: "the-discipline-of-transcendence-vol-1-series", fileTitle: "The Discipline Of Transcendence Vol 1"),
    SeriesInfo(name: "The Discipline of Transcendence Vol 2", filePrefix: "The_Discipline_Of_Transcendence_Vol_2", count: 11, language: .english, urlType: .slug, slug: "the-discipline-of-transcendence-vol-2-series", fileTitle: "The Discipline Of Transcendence Vol 2"),

    // Zen and Zen Masters (slug pattern)
    SeriesInfo(name: "Dogen The Zen Master A Search and A Fulfilment", filePrefix: "Dogen_The_Zen_Master", count: 8, language: .english, urlType: .slug, slug: "dogen-the-zen-master-a-search-and-a-fulfilment-01-08", fileTitle: "Dogen The Zen Master A Search And A Fulfilment"),
    SeriesInfo(name: "God is Dead Zen is the Only Living Truth", filePrefix: "God_Is_Dead_Zen_Is_The_Only_Living_Truth", count: 7, language: .english, urlType: .slug, slug: "god-is-dead-zen-is-the-only-living-truth-series", fileTitle: "God Is Dead Zen Is The Only Living Truth"),
    SeriesInfo(name: "Hyakujo The Everest of Zen", filePrefix: "Hyakujo_The_Everest_Of_Zen", count: 9, language: .english, urlType: .slug, slug: "hyakujo-the-everest-of-zen-with-bashos-haikus-series", fileTitle: "Hyakujo The Everest Of Zen"),
    SeriesInfo(name: "I Celebrate Myself", filePrefix: "I_Celebrate_Myself", count: 7, language: .english, urlType: .slug, slug: "i-celebrate-myself-series", fileTitle: "I Celebrate Myself"),
    SeriesInfo(name: "Isan No Footprints In the Blue Sky", filePrefix: "Isan_No_Footprints_In_The_Blue_Sky", count: 8, language: .english, urlType: .slug, slug: "isan-no-footprints-in-the-blue-sky-series", fileTitle: "Isan No Footprints In The Blue Sky"),
    SeriesInfo(name: "Joshu The Lion's Roar", filePrefix: "Joshu_The_Lions_Roar", count: 8, language: .english, urlType: .slug, slug: "joshu-the-lions-roar-series", fileTitle: "Joshu The Lions Roar"),
    SeriesInfo(name: "Kyozan A True Man of Zen", filePrefix: "Kyozan_A_True_Man_Of_Zen", count: 4, language: .english, urlType: .slug, slug: "kyozan-a-true-man-of-zen-series", fileTitle: "Kyozan A True Man Of Zen"),
    SeriesInfo(name: "Live Zen", filePrefix: "Live_Zen", count: 10, language: .english, urlType: .slug, slug: "live-zen-series", fileTitle: "Live Zen"),
    SeriesInfo(name: "Ma Tzu The Empty Mirror", filePrefix: "Ma_Tzu_The_Empty_Mirror", count: 10, language: .english, urlType: .slug, slug: "ma-tzu-the-empty-mirror-series", fileTitle: "Ma Tzu The Empty Mirror"),
    SeriesInfo(name: "Nansen The Point of Departure", filePrefix: "Nansen_The_Point_Of_Departure", count: 8, language: .english, urlType: .slug, slug: "nansen-the-point-of-departure-series", fileTitle: "Nansen The Point Of Departure"),
    SeriesInfo(name: "No Mind The Flowers of Eternity", filePrefix: "No_Mind_The_Flowers_Of_Eternity", count: 10, language: .english, urlType: .slug, slug: "no-mind-the-flowers-of-eternity-series", fileTitle: "No Mind The Flowers Of Eternity"),
    SeriesInfo(name: "No Water No Moon", filePrefix: "No_Water_No_Moon", count: 10, language: .english, urlType: .slug, slug: "no-water-no-moon-series", fileTitle: "No Water No Moon"),
    SeriesInfo(name: "One Seed Makes The Whole Earth Green", filePrefix: "One_Seed_Makes_The_Whole_Earth_Green", count: 4, language: .english, urlType: .slug, slug: "one-seed-makes-the-whole-earth-green-series", fileTitle: "One Seed Makes The Whole Earth Green"),
    SeriesInfo(name: "Returning To The Source", filePrefix: "Returning_To_The_Source", count: 10, language: .english, urlType: .slug, slug: "returning-to-the-source-series", fileTitle: "Returning To The Source"),
    SeriesInfo(name: "Rinzai Master of the Irrational", filePrefix: "Rinzai_Master_Of_The_Irrational", count: 8, language: .english, urlType: .slug, slug: "rinzai-master-of-the-irrational-series", fileTitle: "Rinzai Master Of The Irrational"),
    SeriesInfo(name: "The Grass Grows By Itself", filePrefix: "The_Grass_Grows_By_Itself", count: 8, language: .english, urlType: .slug, slug: "the-grass-grows-by-itself-series", fileTitle: "The Grass Grows By Itself"),
    SeriesInfo(name: "The Heart Sutra", filePrefix: "The_Heart_Sutra", count: 10, language: .english, urlType: .slug, slug: "the-heart-sutra-series", fileTitle: "The Heart Sutra"),
    SeriesInfo(name: "The Language of Existence", filePrefix: "The_Language_Of_Existence", count: 9, language: .english, urlType: .slug, slug: "the-language-of-existence-series", fileTitle: "The Language Of Existence"),
    SeriesInfo(name: "The Miracle", filePrefix: "The_Miracle", count: 10, language: .english, urlType: .slug, slug: "the-miracle-series", fileTitle: "The Miracle"),
    SeriesInfo(name: "The Original Man", filePrefix: "The_Original_Man", count: 9, language: .english, urlType: .slug, slug: "the-original-man-series", fileTitle: "The Original Man"),
    SeriesInfo(name: "Turning In", filePrefix: "Turning_In", count: 8, language: .english, urlType: .slug, slug: "turning-in-series", fileTitle: "Turning In"),
    SeriesInfo(name: "Yakusan Straight To The Point of Enlightenment", filePrefix: "Yakusan_Straight_To_The_Point_Of_Enlightenment", count: 5, language: .english, urlType: .slug, slug: "yakusan-straight-to-the-point-of-enlightenment-series", fileTitle: "Yakusan Straight To The Point Of Enlightenment"),
    SeriesInfo(name: "Zen The Diamond Thunderbolt", filePrefix: "Zen_The_Diamond_Thunderbolt", count: 10, language: .english, urlType: .slug, slug: "zen-the-diamond-thunderbolt-series", fileTitle: "Zen The Diamond Thunderbolt"),
    SeriesInfo(name: "Zen The Special Transmission", filePrefix: "Zen_The_Special_Transmission", count: 10, language: .english, urlType: .slug, slug: "zen-the-special-transmission-series", fileTitle: "Zen The Special Transmission"),

    // Other/Miscellaneous
    SeriesInfo(name: "Nirvana The Last Nightmare", filePrefix: "Nirvana_The_Last_Nightmare", count: 10, language: .english, urlType: .slug, slug: "nirvana-the-last-nightmare-series", fileTitle: "Nirvana The Last Nightmare"),
    SeriesInfo(name: "Take It Easy Vol 1", filePrefix: "Take_It_Easy_Vol_1", count: 10, language: .english, urlType: .slug, slug: "take-it-easy-series", fileTitle: "Take It Easy Vol 1"),
    SeriesInfo(name: "The First Principle", filePrefix: "The_First_Principle", count: 10, language: .english, urlType: .slug, slug: "the-first-principle-series", fileTitle: "The First Principle"),
    SeriesInfo(name: "Theologia Mystica", filePrefix: "Theologia_Mystica", count: 10, language: .english, urlType: .slug, slug: "theologia-mystica-series", fileTitle: "Theologia Mystica"),
    SeriesInfo(name: "Walking In Zen Sitting In Zen", filePrefix: "Walking_In_Zen_Sitting_In_Zen", count: 10, language: .english, urlType: .slug, slug: "walking-in-zen-sitting-in-zen-series", fileTitle: "Walking In Zen Sitting In Zen"),

    // Sufism
    SeriesInfo(name: "Journey to the Heart Sufism", filePrefix: "Journey_To_The_Heart", count: 10, language: .english, urlType: .slug, slug: "journey-to-the-heart-sufism-series", fileTitle: "Journey To The Heart"),
    SeriesInfo(name: "Just Like That", filePrefix: "Just_Like_That", count: 10, language: .english, urlType: .slug, slug: "just-like-that-series", fileTitle: "Just Like That"),
    SeriesInfo(name: "Sufis People of the Path", filePrefix: "Sufis_People_Of_The_Path", count: 31, language: .english, urlType: .slug, slug: "sufis-people-of-the-path-series", fileTitle: "Sufis People Of The Path"),
    SeriesInfo(name: "The Perfect Master", filePrefix: "The_Perfect_Master", count: 20, language: .english, urlType: .slug, slug: "the-perfect-master-series", fileTitle: "The Perfect Master"),
    SeriesInfo(name: "The Secret", filePrefix: "The_Secret", count: 21, language: .english, urlType: .slug, slug: "the-secret-series", fileTitle: "The Secret"),
    SeriesInfo(name: "Unio Mystica", filePrefix: "Unio_Mystica", count: 20, language: .english, urlType: .slug, slug: "unio-mystica-series", fileTitle: "Unio Mystica"),
    SeriesInfo(name: "Wisdom of The Sands", filePrefix: "Wisdom_Of_The_Sands", count: 18, language: .english, urlType: .slug, slug: "wisdom-of-the-sands-series", fileTitle: "Wisdom Of The Sands"),

    // Tantra
    SeriesInfo(name: "Tantra The Supreme Understanding", filePrefix: "Tantra_The_Supreme_Understanding", count: 10, language: .english, urlType: .slug, slug: "tantra-the-supreme-understanding-series", fileTitle: "Tantra The Supreme Understanding"),
    SeriesInfo(name: "Tantra Vision Vol 1", filePrefix: "Tantra_Vision_Vol_1", count: 10, language: .english, urlType: .slug, slug: "tantra-vision-vol-1-tantra-experience-series", fileTitle: "Tantra Vision Vol 1"),
    SeriesInfo(name: "Tantra Vision Vol 2", filePrefix: "Tantra_Vision_Vol_2", count: 10, language: .english, urlType: .slug, slug: "tantra-vision-vol-2-tantric-transformation-series", fileTitle: "Tantra Vision Vol 2"),

    // Tao
    SeriesInfo(name: "Tao The Pathless Path", filePrefix: "Tao_The_Pathless_Path", count: 28, language: .english, urlType: .slug, slug: "tao-the-pathless-path-series", fileTitle: "Tao The Pathless Path"),
    SeriesInfo(name: "Tao Vol 1 Absolute Tao", filePrefix: "Tao_Vol_1_Absolute_Tao", count: 10, language: .english, urlType: .slug, slug: "tao-vol-1-absolute-tao-the-three-treasures-series", fileTitle: "Tao Vol 1 Absolute Tao"),
    SeriesInfo(name: "Tao Vol 2 Living Tao", filePrefix: "Tao_Vol_2_Living_Tao", count: 10, language: .english, urlType: .slug, slug: "tao-vol-2-living-tao-the-three-treasures-series", fileTitle: "Tao Vol 2 Living Tao"),
    SeriesInfo(name: "Tao Vol 3 Undone", filePrefix: "Tao_Vol_3_Undone", count: 10, language: .english, urlType: .slug, slug: "tao-vol-3-undone-the-three-treasures-series", fileTitle: "Tao Vol 3 Undone"),
    SeriesInfo(name: "Tao Vol 4 Talking", filePrefix: "Tao_Vol_4_Talking", count: 9, language: .english, urlType: .slug, slug: "tao-vol-4-talking-the-three-treasures-series", fileTitle: "Tao Vol 4 Talking"),
    SeriesInfo(name: "The Empty Boat", filePrefix: "The_Empty_Boat", count: 10, language: .english, urlType: .slug, slug: "the-empty-boat-series", fileTitle: "The Empty Boat"),
    SeriesInfo(name: "The Golden Gate", filePrefix: "The_Golden_Gate", count: 20, language: .english, urlType: .slug, slug: "the-golden-gate-series", fileTitle: "The Golden Gate"),
    SeriesInfo(name: "The Secret of Secrets", filePrefix: "The_Secret_Of_Secrets", count: 31, language: .english, urlType: .slug, slug: "the-secret-of-secrets-series", fileTitle: "The Secret Of Secrets"),
    SeriesInfo(name: "When the Shoe Fits", filePrefix: "When_The_Shoe_Fits", count: 10, language: .english, urlType: .slug, slug: "when-the-shoe-fits-series", fileTitle: "When The Shoe Fits"),

    // Upanishads
    SeriesInfo(name: "I Am That", filePrefix: "I_Am_That", count: 16, language: .english, urlType: .slug, slug: "i-am-that-series", fileTitle: "I Am That"),
    SeriesInfo(name: "Philosophia Ultima", filePrefix: "Philosophia_Ultima", count: 16, language: .english, urlType: .slug, slug: "philosophia-ultima-series", fileTitle: "Philosophia Ultima"),
    SeriesInfo(name: "That Art Thou", filePrefix: "That_Art_Thou", count: 50, language: .english, urlType: .slug, slug: "that-art-thou-series", fileTitle: "That Art Thou"),
    SeriesInfo(name: "The Supreme Doctrine", filePrefix: "The_Supreme_Doctrine", count: 16, language: .english, urlType: .slug, slug: "the-supreme-doctrine-series", fileTitle: "The Supreme Doctrine"),
    SeriesInfo(name: "The Ultimate Alchemy", filePrefix: "The_Ultimate_Alchemy", count: 34, language: .english, urlType: .slug, slug: "the-ultimate-alchemy-series", fileTitle: "The Ultimate Alchemy"),
    SeriesInfo(name: "Vedanta Seven Steps to Samadhi", filePrefix: "Vedanta_Seven_Steps_To_Samadhi", count: 17, language: .english, urlType: .slug, slug: "vedanta-seven-steps-to-samadhi-series", fileTitle: "Vedanta Seven Steps To Samadhi"),

    // Western Mystics
    SeriesInfo(name: "Guida Spirituale", filePrefix: "Guida_Spirituale", count: 16, language: .english, urlType: .slug, slug: "guida-spirituale-series", fileTitle: "Guida Spirituale"),
    SeriesInfo(name: "New Alchemy To Turn You On", filePrefix: "New_Alchemy_To_Turn_You_On", count: 34, language: .english, urlType: .slug, slug: "new-alchemy-to-turn-you-on-series", fileTitle: "New Alchemy To Turn You On"),
    SeriesInfo(name: "Philosophia Perennis", filePrefix: "Philosophia_Perennis", count: 21, language: .english, urlType: .slug, slug: "philosophia-perennisia-series", fileTitle: "Philosophia Perennis"),
    SeriesInfo(name: "The Hidden Harmony", filePrefix: "The_Hidden_Harmony", count: 11, language: .english, urlType: .slug, slug: "the-hidden-harmony-series", fileTitle: "The Hidden Harmony"),
    SeriesInfo(name: "The Hidden Splendor", filePrefix: "The_Hidden_Splendor", count: 27, language: .english, urlType: .slug, slug: "the-hidden-splendor-series", fileTitle: "The Hidden Splendor"),
    SeriesInfo(name: "The Prophet", filePrefix: "The_Prophet", count: 47, language: .english, urlType: .slug, slug: "the-prophet-series", fileTitle: "The Prophet"),
    SeriesInfo(name: "Zarathustra A God Can Dance", filePrefix: "Zarathustra_A_God_Can_Dance", count: 23, language: .english, urlType: .slug, slug: "zarathustra-a-god-can-dance-series", fileTitle: "Zarathustra A God Can Dance"),
    SeriesInfo(name: "Zarathustra The Laughing Prophet", filePrefix: "Zarathustra_The_Laughing_Prophet", count: 23, language: .english, urlType: .slug, slug: "zarathustra-the-laughing-prophet-series", fileTitle: "Zarathustra The Laughing Prophet"),

    // Yoga
    SeriesInfo(name: "Yoga Vol 1 The Path of Yoga", filePrefix: "The_Path_Of_Yoga", count: 9, language: .english, urlType: .slug, slug: "yoga-vol-1-the-path-of-yoga-series", fileTitle: "The Path Of Yoga"),
    SeriesInfo(name: "Yoga Vol 2 The Science of Soul", filePrefix: "The_Science_Of_Soul", count: 10, language: .english, urlType: .slug, slug: "yoga-vol-2-the-science-of-soul-series", fileTitle: "The Science Of Soul"),
    SeriesInfo(name: "Yoga Vol 3 The Mystery Beyond Mind", filePrefix: "The_Mystery_Beyond_Mind", count: 10, language: .english, urlType: .slug, slug: "yoga-vol-3-the-mystery-beyond-mind-series", fileTitle: "The Mystery Beyond Mind"),
    SeriesInfo(name: "Yoga Vol 4 The Alchemy of Yoga", filePrefix: "The_Alchemy_Of_Yoga", count: 10, language: .english, urlType: .slug, slug: "yoga-vol-4-the-alchemy-of-yoga-series", fileTitle: "The Alchemy Of Yoga"),
    SeriesInfo(name: "Yoga Vol 5 A New Direction", filePrefix: "A_New_Direction", count: 10, language: .english, urlType: .slug, slug: "yoga-vol-5-a-new-direction-series", fileTitle: "A New Direction"),
    SeriesInfo(name: "Yoga Vol 6 The Essence of Yoga", filePrefix: "The_Essence_Of_Yoga", count: 10, language: .english, urlType: .slug, slug: "yoga-vol-6-the-essence-of-yoga-series", fileTitle: "The Essence Of Yoga"),
    SeriesInfo(name: "Yoga Vol 7 The Science of Living", filePrefix: "The_Science_Of_Living", count: 10, language: .english, urlType: .slug, slug: "yoga-vol-7-the-science-of-living-series", fileTitle: "The Science Of Living"),
    SeriesInfo(name: "Yoga Vol 8 The Secret of Yoga", filePrefix: "The_Secret_Of_Yoga", count: 10, language: .english, urlType: .slug, slug: "yoga-vol-8-the-secret-of-yoga-series", fileTitle: "The Secret Of Yoga"),
    SeriesInfo(name: "Yoga Vol 9 The Path of Liberation", filePrefix: "The_Path_Of_Liberation", count: 10, language: .english, urlType: .slug, slug: "yoga-vol-9-the-path-of-liberation-series", fileTitle: "The Path Of Liberation"),
    SeriesInfo(name: "Yoga Vol 10 The Supreme Science", filePrefix: "The_Supreme_Science", count: 10, language: .english, urlType: .slug, slug: "yoga-vol-10-the-supreme-science-series", fileTitle: "The Supreme Science"),

    // Baul Mystics
    SeriesInfo(name: "The Beloved", filePrefix: "The_Beloved", count: 20, language: .english, urlType: .slug, slug: "the-beloved-series", fileTitle: "The Beloved"),

    // Kabir
    SeriesInfo(name: "The Divine Melody", filePrefix: "The_Divine_Melody", count: 10, language: .english, urlType: .slug, slug: "the-divine-melody-series", fileTitle: "The Divine Melody"),
    SeriesInfo(name: "The Guest", filePrefix: "The_Guest", count: 15, language: .english, urlType: .slug, slug: "the-guest-series", fileTitle: "The Guest"),
    SeriesInfo(name: "The Path of Love", filePrefix: "The_Path_Of_Love", count: 10, language: .english, urlType: .slug, slug: "the-path-of-love-series", fileTitle: "The Path Of Love"),
    SeriesInfo(name: "The Revolution Kabir", filePrefix: "The_Revolution", count: 10, language: .english, urlType: .slug, slug: "the-revolution-kabir-series", fileTitle: "The Revolution"),

    // Jesus
    SeriesInfo(name: "I Say Unto You", filePrefix: "I_Say_Unto_You", count: 19, language: .english, urlType: .slug, slug: "i-say-unto-you-series", fileTitle: "I Say Unto You"),
    SeriesInfo(name: "The Mustard Seed", filePrefix: "The_Mustard_Seed", count: 21, language: .english, urlType: .slug, slug: "the-mustard-seed-jesus-series", fileTitle: "The Mustard Seed"),

    // Jewish Mystics
    SeriesInfo(name: "The Art of Dying", filePrefix: "The_Art_Of_Dying", count: 10, language: .english, urlType: .slug, slug: "the-art-of-dying-series", fileTitle: "The Art Of Dying"),
    SeriesInfo(name: "The True Sage", filePrefix: "The_True_Sage", count: 10, language: .english, urlType: .slug, slug: "the-true-sage-series", fileTitle: "The True Sage"),

    // Talks in America
    SeriesInfo(name: "From Darkness to Light", filePrefix: "From_Darkness_To_Light", count: 30, language: .english, urlType: .slug, slug: "from-darkness-to-light-series", fileTitle: "From Darkness To Light"),
    SeriesInfo(name: "From Ignorance to Innocence", filePrefix: "From_Ignorance_To_Innocence", count: 30, language: .english, urlType: .slug, slug: "from-ignorance-to-innocence-series", fileTitle: "From Ignorance To Innocence"),
    SeriesInfo(name: "From Misery to Enlightenment", filePrefix: "From_Misery_To_Enlightenment", count: 30, language: .english, urlType: .slug, slug: "from-misery-to-enlightenment-series", fileTitle: "From Misery To Enlightenment"),
    SeriesInfo(name: "From Personality to Individuality", filePrefix: "From_Personality_To_Individuality", count: 30, language: .english, urlType: .slug, slug: "from-personality-to-individuality-series", fileTitle: "From Personality To Individuality"),
    SeriesInfo(name: "From Unconscious to Consciousness", filePrefix: "From_Unconscious_To_Consciousness", count: 30, language: .english, urlType: .slug, slug: "from-unconscious-to-consciousness-series", fileTitle: "From Unconscious To Consciousness"),
    SeriesInfo(name: "From the False to the Truth", filePrefix: "From_The_False_To_The_Truth", count: 34, language: .english, urlType: .slug, slug: "from-the-false-to-the-truth-series", fileTitle: "From The False To The Truth"),

    // The World Tour
    SeriesInfo(name: "Osho Upanishad", filePrefix: "Osho_Upanishad", count: 44, language: .english, urlType: .slug, slug: "osho-upanishad-series", fileTitle: "Osho Upanishad"),
    SeriesInfo(name: "Sermons in Stones", filePrefix: "Sermons_In_Stones", count: 30, language: .english, urlType: .slug, slug: "sermons-in-stones-series", fileTitle: "Sermons In Stones"),
    SeriesInfo(name: "Socrates Poisoned Again After Twenty Five Centuries", filePrefix: "Socrates_Poisoned_Again", count: 27, language: .english, urlType: .slug, slug: "socrates-poisoned-again-after-twenty-five-centuries-series", fileTitle: "Socrates Poisoned Again After Twenty Five Centuries"),
    SeriesInfo(name: "The Path of the Mystic", filePrefix: "The_Path_Of_The_Mystic", count: 44, language: .english, urlType: .slug, slug: "the-path-of-the-mystic-series", fileTitle: "The Path Of The Mystic"),
    SeriesInfo(name: "The Sword and the Lotus", filePrefix: "The_Sword_And_The_Lotus", count: 24, language: .english, urlType: .slug, slug: "the-sword-and-the-lotus-series", fileTitle: "The Sword And The Lotus"),
    SeriesInfo(name: "The Transmission of the Lamp", filePrefix: "The_Transmission_Of_The_Lamp", count: 46, language: .english, urlType: .slug, slug: "the-transmission-of-the-lamp-series", fileTitle: "The Transmission Of The Lamp"),

    // Osho's Vision for the World
    SeriesInfo(name: "Rebellious Spirit", filePrefix: "Rebellious_Spirit", count: 30, language: .english, urlType: .slug, slug: "rebellious-spirit-series", fileTitle: "Rebellious Spirit"),
    SeriesInfo(name: "The Golden Future", filePrefix: "The_Golden_Future", count: 40, language: .english, urlType: .slug, slug: "the-golden-future-series", fileTitle: "The Golden Future"),
    SeriesInfo(name: "The New Dawn", filePrefix: "The_New_Dawn", count: 33, language: .english, urlType: .slug, slug: "the-new-dawn-series", fileTitle: "The New Dawn"),
    SeriesInfo(name: "The Rebel", filePrefix: "The_Rebel", count: 35, language: .english, urlType: .slug, slug: "the-rebel-series", fileTitle: "The Rebel"),

    // The Mantra Series
    SeriesInfo(name: "Hari Om Tat Sat", filePrefix: "Hari_Om_Tat_Sat", count: 30, language: .english, urlType: .slug, slug: "hari-om-tat-sat-series", fileTitle: "Hari Om Tat Sat"),
    SeriesInfo(name: "Om Mani Padme Hum", filePrefix: "Om_Mani_Padme_Hum", count: 30, language: .english, urlType: .slug, slug: "om-mani-padme-hum-series", fileTitle: "Om Mani Padme Hum"),
    SeriesInfo(name: "Om Shantih Shantih Shantih", filePrefix: "Om_Shantih_Shantih_Shantih", count: 27, language: .english, urlType: .slug, slug: "om-shantih-shantih-shantih-series", fileTitle: "Om Shantih Shantih Shantih"),
    SeriesInfo(name: "Sat Chit Anand", filePrefix: "Sat_Chit_Anand", count: 30, language: .english, urlType: .slug, slug: "sat-chit-anand-series", fileTitle: "Sat Chit Anand"),
    SeriesInfo(name: "Satyam Shivam Sundaram", filePrefix: "Satyam_Shivam_Sundaram", count: 30, language: .english, urlType: .slug, slug: "satyam-shivam-sundaram-series", fileTitle: "Satyam Shivam Sundaram"),

    // Interview with World Press
    SeriesInfo(name: "The Last Testament Vol 1", filePrefix: "The_Last_Testament_Vol_1", count: 30, language: .english, urlType: .slug, slug: "the-last-testament-vol-1-series", fileTitle: "The Last Testament Vol 1"),
    SeriesInfo(name: "The Last Testament Vol 2", filePrefix: "The_Last_Testament_Vol_2", count: 30, language: .english, urlType: .slug, slug: "the-last-testament-vol-2-series", fileTitle: "The Last Testament Vol 2"),
    SeriesInfo(name: "The Last Testament Vol 3", filePrefix: "The_Last_Testament_Vol_3", count: 30, language: .english, urlType: .slug, slug: "the-last-testament-vol-3-series", fileTitle: "The Last Testament Vol 3"),
    SeriesInfo(name: "The Last Testament Vol 4", filePrefix: "The_Last_Testament_Vol_4", count: 27, language: .english, urlType: .slug, slug: "the-last-testament-vol-4-series", fileTitle: "The Last Testament Vol 4"),
    SeriesInfo(name: "The Last Testament Vol 5", filePrefix: "The_Last_Testament_Vol_5", count: 28, language: .english, urlType: .slug, slug: "the-last-testament-vol-5-series", fileTitle: "The Last Testament Vol 5"),
    SeriesInfo(name: "The Last Testament Vol 6", filePrefix: "The_Last_Testament_Vol_6", count: 13, language: .english, urlType: .slug, slug: "the-last-testament-vol-6-series", fileTitle: "The Last Testament Vol 6"),

    // Responses to Questions
    SeriesInfo(name: "The Goose Is Out", filePrefix: "The_Goose_Is_Out", count: 10, language: .english, urlType: .slug, slug: "the-goose-is-out-series", fileTitle: "The Goose Is Out"),
    SeriesInfo(name: "The Great Pilgrimage", filePrefix: "The_Great_Pilgrimage", count: 28, language: .english, urlType: .slug, slug: "the-great-pilgrimage-series", fileTitle: "The Great Pilgrimage"),
    SeriesInfo(name: "The Invitation", filePrefix: "The_Invitation", count: 30, language: .english, urlType: .slug, slug: "the-invitation-series", fileTitle: "The Invitation"),
    SeriesInfo(name: "The Razors Edge", filePrefix: "The_Razors_Edge", count: 30, language: .english, urlType: .slug, slug: "the-razors-edge-series", fileTitle: "The Razors Edge"),
    SeriesInfo(name: "The Wild Geese and the Water", filePrefix: "The_Wild_Geese_And_The_Water", count: 14, language: .english, urlType: .slug, slug: "the-wild-geese-and-the-water-series", fileTitle: "The Wild Geese And The Water"),
    SeriesInfo(name: "Walk Without Feet Fly Without Wings", filePrefix: "Walk_Without_Feet_Fly_Without_Wings", count: 10, language: .english, urlType: .slug, slug: "walk-without-feet-fly-without-wings-series", fileTitle: "Walk Without Feet Fly Without Wings"),
    SeriesInfo(name: "Zen Zest Zip Zap and Zing", filePrefix: "Zen_Zest_Zip_Zap_And_Zing", count: 15, language: .english, urlType: .slug, slug: "zen-zest-zip-zap-and-zing-series", fileTitle: "Zen Zest Zip Zap And Zing"),

    // Meditation
    SeriesInfo(name: "Yaa Hoo The Mystic Rose", filePrefix: "Yaa_Hoo_The_Mystic_Rose", count: 30, language: .english, urlType: .slug, slug: "yaa-hoo-the-mystic-rose-series", fileTitle: "Yaa Hoo The Mystic Rose"),
]

// MARK: - English OSHO Prefix Series

private let englishOshoPrefixSeries: [SeriesInfo] = [
    SeriesInfo(name: "Light on the Path", filePrefix: "Light_on_the_Path", count: 38, language: .english, urlType: .oshoPrefix),
]

// MARK: - Hindi Series

private let hindiSeriesList: [SeriesInfo] = [
    // Upanishad
    SeriesInfo(name: "Adhyatam Upanishad", filePrefix: "Adhyatam_Upanishad", count: 17, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Ishavashya Upanishad", filePrefix: "Ishavashya_Upanishad", count: 13, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Kaivalya Upanishad", filePrefix: "Kaivalya_Upanishad", count: 19, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Kathopanishad", filePrefix: "Kathopanishad", count: 19, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Nirvan Upanishad", filePrefix: "Nirvan_Upanishad", count: 17, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Saravsar Upanishad", filePrefix: "Saravsar_Upanishad", count: 19, language: .hindi, urlType: .oshoPrefix),

    // Krishna / Geeta Darshan
    SeriesInfo(name: "Geeta Darshan Vol 1-2", filePrefix: "Geeta_Darshan_Vol_1-2", count: 18, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Geeta Darshan Vol 3", filePrefix: "Geeta_Darshan_Vol_3", count: 10, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Geeta Darshan Vol 4", filePrefix: "Geeta_Darshan_Vol_4", count: 18, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Geeta Darshan Vol 5", filePrefix: "Geeta_Darshan_Vol_5", count: 11, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Geeta Darshan Vol 6", filePrefix: "Geeta_Darshan_Vol_6", count: 21, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Geeta Darshan Vol 7", filePrefix: "Geeta_Darshan_Vol_7", count: 10, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Geeta Darshan Vol 8", filePrefix: "Geeta_Darshan_Vol_8", count: 11, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Geeta Darshan Vol 9", filePrefix: "Geeta_Darshan_Vol_9", count: 13, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Geeta Darshan Vol 10", filePrefix: "Geeta_Darshan_Vol_10", count: 15, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Geeta Darshan Vol 11", filePrefix: "Geeta_Darshan_Vol_11", count: 12, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Geeta Darshan Vol 12", filePrefix: "Geeta_Darshan_Vol_12", count: 11, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Geeta Darshan Vol 13", filePrefix: "Geeta_Darshan_Vol_13", count: 12, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Geeta Darshan Vol 14", filePrefix: "Geeta_Darshan_Vol_14", count: 10, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Geeta Darshan Vol 15", filePrefix: "Geeta_Darshan_Vol_15", count: 7, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Geeta Darshan Vol 16", filePrefix: "Geeta_Darshan_Vol_16", count: 8, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Geeta Darshan Vol 17", filePrefix: "Geeta_Darshan_Vol_17", count: 11, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Geeta Darshan Vol 18", filePrefix: "Geeta_Darshan_Vol_18", count: 21, language: .hindi, urlType: .oshoPrefix),

    // Kabir
    SeriesInfo(name: "Kahe Kabir Diwana", filePrefix: "Kahe_Kabir_Diwana", count: 20, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Kahe Kabir Main Pura Paya", filePrefix: "Kahe_Kabir_Main_Pura_Paya", count: 20, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Suno Bhai Sadho", filePrefix: "Suno_Bhai_Sadho", count: 20, language: .hindi, urlType: .oshoPrefix),

    // Nanak
    SeriesInfo(name: "Ek Omkar Satnam", filePrefix: "Ek_Omkar_Satnam", count: 20, language: .hindi, urlType: .oshoPrefix),

    // Shiv
    SeriesInfo(name: "Shiv Sutra", filePrefix: "Shiv_Sutra", count: 10, language: .hindi, urlType: .oshoPrefix),

    // Zen Sufi
    SeriesInfo(name: "Bin Bati Bin Tel", filePrefix: "Bin_Bati_Bin_Tel", count: 19, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Diya Tale Andhera", filePrefix: "Diya_Tale_Andhera", count: 20, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Sahaj Samadhi Bhali", filePrefix: "Sahaj_Samadhi_Bhali", count: 21, language: .hindi, urlType: .oshoPrefix),

    // Dadu
    SeriesInfo(name: "Piv Piv Lagi Pyas", filePrefix: "Piv_Piv_Lagi_Pyas", count: 10, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Sabai Sayane Ek Mat", filePrefix: "Sabai_Sayane_Ek_Mat", count: 10, language: .hindi, urlType: .oshoPrefix),

    // Lao Tzu
    SeriesInfo(name: "Tao Upanishad", filePrefix: "Tao_Upanishad", count: 127, language: .hindi, urlType: .oshoPrefix),

    // Mahavir
    SeriesInfo(name: "Jin Sutra", filePrefix: "Jin_Sutra", count: 62, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Mahaveer Meri Drishti Mein", filePrefix: "Mahaveer_Meri_Drishti_Mein", count: 25, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Mahaveer Vani", filePrefix: "Mahaveer_Vani", count: 54, language: .hindi, urlType: .oshoPrefix),

    // Narad
    SeriesInfo(name: "Bhakti Sutra", filePrefix: "Bhakti_Sutra", count: 20, language: .hindi, urlType: .oshoPrefix),

    SeriesInfo(name: "Ashtavakra Maha Geeta", filePrefix: "Maha_Geeta", count: 91, language: .hindi, urlType: .oshoPrefix),

    // Gorakh
    SeriesInfo(name: "Mare He Jogi Maro", filePrefix: "Mare_He_Jogi_Maro", count: 20, language: .hindi, urlType: .oshoPrefix),

    // Sarahapa
    SeriesInfo(name: "Sahaj Yog", filePrefix: "Sahaj_Yog", count: 20, language: .hindi, urlType: .oshoPrefix),

    // Yari
    SeriesInfo(name: "Birhani Mandir Diyana Baar", filePrefix: "Birhani_Mandir_Diyana_Baar", count: 10, language: .hindi, urlType: .oshoPrefix),

    // Dariyadas
    SeriesInfo(name: "Dariya Kahe Sabad Nirvana", filePrefix: "Dariya_Kahe_Sabad_Nirvana", count: 9, language: .hindi, urlType: .oshoPrefix),

    // Laal
    SeriesInfo(name: "Hansa To Moti Chuge", filePrefix: "Hansa_To_Moti_Chuge", count: 10, language: .hindi, urlType: .oshoPrefix),

    // Bhikha
    SeriesInfo(name: "Guru Partap Sadh Ki Sangati", filePrefix: "Guru_Partap_Sadh_Ki_Sangati", count: 11, language: .hindi, urlType: .oshoPrefix),

    // Raidas
    SeriesInfo(name: "Man Hi Pooja Man Hi Dhoop", filePrefix: "Man_Hi_Pooja_Man_Hi_Dhoop", count: 10, language: .hindi, urlType: .oshoPrefix),

    // Maluuk
    SeriesInfo(name: "Ram Duware Jo Mare", filePrefix: "Ram_Duware_Jo_Mare", count: 10, language: .hindi, urlType: .oshoPrefix),

    // Gulal
    SeriesInfo(name: "Jharat Dashahun Dis Moti", filePrefix: "Jharat_Dashahun_Dis_Moti", count: 21, language: .hindi, urlType: .oshoPrefix),

    // Dayabai
    SeriesInfo(name: "Jagat Taraiya Bhor Ki", filePrefix: "Jagat_Taraiya_Bhor_Ki", count: 10, language: .hindi, urlType: .oshoPrefix),

    // Charandas
    SeriesInfo(name: "Nahin Sanjh Nahin Bhor", filePrefix: "Nahin_Sanjh_Nahin_Bhor", count: 10, language: .hindi, urlType: .oshoPrefix),

    // Dharamdas
    SeriesInfo(name: "Jas Panihar Dhare Sir Gagar", filePrefix: "Jas_Panihar_Dhare_Sir_Gagar", count: 11, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Ka Sovai Din Rain", filePrefix: "Ka_Sovai_Din_Rain", count: 11, language: .hindi, urlType: .oshoPrefix),

    // Sundardas
    SeriesInfo(name: "Hari Bolo Hari Bol", filePrefix: "Hari_Bolo_Hari_Bol", count: 10, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Jyoti Se Jyoti Jale", filePrefix: "Jyoti_Se_Jyoti_Jale", count: 21, language: .hindi, urlType: .oshoPrefix),

    // Wajid
    SeriesInfo(name: "Kahe Vajid Pukar", filePrefix: "Kahe_Vajid_Pukar", count: 10, language: .hindi, urlType: .oshoPrefix),

    // Rajab
    SeriesInfo(name: "Santo Magan Bhaya Man Mera", filePrefix: "Santo_Magan_Bhaya_Man_Mera", count: 20, language: .hindi, urlType: .oshoPrefix),

    // Jagjeevan Sahib
    SeriesInfo(name: "Ari Main To Naam Ke Rang Chhaki", filePrefix: "Ari_Main_To_Naam_Ke_Rang_Chhaki", count: 10, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Nam Sumir Man Bavre", filePrefix: "Nam_Sumir_Man_Bavre", count: 10, language: .hindi, urlType: .oshoPrefix),

    // Dulan
    SeriesInfo(name: "Prem Rang Ras Audh Chadariya", filePrefix: "Prem_Rang_Ras_Audh_Chadariya", count: 10, language: .hindi, urlType: .oshoPrefix),

    // Dariya
    SeriesInfo(name: "Ami Jharat Bigsat Kanwal", filePrefix: "Ami_Jharat_Bigsat_Kanwal", count: 14, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Kano Suni So Juth Sab", filePrefix: "Kano_Suni_So_Juth_Sab", count: 10, language: .hindi, urlType: .oshoPrefix),

    // Maluuk Das
    SeriesInfo(name: "Kan Thore Kankar Ghane", filePrefix: "Kan_Thore_Kankar_Ghane", count: 10, language: .hindi, urlType: .oshoPrefix),

    // Prashnottar (Q&A)
    SeriesInfo(name: "Anahad Mein Bisram", filePrefix: "Anahad_Mein_Bisram", count: 10, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Bahuri Na Aiso Daon", filePrefix: "Bahuri_Na_Aiso_Daon", count: 10, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Bahutere Hain Ghat", filePrefix: "Bahutere_Hain_Ghat", count: 4, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Deepak Bara Naam Ka", filePrefix: "Deepak_Bara_Naam_Ka", count: 10, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Jo Bole To Hari Katha", filePrefix: "Jo_Bole_To_Hari_Katha", count: 11, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Jyun Macchali Bin Neer", filePrefix: "Jyun_Macchali_Bin_Neer", count: 10, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Jyun Tha Tyun Thaharaya", filePrefix: "Jyun_Tha_Tyun_Thaharaya", count: 10, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Lagan Mahurat Jhooth Sab", filePrefix: "Lagan_Mahurat_Jhooth_Sab", count: 10, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Mrityoma Amritam Gamaya", filePrefix: "Mrityoma_Amritam_Gamaya", count: 10, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Nahin Ram Bin Thaon", filePrefix: "Nahin_Ram_Bin_Thaon", count: 16, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Peevat Ramras Lagi Khumari", filePrefix: "Peevat_Ramras_Lagi_Khumari", count: 10, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Piya KoKhojan Main Chali", filePrefix: "Piya_KoKhojan_Main_Chali", count: 10, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Preetam Chhabi Nainan Basee", filePrefix: "Preetam_Chhabi_Nainan_Basee", count: 16, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Prem Panth Aiso Kathin", filePrefix: "Prem_Panth_Aiso_Kathin", count: 15, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Rahiman Dhaga Prem Ka", filePrefix: "Rahiman_Dhaga_Prem_Ka", count: 12, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Ramnam Janyo Nahin", filePrefix: "Ramnam_Janyo_Nahin", count: 10, language: .hindi, urlType: .oshoPrefix),

    // Pune Discourses (General)
    SeriesInfo(name: "Asambhav Kranti", filePrefix: "Asambhav_Kranti", count: 10, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Bharat Ka Bhavishya", filePrefix: "Bharat_Ka_Bhavishya", count: 12, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Dharam Sadhana Ke Sutra", filePrefix: "Dharam_Sadhana_Ke_Sutra", count: 10, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Dhyan Sutra", filePrefix: "Dhyan_Sutra", count: 9, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Gahre Pani Paith", filePrefix: "Gahre_Pani_Paith", count: 4, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Jeevan Hi Hain Prabhu", filePrefix: "Jeevan_Hi_Hain_Prabhu", count: 7, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Jeevan Kranti Ke Sutra", filePrefix: "Jeevan_Kranti_Ke_Sutra", count: 10, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Jevan Rahasya", filePrefix: "Jevan_Rahasya", count: 13, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Jyotish", filePrefix: "Jyotish", count: 2, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Koplen Phir Phoot Aayeen", filePrefix: "Koplen_Phir_Phoot_Aayeen", count: 12, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Main Kahta Akhan Dekhi", filePrefix: "Main_Kahta_Akhan_Dekhi", count: 7, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Main Mrityu Sikhata Hun", filePrefix: "Main_Mrityu_Sikhata_Hun", count: 15, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Naye Samaj Ki Khoj", filePrefix: "Naye_Samaj_Ki_Khoj", count: 17, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Prabhu Mandir Ke Dwar Par", filePrefix: "Prabhu_Mandir_Ke_Dwar_Par", count: 10, language: .hindi, urlType: .oshoPrefix),

    // Additional verified Hindi series
    SeriesInfo(name: "Sanch Sanch So Sanch", filePrefix: "Sanch_Sanch_So_Sanch", count: 11, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Sumiran Mera Hari Kare", filePrefix: "Sumiran_Mera_Hari_Kare", count: 10, language: .hindi, urlType: .oshoPrefix),

    // From main listing page (A-series)
    SeriesInfo(name: "Agyat Ki Aur", filePrefix: "Agyat_Ki_Aur", count: 7, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Ajhun Chet Ganwar", filePrefix: "Ajhun_Chet_Ganwar", count: 21, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Amrit Dwar", filePrefix: "Amrit_Dwar", count: 6, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Amrit Ki Disha", filePrefix: "Amrit_Ki_Disha", count: 8, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Amrit Varsha", filePrefix: "Amrit_Varsha", count: 5, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Anant Ki Pukar", filePrefix: "Anant_Ki_Pukar", count: 12, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Antar Ki Khoj", filePrefix: "Antar_Ki_Khoj", count: 10, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Apne Mahin Tatol", filePrefix: "Apne_Mahin_Tatol", count: 8, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Apui Gai Hiray", filePrefix: "Apui_Gai_Hiray", count: 10, language: .hindi, urlType: .oshoPrefix),
    SeriesInfo(name: "Athato Bhakti Jigyasa", filePrefix: "Athato_Bhakti_Jigyasa", count: 40, language: .hindi, urlType: .oshoPrefix),
]
