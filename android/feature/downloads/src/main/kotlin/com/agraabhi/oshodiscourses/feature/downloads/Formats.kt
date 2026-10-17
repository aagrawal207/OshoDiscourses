package com.agraabhi.oshodiscourses.feature.downloads

import java.math.BigDecimal
import java.math.RoundingMode
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeParseException
import java.util.Locale

/** Number and date formatting shared by the Downloads, Stats and History screens. */
internal object Formats {
    private val units = listOf("KB", "MB", "GB", "TB")

    /**
     * `ByteCountFormatter` with `.file`: base 1000; KB whole, MB one decimal, GB and up two;
     * trailing zeros dropped. Android's `Formatter` rounds and pads differently.
     */
    fun bytes(count: Long): String {
        if (count == 0L) return "Zero KB"
        if (count < 1000) return if (count == 1L) "1 byte" else "$count bytes"
        var value = count.toDouble() / 1000
        var unit = 0
        while (true) {
            val decimals = when (unit) {
                0 -> 0
                1 -> 1
                else -> 2
            }
            val rounded = BigDecimal.valueOf(value).setScale(decimals, RoundingMode.HALF_UP)
            if (rounded >= BigDecimal.valueOf(1000) && unit < units.lastIndex) {
                value /= 1000
                unit++
                continue
            }
            return "${rounded.stripTrailingZeros().toPlainString()} ${units[unit]}"
        }
    }

    /** "1h 5m", "12m" or "<1m" (stat cards, history, Downloads activity). */
    fun shortDuration(seconds: Double): String {
        val total = seconds.toLong().coerceAtLeast(0)
        val hours = total / 3600
        val minutes = (total % 3600) / 60
        return when {
            hours > 0 -> "${hours}h ${minutes}m"
            minutes > 0 -> "${minutes}m"
            else -> "<1m"
        }
    }

    /** "1h 5m", "12 min", "<1 min" or "—" for the Time Periods rows. */
    fun periodDuration(seconds: Double): String {
        val total = seconds.toLong().coerceAtLeast(0)
        val hours = total / 3600
        val minutes = (total % 3600) / 60
        return when {
            hours > 0 -> "${hours}h ${minutes}m"
            minutes > 0 -> "$minutes min"
            total > 0 -> "<1 min"
            else -> "—"
        }
    }

    /** Downloads > Listening Stats subtitle. */
    fun listenedSubtitle(seconds: Double): String {
        val total = seconds.toLong().coerceAtLeast(0)
        val hours = total / 3600
        val minutes = (total % 3600) / 60
        return when {
            hours > 0 -> "${hours}h ${minutes}m listened"
            minutes > 0 -> "${minutes}m listened"
            else -> "Start listening to track time"
        }
    }

    /** "Today", "Yesterday" or "Wed, Jul 29" for a `yyyy-MM-dd` day. */
    fun dayLabel(date: String, today: LocalDate, locale: Locale = Locale.getDefault()): String {
        val day = try {
            LocalDate.parse(date)
        } catch (_: DateTimeParseException) {
            return date
        }
        return when (day) {
            today -> "Today"
            today.minusDays(1) -> "Yesterday"
            else -> day.format(DateTimeFormatter.ofPattern("EEE, MMM d", locale))
        }
    }
}
