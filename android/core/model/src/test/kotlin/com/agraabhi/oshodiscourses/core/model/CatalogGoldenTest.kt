package com.agraabhi.oshodiscourses.core.model

import com.google.common.truth.Truth.assertThat
import com.google.common.truth.Truth.assertWithMessage
import kotlin.test.assertNotNull
import org.junit.Test

/**
 * Checks every discourse and series against values the iOS Swift code computed
 * (`android/scripts/export-catalog.sh`). "-" in a golden cell means none.
 */
class CatalogGoldenTest {
    private val catalog = CatalogTest.shared

    private fun golden(name: String): List<Map<String, String?>> {
        val stream = checkNotNull(javaClass.getResourceAsStream("/catalog/$name")) { "$name golden file missing" }
        val lines = stream.bufferedReader().readLines().filter { it.isNotEmpty() }
        val header = lines.first().split('\t')
        return lines.drop(1).map { line ->
            val cells = line.split('\t')
            check(cells.size == header.size) { "malformed golden line: $line" }
            header.zip(cells.map { if (it == "-") null else it }).toMap()
        }
    }

    @Test
    fun everyDiscourseMatchesSwiftURLs() {
        val rows = golden("discourses.tsv")
        assertThat(rows).hasSize(5_481)
        assertThat(catalog.allDiscourses().map { it.id }).containsExactlyElementsIn(rows.map { it["id"] }).inOrder()
        for (row in rows) {
            val id = row.getValue("id")!!
            val entry = assertNotNull(catalog.entry(id), id)
            val discourse = entry.discourse
            assertWithMessage(id).that(discourse.number.toString()).isEqualTo(row["number"])
            assertWithMessage("$id pattern").that(patternAudioURL(entry.series, discourse.number).ifEmpty { null })
                .isEqualTo(row["patternURL"])
            assertWithMessage("$id audio").that(discourse.audioURL).isEqualTo(row["audioURL"])
            assertWithMessage("$id request").that(URLEncoding.requestURL(discourse.audioURL)).isEqualTo(row["encodedAudioURL"])
            assertWithMessage("$id archive").that(catalog.archiveAudioURL(discourse)).isEqualTo(row["archiveURL"])
        }
    }

    @Test
    fun everySeriesMatchesSwiftMetadata() {
        val rows = golden("series.tsv")
        assertThat(rows).hasSize(351)
        assertThat(catalog.allSeries.map { it.id }).containsExactlyElementsIn(rows.map { it["id"] }).inOrder()
        for (row in rows) {
            val id = row.getValue("id")!!
            val series = assertNotNull(catalog.series(id), id)
            assertWithMessage(id).that(series.language.rawValue).isEqualTo(row["language"])
            assertWithMessage(id).that(series.count.toString()).isEqualTo(row["count"])
            assertWithMessage("$id transcripts").that(catalog.transcriptCount(id).toString()).isEqualTo(row["transcripts"])
            assertWithMessage("$id cover").that(catalog.coverURL(id)).isEqualTo(row["coverURL"])
            assertWithMessage("$id subtitle").that(catalog.discourseSubtitle(3, series.name)).isEqualTo(row["subtitle3"])
            assertWithMessage("$id search").that(catalog.searchText(series.name)).isEqualTo(row["searchText"])
        }
    }

    @Test
    fun themeChipLabelsMatchFoundationCapitalized() {
        val rows = golden("themes.tsv")
        assertThat(rows).isNotEmpty()
        for (row in rows) {
            val theme = row.getValue("theme")!!
            assertWithMessage(theme).that(SeriesFilter.Theme(theme).label).isEqualTo(row["label"])
        }
    }
}
