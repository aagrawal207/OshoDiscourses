package com.agraabhi.oshodiscourses.core.ui.theme

import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Color
import com.agraabhi.oshodiscourses.core.model.AccentTheme

/**
 * iOS 26 system colours for the eight accents (ui-style.md §1.3). The Swift sources use
 * SwiftUI's `.blue`, `.teal`, ... so these are the values iOS 26 renders.
 */
object AccentPalette {
    fun color(theme: AccentTheme, dark: Boolean): Color = if (dark) darkColor(theme) else lightColor(theme)

    fun lightColor(theme: AccentTheme): Color = when (theme) {
        AccentTheme.BLUE -> Color(0xFF0088FF)
        AccentTheme.TEAL -> Color(0xFF00C3D0)
        AccentTheme.PURPLE -> Color(0xFFCB30E0)
        AccentTheme.PINK -> Color(0xFFFF2D55)
        AccentTheme.ORANGE -> Color(0xFFFF8D28)
        AccentTheme.GREEN -> Color(0xFF34C759)
        AccentTheme.INDIGO -> Color(0xFF6155F5)
        AccentTheme.MINT -> Color(0xFF00C8B3)
    }

    fun darkColor(theme: AccentTheme): Color = when (theme) {
        AccentTheme.BLUE -> Color(0xFF0091FF)
        AccentTheme.TEAL -> Color(0xFF00D2E0)
        AccentTheme.PURPLE -> Color(0xFFDB34F2)
        AccentTheme.PINK -> Color(0xFFFF375F)
        AccentTheme.ORANGE -> Color(0xFFFF9230)
        AccentTheme.GREEN -> Color(0xFF30D158)
        AccentTheme.INDIGO -> Color(0xFF6D7CFF)
        AccentTheme.MINT -> Color(0xFF00DAC3)
    }
}

/** Launch background, `LaunchBackground.colorset` (sRGB 0.118, 0.059, 0.267). */
val LaunchBackground = Color(0xFF1E0F44)

/**
 * The iOS semantic colours by their UIKit names (ui-style.md §1.1-1.4, §1.7). [elevated] is the
 * dark sheet variant from [ProvideElevatedSurfaces]; light mode has none.
 */
