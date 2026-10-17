package com.agraabhi.oshodiscourses.feature.downloads

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.agraabhi.oshodiscourses.core.domain.progress.PlaybackProgress
import com.agraabhi.oshodiscourses.core.domain.progress.PlaybackStateRepository
import com.agraabhi.oshodiscourses.core.domain.stats.ListeningStats
import com.agraabhi.oshodiscourses.core.domain.stats.ListeningStatsRepository
import com.agraabhi.oshodiscourses.core.model.CatalogRepository
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.time.LocalDate

internal data class HistoryDay(val label: String, val duration: String)

internal data class HistoryItem(val id: String, val title: String, val series: String, val position: Double) {
    val positionText: String? get() = if (position > 0) Formats.shortDuration(position) else null
}

internal data class ListeningStatsUiState(
    val allTime: String = "<1m",
    val streak: String = "0d",
    val discoursesDone: Int = 0,
    val seriesDone: Int = 0,
    val today: String = "—",
    val lastWeek: String = "—",
    val lastMonth: String = "—",
    val allTimePeriod: String = "—",
    /** iOS counts recently played here, while the history page lists every played discourse. */
    val historyCount: Int = 0,
    val days: List<HistoryDay> = emptyList(),
    val played: List<HistoryItem> = emptyList(),
)

/** iOS `ListeningStatsView` and `ListeningHistoryDetailView`, which read the same services. */
internal class ListeningStatsViewModel(
    private val stats: ListeningStatsRepository,
    playbackState: PlaybackStateRepository,
    private val catalog: CatalogRepository,
    private val today: () -> LocalDate = LocalDate::now,
) : ViewModel() {
    val state: StateFlow<ListeningStatsUiState> = combine(stats.stats, playbackState.state, ::build)
        .stateIn(viewModelScope, SharingStarted.Eagerly, build(stats.stats.value, playbackState.state.value))

    /** Persists today's in-memory total so the page shows what was just heard. */
    fun onAppear() = viewModelScope.launch { stats.save() }

    private fun build(s: ListeningStats, p: PlaybackProgress): ListeningStatsUiState {
        val completed = p.completedDiscourseIDs
        // Only series with a completed discourse can be done; avoids walking all 5,481 discourses.
        val seriesDone = completed.mapNotNull { catalog.entry(it)?.series }.distinctBy { it.id }.count { series ->
            val ids = catalog.discourses(series)
            ids.isNotEmpty() && ids.all { it.id in completed }
        }
        val day = today()
        return ListeningStatsUiState(
            allTime = Formats.shortDuration(s.totalAllTime),
            streak = "${s.streakDays}d",
            discoursesDone = completed.size,
            seriesDone = seriesDone,
            today = Formats.periodDuration(s.totalToday),
            lastWeek = Formats.periodDuration(s.totalLastWeek),
            lastMonth = Formats.periodDuration(s.totalLastMonth),
            allTimePeriod = Formats.periodDuration(s.totalAllTime),
            historyCount = p.recentlyPlayed.size,
            days = s.dailyHistory.asReversed().map { HistoryDay(Formats.dayLabel(it.date, day), Formats.shortDuration(it.seconds)) },
            played = p.allPlayedDiscourseIDs.mapNotNull { id ->
                val entry = catalog.entry(id) ?: return@mapNotNull null
                HistoryItem(id, entry.discourse.displayTitle, entry.series.name, p.positions[id] ?: 0.0)
            },
        )
    }
}
