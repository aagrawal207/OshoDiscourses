package com.agraabhi.oshodiscourses.feature.player

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.agraabhi.oshodiscourses.core.domain.player.PlayerState
import com.agraabhi.oshodiscourses.core.ui.components.GlassTextButton
import com.agraabhi.oshodiscourses.core.ui.components.SheetToolbar
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import com.agraabhi.oshodiscourses.core.ui.theme.monospacedDigits
import com.agraabhi.oshodiscourses.feature.player.components.PlayingBars

/** iOS `QueueView`: the download-scoped queue as Up Next. Tapping a row plays it and closes. */
@Composable
internal fun QueueSheetContent(
    player: PlayerState,
    onSelect: (Int) -> Unit,
    onDone: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = Osho.colors
    Column(modifier.fillMaxSize()) {
        SheetToolbar("Up Next", trailing = { GlassTextButton("Done", onClick = onDone) })
        LazyColumn(
            Modifier.fillMaxSize(),
            contentPadding = PaddingValues(bottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding() + 16.dp),
        ) {
            // iOS plain lists rule above the first row and below the last one too.
            item(key = "topRule") { QueueDivider() }
            itemsIndexed(player.queue, key = { _, item -> item.id }) { index, item ->
                val current = index == player.currentIndex
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable(role = Role.Button) { onSelect(index) }
                        .clearAndSetSemantics {
                            contentDescription = if (current) "Now playing: ${item.title}" else "${item.title}, ${item.series}"
                            role = Role.Button
                            selected = current
                            onClick(label = if (current) null else "play this discourse") { onSelect(index); true }
                        }
                        .padding(horizontal = 20.dp, vertical = 15.dp),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(Modifier.width(24.dp), contentAlignment = Alignment.Center) {
                        when {
                            current && player.isPlaying -> PlayingBars(colors.accent)
                            current -> Icon(Icons.Rounded.Pause, contentDescription = null, tint = colors.accent, modifier = Modifier.size(18.dp))
                            else -> Text(
                                "${index + 1}",
                                style = Osho.typography.subheadline.monospacedDigits(),
                                color = colors.secondaryLabel,
                                maxLines = 1,
                            )
                        }
                    }
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(
                            item.title,
                            style = Osho.typography.subheadline,
                            fontWeight = if (current) FontWeight.SemiBold else FontWeight.Normal,
                            color = if (current) colors.accent else colors.label,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Text(
                            item.series,
                            style = Osho.typography.caption,
                            color = colors.secondaryLabel,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
                QueueDivider()
            }
        }
    }
}

@Composable
private fun QueueDivider() {
    HorizontalDivider(Modifier.padding(start = 20.dp, end = 16.dp), thickness = Dp.Hairline, color = Osho.colors.separator)
}
