package com.agraabhi.oshodiscourses.feature.player.components

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.StartOffset
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Replay
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.agraabhi.oshodiscourses.feature.player.R

/**
 * SF `gobackward.15` / `goforward.30`: Material has no replay-15, so both draw `replay` with the
 * number on top (ui-style.md §4). Forward mirrors the arrow but not the digits.
 */
@Composable
fun SkipIntervalIcon(seconds: Int, forward: Boolean, tint: Color, modifier: Modifier = Modifier, size: Dp = 24.dp) {
    // Sized from dp, not sp, so the digits stay inside the ring at any font scale.
    val fontSize = with(LocalDensity.current) { (size * 0.34f).toSp() }
    Box(modifier.size(size).clearAndSetSemantics {}, contentAlignment = Alignment.Center) {
        Icon(
            Icons.Rounded.Replay,
            contentDescription = null,
            tint = tint,
            modifier = Modifier.size(size).graphicsLayer { if (forward) scaleX = -1f },
        )
        Text(
            seconds.toString(),
            color = tint,
            fontSize = fontSize,
            fontWeight = FontWeight.Bold,
            lineHeight = fontSize,
            modifier = Modifier.offset(y = size / 24),
        )
    }
}

/** The shared `gobackward.15` glyph, for the player and the transcript transport. */
@Composable
fun ReplayFifteenIcon(tint: Color, modifier: Modifier = Modifier, size: Dp = 24.dp) =
    SkipIntervalIcon(15, forward = false, tint = tint, modifier = modifier, size = size)

/** The bundled `OshoPortrait` used as artwork for every discourse, as on iOS. */
@Composable
internal fun PortraitArtwork(size: Dp, cornerRadius: Dp, modifier: Modifier = Modifier, glow: Boolean = false) {
    val shape = RoundedCornerShape(cornerRadius)
    Image(
        painter = painterResource(R.drawable.osho_portrait),
        contentDescription = null,
        contentScale = ContentScale.Crop,
        modifier = modifier
            .size(size)
            .then(
                if (glow) {
                    Modifier.shadow(30.dp, shape, ambientColor = Color.White.copy(alpha = 0.08f), spotColor = Color.White.copy(alpha = 0.08f))
                } else {
                    Modifier
                },
            )
            .clip(shape),
    )
}

/**
 * The Up Next "now playing" mark: SF `waveform` with a variable-colour pulse becomes four bars
 * that rise and fall. Tests stop infinite animations, so screenshots show a fixed frame.
 */
@Composable
internal fun PlayingBars(color: Color, modifier: Modifier = Modifier, animating: Boolean = true) {
    val transition = rememberInfiniteTransition(label = "bars")
    val phases = listOf(0, 180, 90, 270).map { delay ->
        val value by transition.animateFloat(
            initialValue = 0.3f,
            targetValue = 1f,
            animationSpec = infiniteRepeatable(tween(450, easing = LinearEasing), RepeatMode.Reverse, StartOffset(delay)),
            label = "bar$delay",
        )
        if (animating) value else 0.6f
    }
    Canvas(modifier.size(16.dp)) {
        val count = phases.size
        val barWidth = size.width / (count * 2 - 1)
        phases.forEachIndexed { i, fraction ->
            val h = size.height * fraction
            drawRoundRect(
                color,
                topLeft = Offset(i * barWidth * 2, (size.height - h) / 2),
                size = Size(barWidth, h),
                cornerRadius = CornerRadius(barWidth / 2),
            )
        }
    }
}
