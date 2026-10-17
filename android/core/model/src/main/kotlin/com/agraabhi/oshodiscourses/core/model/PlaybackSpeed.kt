package com.agraabhi.oshodiscourses.core.model

import java.math.BigDecimal
import java.math.RoundingMode
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Playback speed is a continuous setting in 0.05 steps (iOS `PlaybackSpeed`), so 0.85× and 1.1×
 * are as reachable as 1.5×. Every entry point (slider, presets, media session) uses this grid.
 */
object PlaybackSpeed {
    const val MIN: Float = 0.5f
    const val MAX: Float = 2.0f
    const val STEP: Float = 0.05f

    /** Common speeds stay one tap away beside the slider. */
    val presets: List<Float> = listOf(0.75f, 1f, 1.25f, 1.5f, 2f)

    /** Rounds to the nearest step so drift from any input lands on the same grid. */
    fun normalized(rate: Float): Float {
        if (!rate.isFinite()) return 1f
        val clamped = rate.coerceIn(MIN, MAX)
        // Dividing whole twentieths gives the same Float as a literal such as 0.85f.
        return (clamped * 20).roundToInt() / 20f
    }

    fun stepped(rate: Float, steps: Int): Float = normalized(normalized(rate) + steps * STEP)

    fun matches(lhs: Float, rhs: Float): Boolean = abs(lhs - rhs) < STEP / 2

    /** "1×", "1.25×", "0.85×": up to two fraction digits, no trailing zeros. */
    fun label(rate: Float): String = format(rate) + "×"

    fun accessibilityLabel(rate: Float): String = format(rate) + " times"

    private fun format(rate: Float): String =
        BigDecimal(normalized(rate).toDouble())
            .setScale(2, RoundingMode.HALF_EVEN)
            .stripTrailingZeros()
            .toPlainString()
}
