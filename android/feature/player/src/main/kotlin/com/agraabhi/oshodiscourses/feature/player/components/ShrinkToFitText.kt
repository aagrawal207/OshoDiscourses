package com.agraabhi.oshodiscourses.feature.player.components

import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.isSpecified

/**
 * One line that shrinks to fit before it truncates, like SwiftUI's `minimumScaleFactor`.
 * Below [minScale] it ellipsizes, so a huge font scale still cannot overflow the slot.
 */
@Composable
internal fun ShrinkToFitText(
    text: String,
    style: TextStyle,
    color: Color,
    minScale: Float,
    modifier: Modifier = Modifier,
    textAlign: TextAlign? = null,
) {
    val measurer = rememberTextMeasurer()
    BoxWithConstraints(modifier) {
        val maxWidth = constraints.maxWidth
        val fitted = remember(text, style, maxWidth) {
            if (maxWidth == Constraints.Infinity) return@remember style
            fun widthAt(scale: Float) = measurer.measure(text, style.scaled(scale), maxLines = 1, softWrap = false).size.width
            val full = widthAt(1f)
            if (full <= maxWidth) return@remember style
            // Glyph widths do not scale exactly linearly, so step down until it really fits.
            var scale = maxWidth.toFloat() / full
            while (scale > minScale && widthAt(scale) > maxWidth) scale -= 0.02f
            style.scaled(scale.coerceAtLeast(minScale))
        }
        Text(text, style = fitted, color = color, maxLines = 1, softWrap = false, overflow = TextOverflow.Ellipsis, textAlign = textAlign)
    }
}

private fun TextStyle.scaled(scale: Float): TextStyle = if (scale == 1f) {
    this
} else {
    copy(fontSize = fontSize * scale, lineHeight = if (lineHeight.isSpecified) lineHeight * scale else lineHeight)
}
