package com.agraabhi.oshodiscourses.feature.downloads

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import java.time.LocalDate
import java.util.Locale

class FormatsTest {
    @Test
    fun bytesMatchByteCountFormatterFileStyle() {
        assertThat(Formats.bytes(0)).isEqualTo("Zero KB")
        assertThat(Formats.bytes(1)).isEqualTo("1 byte")
        assertThat(Formats.bytes(999)).isEqualTo("999 bytes")
        assertThat(Formats.bytes(1_000)).isEqualTo("1 KB")
        assertThat(Formats.bytes(512_400)).isEqualTo("512 KB")
        assertThat(Formats.bytes(999_600)).isEqualTo("1 MB")
        assertThat(Formats.bytes(28_000_000)).isEqualTo("28 MB")
        assertThat(Formats.bytes(36_460_000)).isEqualTo("36.5 MB")
        assertThat(Formats.bytes(98_800_000)).isEqualTo("98.8 MB")
        assertThat(Formats.bytes(1_230_000_000)).isEqualTo("1.23 GB")
        assertThat(Formats.bytes(2_000_000_000)).isEqualTo("2 GB")
    }

    @Test
    fun durationsMatchTheSwiftFormatters() {
        assertThat(Formats.shortDuration(0.0)).isEqualTo("<1m")
        assertThat(Formats.shortDuration(59.0)).isEqualTo("<1m")
        assertThat(Formats.shortDuration(17 * 60.0)).isEqualTo("17m")
        assertThat(Formats.shortDuration(18 * 3600.0 + 55 * 60)).isEqualTo("18h 55m")
        assertThat(Formats.periodDuration(0.0)).isEqualTo("—")
        assertThat(Formats.periodDuration(30.0)).isEqualTo("<1 min")
        assertThat(Formats.periodDuration(17 * 60.0)).isEqualTo("17 min")
        assertThat(Formats.periodDuration(2 * 3600.0 + 54 * 60)).isEqualTo("2h 54m")
        assertThat(Formats.listenedSubtitle(0.0)).isEqualTo("Start listening to track time")
        assertThat(Formats.listenedSubtitle(7 * 60.0)).isEqualTo("7m listened")
        assertThat(Formats.listenedSubtitle(16 * 3600.0 + 7 * 60)).isEqualTo("16h 7m listened")
    }

    @Test
    fun dayLabelsUseTodayYesterdayThenShortDates() {
        val today = LocalDate.of(2026, 7, 31)
        assertThat(Formats.dayLabel("2026-07-31", today, Locale.US)).isEqualTo("Today")
        assertThat(Formats.dayLabel("2026-07-30", today, Locale.US)).isEqualTo("Yesterday")
        assertThat(Formats.dayLabel("2026-07-29", today, Locale.US)).isEqualTo("Wed, Jul 29")
        assertThat(Formats.dayLabel("not a date", today, Locale.US)).isEqualTo("not a date")
    }
}
