package com.agraabhi.oshodiscourses.core.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.LocalMinimumInteractiveComponentSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.agraabhi.oshodiscourses.core.model.AccentTheme
import com.agraabhi.oshodiscourses.core.model.Appearance

val LocalOshoColors = staticCompositionLocalOf { OshoColors.light(AccentTheme.PURPLE) }
val LocalOshoTypography = staticCompositionLocalOf { OshoTypography() }

/** Whether [this] appearance resolves to dark right now; System follows the device. */
@Composable
fun Appearance.isDark(): Boolean = when (this) {
    Appearance.SYSTEM -> isSystemInDarkTheme()
    Appearance.DARK -> true
    Appearance.LIGHT -> false
}

/**
 * The app theme: iOS semantic colours and text styles, mirrored into Material 3 so stock
 * components pick up the accent, true black dark mode and white light mode. No dynamic colour.
 */
@Composable
fun OshoTheme(
    appearance: Appearance = Appearance.SYSTEM,
    accent: AccentTheme = AccentTheme.PURPLE,
    content: @Composable () -> Unit,
) {
    ProvideOshoColors(OshoColors.of(accent, appearance.isDark()), content)
}

/** Sheets and popovers: dark mode switches to the elevated greys (ui-style.md §1.1). */
@Composable
fun ProvideElevatedSurfaces(content: @Composable () -> Unit) {
    ProvideOshoColors(LocalOshoColors.current.elevated(), content)
}

@Composable
private fun ProvideOshoColors(colors: OshoColors, content: @Composable () -> Unit) {
    val typography = LocalOshoTypography.current
    CompositionLocalProvider(LocalOshoColors provides colors) {
        MaterialTheme(colorScheme = colors.toColorScheme(), typography = typography.toMaterial()) {
            // iOS hit areas are 44 pt; Material's 48 dp minimum would shift every row.
            CompositionLocalProvider(LocalMinimumInteractiveComponentSize provides 44.dp, content = content)
        }
    }
}

/** Accessors in the style of `MaterialTheme.colorScheme`. */
object Osho {
    val colors: OshoColors
        @Composable @ReadOnlyComposable get() = LocalOshoColors.current

    val typography: OshoTypography
        @Composable @ReadOnlyComposable get() = LocalOshoTypography.current
}

/** ui-style.md §1.9. */
private fun OshoColors.toColorScheme(): ColorScheme {
    val base = if (isDark) darkColorScheme() else lightColorScheme()
    return base.copy(
        primary = accent,
        onPrimary = onAccent,
        primaryContainer = accent.copy(alpha = 0.15f),
        onPrimaryContainer = accent,
        secondary = accent,
        onSecondary = onAccent,
        secondaryContainer = tertiarySystemFill,
        onSecondaryContainer = label,
        tertiary = accent,
        onTertiary = onAccent,
        background = systemBackground,
        onBackground = label,
        surface = systemBackground,
        onSurface = label,
        surfaceVariant = secondarySystemBackground,
        onSurfaceVariant = secondaryLabel,
        surfaceTint = Color.Transparent,
        surfaceContainerLowest = systemBackground,
        surfaceContainerLow = secondarySystemGroupedBackground,
        surfaceContainer = secondarySystemGroupedBackground,
        surfaceContainerHigh = if (isDark) Color(0xFF1C1C1E) else Color.White,
        surfaceContainerHighest = if (isDark) Color(0xFF2C2C2E) else Color.White,
        surfaceBright = secondarySystemBackground,
        surfaceDim = systemBackground,
        outline = separator,
        outlineVariant = separator,
        error = systemRed,
        onError = Color.White,
        inverseSurface = if (isDark) Color.White else Color(0xFF1C1C1E),
        inverseOnSurface = if (isDark) Color.Black else Color.White,
        inversePrimary = accent,
        scrim = Color.Black.copy(alpha = 0.4f),
    )
}
