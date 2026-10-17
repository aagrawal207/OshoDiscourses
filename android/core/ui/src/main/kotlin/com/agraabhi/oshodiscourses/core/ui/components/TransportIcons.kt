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
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.agraabhi.oshodiscourses.core.ui.theme.Osho

/** `gobackward.15`: Material has no replay-15, so "15" is drawn inside `replay`. */
@Composable
fun ReplayFifteenIcon(tint: Color, size: Dp = 24.dp, modifier: Modifier = Modifier) {
    Box(modifier.size(size), contentAlignment = Alignment.Center) {
        Icon(Icons.Rounded.Replay, contentDescription = null, tint = tint, modifier = Modifier.size(size))
        val scale = size.value / 24f
        Text(
            "15",
            color = tint,
            fontSize = with(LocalDensity.current) { (8 * scale).dp.toSp() },
            fontWeight = FontWeight.Bold,
            modifier = Modifier.offset(y = (1 * scale).dp),
        )
    }
}

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
