package com.agraabhi.oshodiscourses.core.ui.components

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.PathBuilder
import androidx.compose.ui.graphics.vector.path
import androidx.compose.ui.unit.dp

/** Glyphs Material has no close match for, drawn after their SF Symbols. */
object OshoIcons {
    /** SF `books.vertical.fill`: three upright spines and one leaning, with label cut-outs. */
    val BooksVertical: ImageVector by lazy {
        ImageVector.Builder(name = "BooksVertical", defaultWidth = 24.dp, defaultHeight = 24.dp, viewportWidth = 24f, viewportHeight = 24f)
            .path(fill = SolidColor(Color.Black), pathFillType = PathFillType.EvenOdd) {
                roundedRect(1.5f, 3f, 5.5f, 21f, 1.2f)
                rect(2.8f, 13f, 4.2f, 16.5f)
                roundedRect(6.2f, 5f, 10.8f, 21f, 1.2f)
                rect(7.6f, 15f, 9.4f, 17.5f)
                roundedRect(11.5f, 3f, 14.6f, 21f, 1f)
                // The leaning book: a parallelogram tipped about 14 degrees to the right.
                moveTo(15.2f, 5.6f)
                lineTo(18.4f, 4.8f)
                lineTo(22.6f, 20.1f)
                lineTo(19.4f, 20.9f)
                close()
            }
            .build()
    }

    /** SF `chart.bar.fill`: three chunky rounded bars rising to the right. */
    val ChartBarFill: ImageVector by lazy {
        ImageVector.Builder(name = "ChartBarFill", defaultWidth = 24.dp, defaultHeight = 24.dp, viewportWidth = 24f, viewportHeight = 24f)
            .path(fill = SolidColor(Color.Black)) {
                roundedRect(1.5f, 11f, 7f, 20f, 1.4f)
                roundedRect(9.25f, 7.5f, 14.75f, 20f, 1.4f)
                roundedRect(17f, 4f, 22.5f, 20f, 1.4f)
            }
            .build()
    }

    /** SF `battery.50percent`: a horizontal outline cell, half filled, with a terminal nub. */
    val Battery50: ImageVector by lazy {
        ImageVector.Builder(name = "Battery50", defaultWidth = 26.dp, defaultHeight = 12.dp, viewportWidth = 26f, viewportHeight = 12f)
            .path(fill = SolidColor(Color.Black), pathFillType = PathFillType.EvenOdd) {
                roundedRect(0.5f, 0.5f, 23f, 11.5f, 3.2f)
                roundedRect(1.9f, 1.9f, 21.6f, 10.1f, 2.1f)
            }
            .path(fill = SolidColor(Color.Black)) {
                roundedRect(3.2f, 3.2f, 12f, 8.8f, 1.2f)
                roundedRect(24f, 4f, 25.6f, 8f, 0.8f)
            }
            .build()
    }

    /** SF `arrow.down.circle.fill`: Material's `ArrowCircleDown` is a ring, not a solid disc. */
    val ArrowDownCircleFill: ImageVector by lazy {
        ImageVector.Builder(name = "ArrowDownCircleFill", defaultWidth = 24.dp, defaultHeight = 24.dp, viewportWidth = 24f, viewportHeight = 24f)
            .path(fill = SolidColor(Color.Black), pathFillType = PathFillType.EvenOdd) {
                moveTo(12f, 2f)
                arcTo(10f, 10f, 0f, isMoreThanHalf = true, isPositiveArc = true, x1 = 12f, y1 = 22f)
                arcTo(10f, 10f, 0f, isMoreThanHalf = true, isPositiveArc = true, x1 = 12f, y1 = 2f)
                close()
                moveTo(11f, 6.5f)
                lineTo(13f, 6.5f)
                lineTo(13f, 13.6f)
                lineTo(15.6f, 11f)
                lineTo(17f, 12.4f)
                lineTo(12f, 17.4f)
                lineTo(7f, 12.4f)
                lineTo(8.4f, 11f)
                lineTo(11f, 13.6f)
                close()
            }
            .build()
    }
}

private fun PathBuilder.rect(left: Float, top: Float, right: Float, bottom: Float) {
    moveTo(left, top)
    lineTo(right, top)
    lineTo(right, bottom)
    lineTo(left, bottom)
    close()
}

private fun PathBuilder.roundedRect(left: Float, top: Float, right: Float, bottom: Float, r: Float) {
    moveTo(left + r, top)
    lineTo(right - r, top)
    quadTo(right, top, right, top + r)
    lineTo(right, bottom - r)
    quadTo(right, bottom, right - r, bottom)
    lineTo(left + r, bottom)
    quadTo(left, bottom, left, bottom - r)
    lineTo(left, top + r)
    quadTo(left, top, left + r, top)
    close()
}
