package com.agraabhi.oshodiscourses.transcript

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class AlignmentCatalogTest {
    @Test
    fun wireFormatRoundTripsWithGapsAndTenths() {
        val entry = AlignmentCatalog.Entry(paragraphCount = 5, duration = 5125.04, starts = listOf(0.0, null, 12.34, 12.4, null))
        val encoded = AlignmentCatalog.encode(entry)
        assertThat(encoded).isEqualTo("5;51250;0,-,123,1,-")
        val decoded = checkNotNull(AlignmentCatalog.decode(encoded))
        assertThat(decoded.paragraphCount).isEqualTo(5)
        assertThat(decoded.duration).isEqualTo(5125.0)
        assertThat(decoded.starts).containsExactly(0.0, null, 12.3, 12.4, null).inOrder()
        assertThat(decoded.matchedCount).isEqualTo(3)
    }

    @Test
    fun malformedStringsDecodeToNull() {
        assertThat(AlignmentCatalog.decode("")).isNull()
        assertThat(AlignmentCatalog.decode("3;100;0,5")).isNull() // count mismatch
        assertThat(AlignmentCatalog.decode("2;100;0,x")).isNull() // bad token
        assertThat(AlignmentCatalog.decode("2;1.5;0,1")).isNull() // duration not in tenths
        assertThat(AlignmentCatalog.decode("1;100;0;9")).isNull() // extra field
        assertThat(AlignmentCatalog.decode("0;100;")).isNotNull() // an empty transcript is still valid
    }

    @Test
    fun entryAppliesOnlyToTheSameSplitAndRecording() {
        val entry = AlignmentCatalog.Entry(paragraphCount = 3, duration = 600.0, starts = listOf(0.0, 200.0, 400.0))
        assertThat(entry.matches(paragraphCount = 3, duration = 601.5)).isTrue()
        assertThat(entry.matches(paragraphCount = 3, duration = 597.5)).isTrue()
        assertThat(entry.matches(paragraphCount = 4, duration = 600.0)).isFalse()
        assertThat(entry.matches(paragraphCount = 3, duration = 610.0)).isFalse()
        assertThat(entry.matches(paragraphCount = 3, duration = 602.6)).isFalse()
    }

    @Test
    fun knownEntryDecodesToItsRecording() {
        val shipped = AlignmentCatalog.loadShipped()
        val bird = checkNotNull(shipped.entry("english-A_Bird_on_the_Wing__-1"))
        assertThat(bird.paragraphCount).isEqualTo(93)
        assertThat(bird.duration).isEqualTo(5901.8)
        assertThat(bird.starts[0]).isNull()
        assertThat(bird.starts[1]).isEqualTo(55.1)
        assertThat(bird.starts[2]).isWithin(1e-9).of(153.6)
        assertThat(shipped.hasAlignment("nope-1")).isFalse()
        assertThat(shipped.entry("nope-1")).isNull()
    }

    @Test
    fun bundledCatalogEntriesDecodeAndPointAtTranscripts() {
        val shipped = AlignmentCatalog.loadShipped()
        val transcripts = TranscriptCatalog.loadShipped()
        assertThat(shipped.count).isAtLeast(4_800)
        for (id in shipped.discourseIDs) {
            val entry = checkNotNull(shipped.entry(id)) { id }
            assertThat(transcripts.hasTranscript(id)).isTrue()
            assertThat(entry.paragraphCount).isGreaterThan(0)
            assertThat(entry.matchedCount).isGreaterThan(0)
            assertThat(entry.duration.isFinite() && entry.duration > 0).isTrue()
            assertThat(entry.starts.filterNotNull().all { it.isFinite() && it >= 0 && it <= entry.duration }).isTrue()
        }
    }
}
