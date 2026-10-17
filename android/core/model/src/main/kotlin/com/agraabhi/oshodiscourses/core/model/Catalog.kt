package com.agraabhi.oshodiscourses.core.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Mirrors iOS `SeriesInfo.Language`; [rawValue] prefixes every series and discourse id. */
@Serializable
enum class Language(val rawValue: String) {
    @SerialName("hindi") HINDI("hindi"),
    @SerialName("english") ENGLISH("english"),
    ;

    companion object {
        fun fromRawValue(value: String): Language? = entries.firstOrNull { it.rawValue == value }
    }
}

/** Which oshoworld.com naming pattern builds a series' audio URLs (iOS `SeriesInfo.URLType`). */
@Serializable
enum class URLType(val rawValue: String) {
    @SerialName("underscore") UNDERSCORE("underscore"),
    @SerialName("slug") SLUG("slug"),
    @SerialName("osho-prefix") OSHO_PREFIX("osho-prefix"),

    /** No naming pattern fits; every path comes from OshoworldCatalog.json. */
    @SerialName("catalog") CATALOG("catalog"),
}

/** One series of discourses (iOS `SeriesInfo`). */
@Serializable
data class SeriesInfo(
    val name: String,
    val filePrefix: String,
    val count: Int,
    val language: Language,
    val urlType: URLType,
    val slug: String? = null,
    val fileTitle: String? = null,
    val folderName: String? = null,
) {
    /** Stable identity, e.g. `english-A_Bird_on_the_Wing__`. Persisted state keys off it. */
    val id: String get() = "${language.rawValue}-$filePrefix"
}

/** One discourse with its built oshoworld URL (iOS `CatalogDiscourse`). */
@Serializable
data class CatalogDiscourse(
    /** `<series id>-<number>`, e.g. `english-A_Bird_on_the_Wing__-1`. */
    val id: String,
    val seriesName: String,
    val number: Int,
    val audioURL: String,
    val language: Language,
) {
    val displayTitle: String get() = "$seriesName - #$number"

    /** The owning series id. Series ids contain hyphens, so the "-<number>" suffix is cut by length. */
    val seriesID: String get() = id.dropLast(number.toString().length + 1)
}

/** A discourse together with the series that owns it (iOS `Catalog.discourseLookup` value). */
data class CatalogEntry(
    val discourse: CatalogDiscourse,
    val series: SeriesInfo,
)

/** Editorial description of a series (iOS `SeriesDescription`). */
data class SeriesDescription(
    val sourceText: String,
    val year: String?,
    val location: String?,
    val themes: List<String>,
)

/** The four curated Home lists, resolved to series (iOS `Catalog.popularEnglish` and friends). */
data class CuratedLists(
    val popularEnglish: List<SeriesInfo>,
    val beginnerEnglish: List<SeriesInfo>,
    val popularHindi: List<SeriesInfo>,
    val beginnerHindi: List<SeriesInfo>,
)
