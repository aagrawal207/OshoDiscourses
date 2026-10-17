package com.agraabhi.oshodiscourses.core.model

/**
 * The static catalog: 351 series and 5,481 discourses, plus shipped mirrors and metadata.
 * Mirrors iOS `Catalog`, `SeriesMetadata`, `ArchiveCatalog` and `TranscriptCatalog` lookups.
 * Everything is immutable after load, so implementations may cache freely.
 */
interface CatalogRepository {
    /** Every series in catalog order (English underscore, slug, OSHO-prefix, then Hindi). */
    val allSeries: List<SeriesInfo>

    val englishSeries: List<SeriesInfo> get() = allSeries.filter { it.language == Language.ENGLISH }

    val hindiSeries: List<SeriesInfo> get() = allSeries.filter { it.language == Language.HINDI }

    val curated: CuratedLists

    fun series(id: String): SeriesInfo?

    /** Discourses of [series] numbered 1 through `series.count`. */
    fun discourses(series: SeriesInfo): List<CatalogDiscourse>

    fun allDiscourses(): List<CatalogDiscourse> = allSeries.flatMap { discourses(it) }

    /** Discourse and series for a discourse id, or null if the catalog no longer has it. */
    fun entry(discourseID: String): CatalogEntry?

    fun discourse(discourseID: String): CatalogDiscourse? = entry(discourseID)?.discourse

    fun description(seriesName: String): SeriesDescription?

    fun themes(seriesName: String): List<String> = description(seriesName)?.themes.orEmpty()

    /** Pre-lowercased name + description + themes, for Library search. */
    fun searchText(seriesName: String): String

    /** Player subtitle, e.g. "Discourse 1 · Pune, 1976"; the origin is dropped when unknown. */
    fun discourseSubtitle(number: Int, seriesName: String): String

    /** archive.org cover art for a series, or null when the mirror has none. */
    fun coverURL(seriesID: String): String?

    /** archive.org mirror URL for a discourse, or null when unmapped. */
    fun archiveAudioURL(discourse: CatalogDiscourse): String?

    /** Whether oshoworld.com has a real transcript for this discourse (TranscriptCatalog.json). */
    fun hasTranscript(discourseID: String): Boolean

    /** Number of discourses in a series that have a transcript, for the series-row indicator. */
    fun transcriptCount(seriesID: String): Int
}
