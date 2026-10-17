package com.agraabhi.oshodiscourses.core.model

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class TranscriptCatalogTest {
    private val shipped = TranscriptCatalog.loadShipped()

    @Test
    fun mappingCoversMostOfTheCatalog() {
        assertThat(shipped.mappedDiscourseCount).isAtLeast(4_800)
        assertThat(shipped.mappedSeriesCount).isAtLeast(300)
    }

    @Test
    fun knownDiscoursesResolveToTheirOshoworldPages() {
        val hindi = checkNotNull(shipped.entry("hindi-Maha_Geeta-1"))
        assertThat(hindi.slug).isEqualTo("ashtavakra-maha-geeta-01")
        assertThat(hindi.id).isEqualTo("66265929d26d4da463e8850d")
        assertThat(TranscriptCatalog.descriptionURL(hindi)).isEqualTo("https://oshoworld.com/api/server/audio/get-description/${hindi.id}")
        assertThat(TranscriptCatalog.pageURL(hindi)).isEqualTo("https://oshoworld.com/ashtavakra-maha-geeta-01")
        assertThat(shipped.transcriptCount("hindi-Maha_Geeta")).isAtLeast(80)

        val english = checkNotNull(shipped.entry("english-A_Bird_on_the_Wing__-1"))
        assertThat(english.slug).isEqualTo("a-bird-on-the-wing-01")
        assertThat(shipped.transcriptCount("english-A_Bird_on_the_Wing__")).isEqualTo(11)
    }

    @Test
    fun unknownDiscoursesHaveNoTranscript() {
        assertThat(shipped.hasTranscript("nope-1")).isFalse()
        assertThat(shipped.entry("nope-1")).isNull()
        assertThat(shipped.transcriptCount("nope")).isEqualTo(0)
    }

    @Test
    fun everyEntryHasAnIdAndSlugAndAPrefixedDiscourseID() {
        for (id in shipped.discourseIDs) {
            val entry = checkNotNull(shipped.entry(id))
            assertThat(entry.id).matches("[0-9a-f]{24}")
            assertThat(entry.slug).isNotEmpty()
            assertThat(id).matches("(english|hindi)-.+-[0-9]+")
        }
    }

    @Test
    fun seriesCountsSplitOnTheLastHyphen() {
        val catalog = TranscriptCatalog(
            mapOf(
                "english-Zen-The_Path-1" to TranscriptCatalog.Entry("a", "zen-1"),
                "english-Zen-The_Path-2" to TranscriptCatalog.Entry("b", "zen-2"),
                "hindi-Geeta_Darshan_Vol_7-8" to TranscriptCatalog.Entry("c", "gd-8"),
            ),
        )
        assertThat(catalog.transcriptCount("english-Zen-The_Path")).isEqualTo(2)
        assertThat(catalog.transcriptCount("hindi-Geeta_Darshan_Vol_7")).isEqualTo(1)
        assertThat(catalog.mappedSeriesCount).isEqualTo(2)
    }

    @Test
    fun malformedJsonFailsToDecode() {
        assertThat(runCatching { TranscriptCatalog.decode("[]") }.isFailure).isTrue()
    }
}
