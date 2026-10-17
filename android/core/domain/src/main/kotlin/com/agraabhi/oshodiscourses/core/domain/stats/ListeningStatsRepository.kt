package com.agraabhi.oshodiscourses.core.domain.stats

import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable

/**
 * Daily listening totals in `listening_stats.json` (iOS `ListeningStatsService`). Days are
 * local-calendar `yyyy-MM-dd` strings. Sync merges take the max per day, never the sum.
 */
interface ListeningStatsRepository {
    val stats: StateFlow<ListeningStats>

    /** Adds seconds to today's total in memory; [save] persists. */
    suspend fun recordListeningTime(seconds: Double)

    suspend fun save()

    /** Date string to seconds, for the sync snapshot. */
    fun syncedDailyStats(): Map<String, Double>

    /** Max seconds per day; true if anything changed. */
    suspend fun mergeSyncedStats(incoming: Map<String, Double>): Boolean

    companion object {
        /** A day counts toward the streak from one minute of listening. */
        const val STREAK_MINIMUM_SECONDS: Double = 60.0
    }
}

/** One persisted day (iOS `ListeningStatsService.DailyEntry`). */
@Serializable
data class DailyListening(
    /** `yyyy-MM-dd` in the local time zone. */
    val date: String,
    val seconds: Double,
)

data class ListeningStats(
    val totalToday: Double = 0.0,
    /** Last 7 days. */
    val totalLastWeek: Double = 0.0,
    /** Last 30 days. */
    val totalLastMonth: Double = 0.0,
    val totalAllTime: Double = 0.0,
    /** Consecutive days with at least a minute; starts from yesterday if today has less. */
    val streakDays: Int = 0,
    /** Days with any listening; the review-prompt signal. */
    val distinctActiveDays: Int = 0,
    /** The last 30 recorded days, oldest first. */
    val dailyHistory: List<DailyListening> = emptyList(),
)