@Immutable
data class OshoColors(
    val isDark: Boolean,
    val elevated: Boolean,
    val accent: Color,
    /** Text on an accent fill: active chips, Now-playing pill. */
    val onAccent: Color,
    val label: Color,
    val secondaryLabel: Color,
    val tertiaryLabel: Color,
    val quaternaryLabel: Color,
    val placeholderText: Color,
    val systemBackground: Color,
    val secondarySystemBackground: Color,
    val tertiarySystemBackground: Color,
    val systemGroupedBackground: Color,
    val secondarySystemGroupedBackground: Color,
    val tertiarySystemGroupedBackground: Color,
    val systemFill: Color,
    val secondarySystemFill: Color,
    val tertiarySystemFill: Color,
    val quaternarySystemFill: Color,
    val separator: Color,
    /** For dividers drawn over translucent material. */
    val opaqueSeparator: Color,
    val systemGray: Color,
    /** Destructive actions, failures. */
    val systemRed: Color,
    val systemGreen: Color,
    val systemOrange: Color,
    val systemYellow: Color,
    /** Hardcoded iOS blue (not the accent) on playing-row titles and Add Bookmark, kept for parity. */
    val systemBlue: Color,
    val systemPurple: Color,
    /** `.ultraThinMaterial` tint over a 30 dp backdrop blur. */
    val ultraThinMaterial: Color,
    /** `.ultraThinMaterial` without blur (API < 31). */
    val ultraThinMaterialFallback: Color,
    val regularMaterial: Color,
    val regularMaterialFallback: Color,
    /** `.bar` chrome: transcript search, transport and selection bars. */
    val barMaterial: Color,
    /** Liquid Glass hairline on the tab bar and toolbar buttons. */
    val glassBorder: Color,
    val glassShadow: Color,
    /** Selected tab pill behind the accent icon and label: darker than the bar in both modes. */
    val tabSelectionPill: Color,
) {
    /** Tinted-button secondary: `.secondary` inside a default-style Button resolves to accent at 60 % (§1.6). */
    val accentSecondary: Color get() = accent.copy(alpha = 0.6f)

    /** The same palette as it looks inside a sheet. */
    fun elevated(): OshoColors = if (isDark && !elevated) {
        copy(
            elevated = true,
            systemBackground = Color(0xFF1C1C1E),
            secondarySystemBackground = Color(0xFF2C2C2E),
            tertiarySystemBackground = Color(0xFF3A3A3C),
            systemGroupedBackground = Color(0xFF1C1C1E),
            secondarySystemGroupedBackground = Color(0xFF2C2C2E),
            tertiarySystemGroupedBackground = Color(0xFF3A3A3C),
            barMaterial = Color(0xF0252525),
        )
    } else {
        copy(elevated = true)
    }

    companion object {
        fun of(accent: AccentTheme, dark: Boolean): OshoColors = if (dark) dark(accent) else light(accent)

        fun light(accent: AccentTheme): OshoColors = OshoColors(
            isDark = false,
            elevated = false,
            accent = AccentPalette.lightColor(accent),
            onAccent = Color.White,
            label = Color.Black,
            secondaryLabel = Color(0x993C3C43),
            tertiaryLabel = Color(0x4D3C3C43),
            quaternaryLabel = Color(0x2E3C3C43),
            placeholderText = Color(0x4D3C3C43),
            systemBackground = Color.White,
            secondarySystemBackground = Color(0xFFF2F2F7),
            tertiarySystemBackground = Color.White,
            systemGroupedBackground = Color(0xFFF2F2F7),
            secondarySystemGroupedBackground = Color.White,
            tertiarySystemGroupedBackground = Color(0xFFF2F2F7),
            systemFill = Color(0x33787880),
            secondarySystemFill = Color(0x29787880),
            tertiarySystemFill = Color(0x1F767680),
            quaternarySystemFill = Color(0x14747480),
            separator = Color(0x4A3C3C43),
            opaqueSeparator = Color(0xFFC6C6C8),
            systemGray = Color(0xFF8E8E93),
            systemRed = Color(0xFFFF383C),
            systemGreen = Color(0xFF34C759),
            systemOrange = Color(0xFFFF8D28),
            systemYellow = Color(0xFFFFCC00),
            systemBlue = Color(0xFF0088FF),
            systemPurple = Color(0xFFCB30E0),
            ultraThinMaterial = Color(0x8CFFFFFF),
            ultraThinMaterialFallback = Color(0xF0F9F9F9),
            regularMaterial = Color(0xBFFFFFFF),
            regularMaterialFallback = Color(0xF5FFFFFF),
            barMaterial = Color(0xF0F9F9F9),
            glassBorder = Color(0x1A000000),
            glassShadow = Color(0x1F000000),
            tabSelectionPill = Color(0x16000000),
        )

        /** True black, the iOS app's Apple Music dark look. */
        fun dark(accent: AccentTheme): OshoColors = OshoColors(
            isDark = true,
            elevated = false,
            accent = AccentPalette.darkColor(accent),
            onAccent = Color.White,
            label = Color.White,
            secondaryLabel = Color(0x99EBEBF5),
            tertiaryLabel = Color(0x4DEBEBF5),
            quaternaryLabel = Color(0x2EEBEBF5),
            placeholderText = Color(0x4DEBEBF5),
            systemBackground = Color.Black,
            secondarySystemBackground = Color(0xFF1C1C1E),
            tertiarySystemBackground = Color(0xFF2C2C2E),
            systemGroupedBackground = Color.Black,
            secondarySystemGroupedBackground = Color(0xFF1C1C1E),
            tertiarySystemGroupedBackground = Color(0xFF2C2C2E),
            systemFill = Color(0x5C787880),
            secondarySystemFill = Color(0x52787880),
            tertiarySystemFill = Color(0x3D767680),
            quaternarySystemFill = Color(0x2E767680),
            separator = Color(0x99545458),
            opaqueSeparator = Color(0xFF38383A),
            systemGray = Color(0xFF8E8E93),
            systemRed = Color(0xFFFF4245),
            systemGreen = Color(0xFF30D158),
            systemOrange = Color(0xFFFF9230),
            systemYellow = Color(0xFFFFD600),
            systemBlue = Color(0xFF0091FF),
            systemPurple = Color(0xFFDB34F2),
            ultraThinMaterial = Color(0x8C3A3A3C),
            ultraThinMaterialFallback = Color(0xF0222224),
            regularMaterial = Color(0xBF1C1C1E),
            regularMaterialFallback = Color(0xF51C1C1E),
            barMaterial = Color(0xF0161616),
            glassBorder = Color(0x26FFFFFF),
            glassShadow = Color(0x1F000000),
            tabSelectionPill = Color(0x8C000000),
        )
    }
}
