package com.agraabhi.oshodiscourses.core.testing

import com.agraabhi.oshodiscourses.core.model.CatalogDiscourse
import com.agraabhi.oshodiscourses.core.model.CatalogEntry
import com.agraabhi.oshodiscourses.core.model.CatalogRepository
import com.agraabhi.oshodiscourses.core.model.CuratedLists
import com.agraabhi.oshodiscourses.core.model.Language
import com.agraabhi.oshodiscourses.core.model.SeriesDescription
import com.agraabhi.oshodiscourses.core.model.SeriesInfo
import com.agraabhi.oshodiscourses.core.model.URLType

/** Two real series, trimmed to a few discourses, for previews, screenshots and tests. */
object SampleCatalog {
    val birdOnTheWing = SeriesInfo(
        name = "A Bird on the Wing",
        filePrefix = "A_Bird_on_the_Wing__",
        count = 3,
        language = Language.ENGLISH,
        urlType = URLType.UNDERSCORE,
        folderName = "A_Bird_on_the_Wing",
    )

    val mahaGeeta = SeriesInfo(
        name = "Ashtavakra Maha Geeta",
        filePrefix = "Maha_Geeta",
        count = 2,
        language = Language.HINDI,
        urlType = URLType.OSHO_PREFIX,
    )

    val allSeries: List<SeriesInfo> = listOf(birdOnTheWing, mahaGeeta)

    val descriptions: Map<String, SeriesDescription> = mapOf(
        birdOnTheWing.name to SeriesDescription(
            sourceText = "Eleven Zen stories. Each one is a koan that refuses to make rational sense, and that's the point: awakening comes as a jolt, not a conclusion.",
            year = "1974",
            location = "Mumbai",
            themes = listOf("Zen", "koans", "stories", "awakening", "paradox", "beginner friendly"),
        ),
        mahaGeeta.name to SeriesDescription(
            sourceText = "The Ashtavakra Gita (Ashtavakra Samhita), a dialogue between the sage Ashtavakra and King Janaka about the Self, reality, and liberation. Possibly the most direct Advaita teaching there is.",
            year = "1976",
            location = "Pune",
            themes = listOf("Ashtavakra", "Advaita", "self-realization", "Janaka", "liberation", "non-duality"),
        ),
    )

    fun discourses(series: SeriesInfo): List<CatalogDiscourse> = (1..series.count).map { number ->
        CatalogDiscourse(
            id = "${series.id}-$number",
            seriesName = series.name,
            number = number,
            audioURL = "https://example.invalid/${series.filePrefix}_$number.mp3",
            language = series.language,
        )
    }

    /** `english-A_Bird_on_the_Wing__-1`, which also has a transcript in the shipped catalog. */
    val firstDiscourse: CatalogDiscourse get() = discourses(birdOnTheWing).first()

    val hindiDiscourse: CatalogDiscourse get() = discourses(mahaGeeta).first()
}

class FakeCatalogRepository(
    override val allSeries: List<SeriesInfo> = SampleCatalog.allSeries,
    private val descriptions: Map<String, SeriesDescription> = SampleCatalog.descriptions,
    private val transcriptIDs: Set<String> = setOf(SampleCatalog.firstDiscourse.id),
) : CatalogRepository {
    private val bySeries = allSeries.associate { it.id to SampleCatalog.discourses(it) }
    private val lookup = allSeries.flatMap { s -> bySeries.getValue(s.id).map { it.id to CatalogEntry(it, s) } }.toMap()

    override val curated: CuratedLists = CuratedLists(
        popularEnglish = englishSeries,
        beginnerEnglish = englishSeries,
        popularHindi = hindiSeries,
        beginnerHindi = hindiSeries,
    )

    override fun series(id: String): SeriesInfo? = allSeries.firstOrNull { it.id == id }

    override fun discourses(series: SeriesInfo): List<CatalogDiscourse> = bySeries[series.id].orEmpty()

    override fun entry(discourseID: String): CatalogEntry? = lookup[discourseID]

    override fun description(seriesName: String): SeriesDescription? = descriptions[seriesName]

    override fun searchText(seriesName: String): String {
        val d = descriptions[seriesName] ?: return seriesName.lowercase()
        return "$seriesName ${d.sourceText} ${d.themes.joinToString(" ")}".lowercase()
    }

    override fun discourseSubtitle(number: Int, seriesName: String): String {
        val label = "Discourse $number"
        val d = descriptions[seriesName] ?: return label
        val origin = listOfNotNull(d.location, d.year).filter { it.isNotEmpty() }.joinToString(", ")
        return if (origin.isEmpty()) label else "$label · $origin"
    }

    override fun coverURL(seriesID: String): String? = null

    override fun archiveAudioURL(discourse: CatalogDiscourse): String? = null

    override fun hasTranscript(discourseID: String): Boolean = discourseID in transcriptIDs

    override fun transcriptCount(seriesID: String): Int = transcriptIDs.count { it.startsWith("$seriesID-") }
}
