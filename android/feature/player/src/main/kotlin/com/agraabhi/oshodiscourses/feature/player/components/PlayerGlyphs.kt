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
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.agraabhi.oshodiscourses.feature.player.R

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
