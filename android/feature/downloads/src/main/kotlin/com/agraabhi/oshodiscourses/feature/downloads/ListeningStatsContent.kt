package com.agraabhi.oshodiscourses.feature.downloads

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.LibraryBooks
import androidx.compose.material.icons.outlined.AllInclusive
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.LocalFireDepartment
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import com.agraabhi.oshodiscourses.core.ui.theme.monospacedDigits
import com.agraabhi.oshodiscourses.feature.downloads.ui.BackButton
import com.agraabhi.oshodiscourses.feature.downloads.ui.CardRow
import com.agraabhi.oshodiscourses.feature.downloads.ui.GroupedPage
import com.agraabhi.oshodiscourses.feature.downloads.ui.rowContentPadding
import com.agraabhi.oshodiscourses.feature.downloads.ui.sectionGap
import com.agraabhi.oshodiscourses.feature.downloads.ui.sectionHeader

@Composable
internal fun ListeningStatsContent(
    state: ListeningStatsUiState,
    onOpenHistory: () -> Unit,
    onBack: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    val colors = Osho.colors
    GroupedPage(
        title = "Listening Stats",
        largeTitle = false,
        background = colors.systemBackground,
        modifier = modifier,
        navigation = onBack?.let { back -> { BackButton(back) } },
    ) {
        sectionGap("top", 16.dp)
        item(key = "overview", contentType = "overview") {
            CardRow(isFirst = true, isLast = true) {
                Column(Modifier.fillMaxWidth().padding(vertical = 20.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
                    Row(Modifier.fillMaxWidth()) {
                        StatCard("All Time", state.allTime, Icons.Outlined.AllInclusive, colors.accent, Modifier.weight(1f))
                        StatCard("Streak", state.streak, Icons.Rounded.LocalFireDepartment, colors.systemOrange, Modifier.weight(1f))
                    }
                    Row(Modifier.fillMaxWidth()) {
                        StatCard("Discourses Done", "${state.discoursesDone}", Icons.Rounded.CheckCircle, colors.systemGreen, Modifier.weight(1f))
                        StatCard("Series Done", "${state.seriesDone}", Icons.AutoMirrored.Rounded.LibraryBooks, colors.systemPurple, Modifier.weight(1f))
                    }
                }
            }
        }
        sectionHeader("periods.header", "Time Periods")
        val periods = listOf(
            "Today" to state.today,
            "Last 7 Days" to state.lastWeek,
            "Last 30 Days" to state.lastMonth,
            "All Time" to state.allTimePeriod,
        )
        itemsIndexed(periods, key = { _, p -> "period.${p.first}" }) { index, (label, value) ->
            CardRow(isFirst = index == 0, isLast = index == periods.lastIndex) {
                ValueRow(label, value)
            }
        }
        sectionGap("history.gap", 32.dp)
        item(key = "history", contentType = "link") {
            CardRow(isFirst = true, isLast = true) {
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clickable(role = Role.Button, onClick = onOpenHistory)
                        .semantics(mergeDescendants = true) {}
                        .rowContentPadding(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text("Full Listening History", style = Osho.typography.body, color = colors.label, modifier = Modifier.weight(1f))
                    Text("${state.historyCount} items", style = Osho.typography.caption, color = colors.secondaryLabel)
                    Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = colors.tertiaryLabel, modifier = Modifier.size(22.dp))
                }
            }
        }
    }
}

@Composable
private fun StatCard(label: String, value: String, icon: ImageVector, tint: Color, modifier: Modifier) {
    Column(
        modifier.semantics(mergeDescendants = true) {}.padding(horizontal = 4.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(28.dp))
        Text(value, style = Osho.typography.title, fontWeight = FontWeight.Bold, color = Osho.colors.label, textAlign = TextAlign.Center)
        Text(label, style = Osho.typography.caption, color = Osho.colors.secondaryLabel, textAlign = TextAlign.Center)
    }
}

@Composable
private fun ValueRow(label: String, value: String, small: Boolean = false) {
    val style = if (small) Osho.typography.subheadline else Osho.typography.body
    Row(
        Modifier.fillMaxWidth().semantics(mergeDescendants = true) {}.rowContentPadding(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(label, style = style, color = Osho.colors.label, modifier = Modifier.weight(1f))
        Text(value, style = style.monospacedDigits(), color = Osho.colors.secondaryLabel)
    }
}

@Composable
internal fun ListeningHistoryContent(state: ListeningStatsUiState, onBack: (() -> Unit)?, modifier: Modifier = Modifier) {
    val colors = Osho.colors
    GroupedPage(
        title = "Listening History",
        largeTitle = false,
        background = colors.systemBackground,
        modifier = modifier,
        navigation = onBack?.let { back -> { BackButton(back) } },
    ) {
        sectionHeader("days.header", "Daily Log", first = true)
        if (state.days.isEmpty()) {
            item(key = "days.empty") {
                CardRow(isFirst = true, isLast = true) {
                    Text("No data yet", style = Osho.typography.body, color = colors.secondaryLabel, modifier = Modifier.fillMaxWidth().rowContentPadding(vertical = 15.dp))
                }
            }
        } else {
            itemsIndexed(state.days, key = { index, _ -> "day.$index" }, contentType = { _, _ -> "day" }) { index, day ->
                CardRow(isFirst = index == 0, isLast = index == state.days.lastIndex) {
                    ValueRow(day.label, day.duration, small = true)
                }
            }
        }
        sectionHeader("played.header", "All Played Discourses (${state.played.size})")
        if (state.played.isEmpty()) {
            item(key = "played.empty") {
                CardRow(isFirst = true, isLast = true) {
                    Text(
                        "No listening history yet",
                        style = Osho.typography.body,
                        color = colors.secondaryLabel,
                        modifier = Modifier.fillMaxWidth().rowContentPadding(vertical = 15.dp),
                    )
                }
            }
        } else {
            itemsIndexed(state.played, key = { _, item -> "played.${item.id}" }, contentType = { _, _ -> "played" }) { index, item ->
                CardRow(isFirst = index == 0, isLast = index == state.played.lastIndex) {
                    Row(
                        Modifier.fillMaxWidth().semantics(mergeDescendants = true) {}.rowContentPadding(vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(item.title, style = Osho.typography.subheadline, color = colors.label, maxLines = 1)
                            Text(item.series, style = Osho.typography.caption, color = colors.secondaryLabel, maxLines = 1)
                        }
                        val position = item.positionText
                        if (position != null) {
                            Text(position, style = Osho.typography.caption.monospacedDigits(), color = colors.secondaryLabel)
                        } else {
                            Icon(Icons.Rounded.CheckCircle, contentDescription = "Completed", tint = colors.accent, modifier = Modifier.size(14.dp))
                        }
                    }
                }
            }
        }
    }
}
