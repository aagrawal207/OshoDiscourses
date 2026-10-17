package com.agraabhi.oshodiscourses.core.model

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

private const val ENGLISH_NEW_AUDIO_BASE = "https://www.oshoworld.com/wp-content/uploads/newAudios"
private const val ENGLISH_OSHO_BASE = "https://www.oshoworld.com/wp-content/uploads/2020/11/English Audio"
private const val HINDI_BASE = "https://www.oshoworld.com/wp-content/uploads/2020/11/Hindi Audio"

/**
 * The oshoworld.com audio URL for a discourse (iOS `buildAudioURL`). URLs keep literal spaces;
 * encode them with [URLEncoding.requestURL] at request time.
 */
fun buildAudioURL(series: SeriesInfo, discourseNumber: Int, oshoworld: OshoworldCatalog): String {
    // The site renamed files inside many upload folders after the patterns were written.
    oshoworld.path(series.id, discourseNumber)?.let { return OshoworldCatalog.HOST + it }
    return patternAudioURL(series, discourseNumber)
}

/** The URL the series' naming pattern predicts, ignoring the crawled overrides. Empty when none fits. */
fun patternAudioURL(series: SeriesInfo, discourseNumber: Int): String {
    val num = discourseNumber.toString().padStart(if (series.count >= 100) 3 else 2, '0')
    return when (series.urlType) {
        URLType.UNDERSCORE -> {
            val baseName = series.folderName ?: series.filePrefix.trimEnd('_', '-')
            val folder = "${baseName}_(${series.count})"
            val separator = if (series.filePrefix.endsWith("_") || series.filePrefix.endsWith("-")) "" else "_"
            "$ENGLISH_NEW_AUDIO_BASE/$folder/${series.filePrefix}$separator$num.mp3"
        }
        URLType.SLUG -> {
            val slug = series.slug
            val fileTitle = series.fileTitle
            if (slug == null || fileTitle == null) "" else "$ENGLISH_NEW_AUDIO_BASE/$slug/$fileTitle $num.mp3"
        }
        URLType.OSHO_PREFIX -> {
            val base = if (series.language == Language.HINDI) HINDI_BASE else ENGLISH_OSHO_BASE
            "$base/OSHO-${series.filePrefix}_$num.mp3"
        }
        URLType.CATALOG -> ""
    }
}

/**
 * oshoworld.com mp3 paths for discourses the naming patterns get wrong (iOS `OshoworldCatalog`),
 * from `OshoworldCatalog.json`. Paths are un-encoded and relative to [HOST].
 */
class OshoworldCatalog(private val overrides: Map<String, String>) {
    fun path(seriesID: String, number: Int): String? = overrides["$seriesID-$number"]

    val overrideCount: Int get() = overrides.size

    companion object {
        const val HOST = "https://www.oshoworld.com"
        const val RESOURCE = "OshoworldCatalog.json"

        /** Missing or unreadable JSON leaves pattern URLs only, as on iOS. */
        fun load(opener: ResourceOpener = ResourceOpener.classpath): OshoworldCatalog {
            val text = opener.readText(RESOURCE) ?: return OshoworldCatalog(emptyMap())
            return OshoworldCatalog(runCatching { Json.decodeFromString<Map<String, String>>(text) }.getOrDefault(emptyMap()))
        }
    }
}

/**
 * Maps discourses to the archive.org item `osho-audio-discourses-collection` (iOS
 * `ArchiveCatalog`), about 12x faster than oshoworld.com. Also provides series cover art.
 * URLs use the stable `archive.org/download/...` form, never an ephemeral datanode host.
 */
class ArchiveCatalog(private val entries: Map<String, SeriesEntry>) {
    @Serializable
    data class SeriesEntry(
        /** Series folder inside the item, e.g. "OSHO_WORLD/Hindi/100-Maha Geeta 01-91 – Osho World". */
        val folder: String,
        /** Discourse number as a string -> filename. Sparse: only verified files. */
        val files: Map<String, String>,
        /** First track's extracted PNG, used as the series cover. */
        val cover: String? = null,
    )

    fun audioURL(discourse: CatalogDiscourse): String? {
        val entry = entries[discourse.seriesID] ?: return null
        val file = entry.files[discourse.number.toString()] ?: return null
        return buildURL("${entry.folder}/$file")
    }

    fun coverURL(seriesID: String): String? {
        val entry = entries[seriesID] ?: return null
        val cover = entry.cover ?: return null
        return buildURL("${entry.folder}/$cover")
    }

    fun mappedCount(seriesID: String): Int = entries[seriesID]?.files?.size ?: 0

    val mappedSeriesCount: Int get() = entries.size

    val mappedDiscourseCount: Int get() = entries.values.sumOf { it.files.size }

    // Folder names carry spaces, en dashes and '&'.
    private fun buildURL(path: String): String = "$ITEM_BASE/${URLEncoding.encodePath(path)}"

    companion object {
        const val ITEM_BASE = "https://archive.org/download/osho-audio-discourses-collection"
        const val RESOURCE = "ArchiveCatalog.json"

        private val json = Json { ignoreUnknownKeys = true }

        /** Missing or unreadable JSON disables archive downloads and covers, as on iOS. */
        fun load(opener: ResourceOpener = ResourceOpener.classpath): ArchiveCatalog {
            val text = opener.readText(RESOURCE) ?: return ArchiveCatalog(emptyMap())
            return ArchiveCatalog(
                runCatching { json.decodeFromString<Map<String, SeriesEntry>>(text) }.getOrDefault(emptyMap()),
            )
        }
    }
}
