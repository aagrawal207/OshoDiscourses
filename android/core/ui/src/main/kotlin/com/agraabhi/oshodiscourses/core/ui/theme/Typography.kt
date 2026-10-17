package com.agraabhi.oshodiscourses.core.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.runtime.Immutable
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/**
 * iOS Dynamic Type styles at "Large" (ui-style.md §2.1), in sp so they follow font scale.
 * Tracking stays 0: Roboto already sets wider than SF, so SF's tracking would cramp it.
 */
@Immutable
data class OshoTypography(
    val largeTitle: TextStyle = style(34, 41),
    val title: TextStyle = style(28, 34),
    val title2: TextStyle = style(22, 28),
    val title3: TextStyle = style(20, 25),
    val headline: TextStyle = style(17, 22, FontWeight.SemiBold),
    val body: TextStyle = style(17, 22),
    val callout: TextStyle = style(16, 21),
    val subheadline: TextStyle = style(15, 20),
    val footnote: TextStyle = style(13, 18),
    val caption: TextStyle = style(12, 16),
    val caption2: TextStyle = style(11, 13),
    /** Collapsed navigation title. */
    val navInline: TextStyle = style(17, 22, FontWeight.SemiBold),
    /** iOS 26 tab bar label: 10 pt SF runs as wide as 11 sp Roboto. */
    val tabLabel: TextStyle = style(11, 13, FontWeight.SemiBold),
    val segment: TextStyle = style(13, 16, FontWeight.Medium),
    /** Grouped list section header; never uppercased. */
    val listHeader: TextStyle = style(17, 22, FontWeight.SemiBold),
    /** iOS 26 list footers set 13 pt on a 16 pt line, tighter than `.footnote`. */
    val listFooter: TextStyle = style(13, 16),
) {
    /** Material slots mapped to the nearest iOS style, for stock components. */
    fun toMaterial(): Typography = Typography(
        displayLarge = largeTitle.copy(fontWeight = FontWeight.Bold),
        displayMedium = largeTitle,
        displaySmall = title,
        headlineLarge = largeTitle.copy(fontWeight = FontWeight.Bold),
        headlineMedium = title,
        headlineSmall = title2,
        titleLarge = title3.copy(fontWeight = FontWeight.SemiBold),
        titleMedium = headline,
        titleSmall = subheadline.copy(fontWeight = FontWeight.SemiBold),
        bodyLarge = body,
        bodyMedium = subheadline,
        bodySmall = footnote,
        labelLarge = subheadline.copy(fontWeight = FontWeight.Medium),
        labelMedium = caption.copy(fontWeight = FontWeight.Medium),
        labelSmall = caption2.copy(fontWeight = FontWeight.Medium),
    )
}

/** `.monospacedDigit()`: tabular figures so times do not jitter. */
fun TextStyle.monospacedDigits(): TextStyle = copy(fontFeatureSettings = "tnum")

private fun style(size: Int, lineHeight: Int, weight: FontWeight = FontWeight.Normal) = TextStyle(
    fontFamily = FontFamily.Default,
    fontWeight = weight,
    fontSize = size.sp,
    lineHeight = lineHeight.sp,
    letterSpacing = 0.sp,
)
