package com.agraabhi.oshodiscourses.core.testing

import com.agraabhi.oshodiscourses.core.domain.stats.DailyListening
import com.agraabhi.oshodiscourses.core.domain.stats.ListeningStats
import com.agraabhi.oshodiscourses.core.domain.stats.ListeningStatsRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update

/** Stats are written directly; [recordListeningTime] only adds to today and all-time totals. */
class FakeListeningStatsRepository(initial: ListeningStats = ListeningStats()) : ListeningStatsRepository {
    override val stats = MutableStateFlow(initial)
    var saves: Int = 0
        private set

    override suspend fun recordListeningTime(seconds: Double) = stats.update {
        it.copy(
            totalToday = it.totalToday + seconds,
            totalLastWeek = it.totalLastWeek + seconds,
            totalLastMonth = it.totalLastMonth + seconds,
            totalAllTime = it.totalAllTime + seconds,
        )
    }

    override suspend fun save() {
        saves++
    }

    override fun syncedDailyStats(): Map<String, Double> = stats.value.dailyHistory.associate { it.date to it.seconds }

    override suspend fun mergeSyncedStats(incoming: Map<String, Double>): Boolean {
        val local = syncedDailyStats()
        val merged = (local.keys + incoming.keys).associateWith { maxOf(local[it] ?: 0.0, incoming[it] ?: 0.0) }
        if (merged == local) return false
        stats.update { s -> s.copy(dailyHistory = merged.toSortedMap().map { (d, sec) -> DailyListening(d, sec) }.takeLast(30)) }
        return true
    }
}
