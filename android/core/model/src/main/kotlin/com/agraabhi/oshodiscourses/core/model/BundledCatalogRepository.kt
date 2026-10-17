package com.agraabhi.oshodiscourses.core.model

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** The curated Home lists by series name, as authored in iOS `Catalog.popularEnglishNames` and friends. */
@Serializable
data class CuratedSeriesNames(
    val popularEnglish: List<String>,
    val beginnerEnglish: List<String>,
    val popularHindi: List<String>,
    val beginnerHindi: List<String>,
)

/**
 * [CatalogRepository] over the shipped resources: `catalog/catalog.json` (exported from the iOS
 * Swift sources by `android/scripts/export-catalog.sh`) plus the iOS Oshoworld, Archive and
 * Transcript catalogs. Each part parses on first use; call [warmUp] off the main thread at launch.
 */
class BundledCatalogRepository(
    private val opener: ResourceOpener = ResourceOpener.classpath,
) : CatalogRepository {
    private val core: Core by lazy { Core.load(opener) }
    private val archive: ArchiveCatalog by lazy { ArchiveCatalog.load(opener) }
    private val transcriptCounts: TranscriptIndex by lazy { TranscriptIndex.load(opener) }

    /** Parses everything now so later lookups never block; blocking, so never call it on the main thread. */
    fun warmUp() {
        core
        archive
        transcriptCounts
    }

    val oshoworld: OshoworldCatalog get() = core.oshoworld

    val archiveCatalog: ArchiveCatalog get() = archive

    val curatedNames: CuratedSeriesNames get() = core.curatedNames

    override val allSeries: List<SeriesInfo> get() = core.allSeries

    override val englishSeries: List<SeriesInfo> get() = core.englishSeries

    override val hindiSeries: List<SeriesInfo> get() = core.hindiSeries

    override val curated: CuratedLists get() = core.curated

    override fun series(id: String): SeriesInfo? = core.seriesByID[id]

    override fun discourses(series: SeriesInfo): List<CatalogDiscourse> = core.discoursesBySeriesID[series.id].orEmpty()

    override fun allDiscourses(): List<CatalogDiscourse> = core.allDiscourses

    override fun entry(discourseID: String): CatalogEntry? = core.lookup[discourseID]

    override fun description(seriesName: String): SeriesDescription? = core.descriptions[seriesName]

    /** Name, description and themes in their original case (iOS `SeriesMetadata.searchableText`). */
    fun searchableText(seriesName: String): String {
        val d = core.descriptions[seriesName] ?: return seriesName
        return "$seriesName ${d.sourceText} ${d.themes.joinToString(" ")}"
    }

    override fun searchText(seriesName: String): String =
        core.searchCorpus[seriesName] ?: seriesName.lowercase()

    // Most series have no origin, and either half may be missing alone; blanks never leave a stray separator.
    override fun discourseSubtitle(number: Int, seriesName: String): String {
        val label = "Discourse $number"
        val d = core.descriptions[seriesName] ?: return label
        val origin = listOfNotNull(d.location, d.year).filter { it.isNotEmpty() }.joinToString(", ")
        return if (origin.isEmpty()) label else "$label · $origin"
    }

    override fun coverURL(seriesID: String): String? = archive.coverURL(seriesID)

    override fun archiveAudioURL(discourse: CatalogDiscourse): String? = archive.audioURL(discourse)

    override fun hasTranscript(discourseID: String): Boolean = discourseID in transcriptCounts.ids

    override fun transcriptCount(seriesID: String): Int = transcriptCounts.countsBySeries[seriesID] ?: 0

    private class Core(
        val allSeries: List<SeriesInfo>,
        val curatedNames: CuratedSeriesNames,
        val descriptions: Map<String, SeriesDescription>,
        val oshoworld: OshoworldCatalog,
    ) {
        val englishSeries = allSeries.filter { it.language == Language.ENGLISH }
        val hindiSeries = allSeries.filter { it.language == Language.HINDI }
        val seriesByID: Map<String, SeriesInfo> = allSeries.associateBy { it.id }

        val discoursesBySeriesID: Map<String, List<CatalogDiscourse>> = HashMap<String, List<CatalogDiscourse>>(allSeries.size * 2).also { map ->
            for (series in allSeries) {
                map[series.id] = (1..series.count).map { number ->
                    CatalogDiscourse(
                        id = "${series.id}-$number",
                        seriesName = series.name,
                        number = number,
                        audioURL = buildAudioURL(series, number, oshoworld),
                        language = series.language,
                    )
                }
            }
        }

        val allDiscourses: List<CatalogDiscourse> = allSeries.flatMap { discoursesBySeriesID.getValue(it.id) }

        val lookup: Map<String, CatalogEntry> = HashMap<String, CatalogEntry>(allDiscourses.size * 2).also { map ->
            for (series in allSeries) {
                for (discourse in discoursesBySeriesID.getValue(series.id)) map[discourse.id] = CatalogEntry(discourse, series)
            }
        }

        // A misspelt name drops out of its Home section; tests pin resolved count == name count.
        val curated = CuratedLists(
            popularEnglish = resolve(curatedNames.popularEnglish),
            beginnerEnglish = resolve(curatedNames.beginnerEnglish),
            popularHindi = resolve(curatedNames.popularHindi),
            beginnerHindi = resolve(curatedNames.beginnerHindi),
        )

        // Library search runs on every keystroke, so the lowercased corpus is built once.
        val searchCorpus: Map<String, String> = allSeries.associate { series ->
            val d = descriptions[series.name]
            val text = if (d == null) series.name else "${series.name} ${d.sourceText} ${d.themes.joinToString(" ")}"
            series.name to text.lowercase()
        }

        private fun resolve(names: List<String>): List<SeriesInfo> =
            names.mapNotNull { name -> allSeries.firstOrNull { it.name == name } }

        companion object {
            fun load(opener: ResourceOpener): Core {
                val text = checkNotNull(opener.readText(CATALOG_RESOURCE)) {
                    "$CATALOG_RESOURCE is missing; run android/scripts/export-catalog.sh"
                }
                val file = json.decodeFromString<CatalogFile>(text)
                return Core(
                    allSeries = file.series,
                    curatedNames = file.curated,
                    descriptions = file.descriptions.mapValues { (_, d) ->
                        SeriesDescription(sourceText = d.sourceText, year = d.year, location = d.location, themes = d.themes)
                    },
                    oshoworld = OshoworldCatalog.load(opener),
                )
            }
        }
    }

    /** Only which discourses have a transcript; the transcript module reads the entries themselves. */
    private class TranscriptIndex(val ids: Set<String>) {
        // Discourse numbers never contain a hyphen, so the series id is everything before the last one.
        val countsBySeries: Map<String, Int> = ids.groupingBy { it.substringBeforeLast('-') }.eachCount()

        companion object {
            fun load(opener: ResourceOpener): TranscriptIndex {
                val text = opener.readText(TRANSCRIPT_RESOURCE) ?: return TranscriptIndex(emptySet())
                val keys = runCatching { json.decodeFromString<Map<String, Present>>(text).keys }.getOrDefault(emptySet())
                return TranscriptIndex(keys)
            }
        }
    }

    @Serializable
    private class CatalogFile(
        val series: List<SeriesInfo>,
        val curated: CuratedSeriesNames,
        val descriptions: Map<String, DescriptionFile>,
    )

    @Serializable
    private class DescriptionFile(
        val sourceText: String,
        val year: String? = null,
        val location: String? = null,
        val themes: List<String>,
    )

    /** Decodes a JSON object while skipping every field. */
    @Serializable
    private class Present

    companion object {
        const val CATALOG_RESOURCE = "catalog/catalog.json"
        const val TRANSCRIPT_RESOURCE = "TranscriptCatalog.json"

        private val json = Json { ignoreUnknownKeys = true }
    }
}
