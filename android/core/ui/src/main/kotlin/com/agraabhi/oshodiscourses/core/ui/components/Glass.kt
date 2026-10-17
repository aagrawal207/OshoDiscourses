package com.agraabhi.oshodiscourses.core.ui.components

import android.os.Build
import androidx.compose.foundation.background
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.dp
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import dev.chrisbanes.haze.HazeInput
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.blur.HazeBlurStyle
import dev.chrisbanes.haze.blur.HazeColorEffect
import dev.chrisbanes.haze.blur.hazeBlur

/**
 * The backdrop the tab shell marks with `Modifier.hazeSource`, so floating chrome (tab bar,
 * mini-player, toasts) can blur what scrolls beneath it. Null where nothing is marked.
 */
val LocalHazeState = compositionLocalOf<HazeState?> { null }

/** iOS materials (ui-style.md §1.7). */
enum class GlassMaterial { ULTRA_THIN, REGULAR }

/**
 * Clips to [shape] and fills it with an iOS material: a 30 dp backdrop blur plus tint on
 * API 31+ when [hazeState] is set, otherwise the near-opaque fallback tint.
 */
@Composable
fun Modifier.glass(
    shape: Shape,
    material: GlassMaterial = GlassMaterial.ULTRA_THIN,
    hazeState: HazeState? = LocalHazeState.current,
): Modifier {
    val colors = Osho.colors
    val (tint, fallback) = when (material) {
        GlassMaterial.ULTRA_THIN -> colors.ultraThinMaterial to colors.ultraThinMaterialFallback
        GlassMaterial.REGULAR -> colors.regularMaterial to colors.regularMaterialFallback
    }
    val clipped = clip(shape)
    if (hazeState == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
        return clipped.background(fallback)
    }
    return clipped.hazeBlur(
        HazeInput.Sources(hazeState),
        HazeBlurStyle {
            blurRadius(30.dp)
            backgroundColor(colors.systemBackground)
            colorEffects(listOf(HazeColorEffect.tint(tint)))
            fallbackColorEffect(HazeColorEffect.tint(fallback))
            noiseFactor(0f)
        },
    )
}
