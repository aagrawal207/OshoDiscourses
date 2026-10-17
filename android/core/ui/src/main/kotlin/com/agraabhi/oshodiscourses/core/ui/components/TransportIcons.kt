package com.agraabhi.oshodiscourses.core.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Replay
import androidx.compose.material.icons.rounded.Stop
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.agraabhi.oshodiscourses.core.ui.theme.Osho

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
fun ReplayFifteenIcon(tint: Color, size: Dp = 24.dp, modifier: Modifier = Modifier) =
    SkipIntervalIcon(15, forward = false, tint = tint, modifier = modifier, size = size)

/** iOS `CircularProgressView`: a 28 dp ring with a stop square, or a spinner while queued. */
@Composable
fun DownloadRing(progress: Float, queued: Boolean, modifier: Modifier = Modifier) {
    val colors = Osho.colors
    val track = colors.label.copy(alpha = 0.15f)
    val accent = colors.accent
    Box(modifier.size(28.dp), contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(28.dp)) {
            val stroke = 2.5.dp.toPx()
            val inset = stroke / 2
            val arcSize = Size(size.width - stroke, size.height - stroke)
            val topLeft = Offset(inset, inset)
            drawArc(track, 0f, 360f, useCenter = false, topLeft = topLeft, size = arcSize, style = Stroke(stroke))
            if (!queued) {
                drawArc(
                    accent,
                    startAngle = -90f,
                    sweepAngle = 360f * progress.coerceIn(0f, 1f),
                    useCenter = false,
                    topLeft = topLeft,
                    size = arcSize,
                    style = Stroke(stroke, cap = StrokeCap.Round),
                )
            }
        }
        if (queued) {
            CircularProgressIndicator(modifier = Modifier.size(16.dp), color = colors.secondaryLabel, strokeWidth = 2.dp)
        } else {
            Icon(Icons.Rounded.Stop, contentDescription = null, tint = accent, modifier = Modifier.size(14.dp))
        }
    }
}
