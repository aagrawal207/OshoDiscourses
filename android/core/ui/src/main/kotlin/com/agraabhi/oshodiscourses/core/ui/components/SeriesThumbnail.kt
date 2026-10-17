package com.agraabhi.oshodiscourses.core.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import java.text.BreakIterator
import java.util.Locale

/**
 * iOS `SeriesThumbnailView` (ui-style.md §1.8): name-seeded gradient with initials, or the cover
 * over it. Decorative, since the row's text carries the name for TalkBack.
 */
@Composable
fun SeriesThumbnail(
    name: String,
    size: Dp,
    modifier: Modifier = Modifier,
    coverURL: String? = null,
) {
    val colors = remember(name) { SeriesArtwork.gradientColors(name) }
    var coverLoaded by remember(coverURL) { mutableStateOf(false) }
    val shape = RoundedCornerShape(12.dp)
    Box(
        modifier = modifier
            .size(size)
            .clip(shape)
            .background(Brush.linearGradient(colors))
            .clearAndSetSemantics {},
        contentAlignment = Alignment.Center,
    ) {
        if (coverURL != null) {
            AsyncImage(
                model = coverURL,
                contentDescription = null,
                contentScale = ContentScale.Crop,
                onSuccess = { coverLoaded = true },
                modifier = Modifier.size(size),
            )
        }
        // The cover is a waveform with a transparent background; initials under it would smudge.
        if (!coverLoaded) {
            val fontSize = with(LocalDensity.current) { (size * 0.3f).toSp() }
            Text(
                text = SeriesArtwork.initials(name),
                color = Osho.colors.label,
                fontSize = fontSize,
                fontWeight = FontWeight.Bold,
            )
        }
    }
}

/** Pure parts of the thumbnail, matched to iOS so a series keeps its colours across platforms. */
object SeriesArtwork {
    /** FNV-1a over UTF-8; stable across launches and devices, unlike `hashCode`. */
    fun stableHash(value: String): ULong {
        var hash = 0xcbf29ce484222325uL
        for (byte in value.encodeToByteArray()) {
            hash = hash xor byte.toUByte().toULong()
            hash *= 0x100000001b3uL
        }
        return hash
    }

    fun gradientColors(name: String): List<Color> {
        val hash = stableHash(name)
        val hue1 = (hash % 360uL).toFloat()
        val hue2 = ((hash / 360uL) % 360uL).toFloat()
        return listOf(Color.hsv(hue1, 0.6f, 0.5f), Color.hsv(hue2, 0.7f, 0.3f))
    }

    /** First two grapheme clusters, like Swift's `prefix(2)`; "A Sudden…" gives "A ". */
    fun initials(name: String): String {
        val breaks = BreakIterator.getCharacterInstance(Locale.ROOT)
        breaks.setText(name)
        var end = 0
        repeat(2) { breaks.next().takeIf { it != BreakIterator.DONE }?.let { end = it } }
        return name.substring(0, end).uppercase(Locale.ROOT)
    }
}
