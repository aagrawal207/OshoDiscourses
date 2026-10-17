package com.agraabhi.oshodiscourses.core.data.stats

import com.agraabhi.oshodiscourses.core.data.AtomicJsonFile
import com.agraabhi.oshodiscourses.core.domain.stats.DailyListening
import com.agraabhi.oshodiscourses.core.domain.stats.ListeningStats
import com.agraabhi.oshodiscourses.core.domain.stats.ListeningStatsRepository
import com.agraabhi.oshodiscourses.core.domain.stats.ListeningStatsRepository.Companion.STREAK_MINIMUM_SECONDS
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.builtins.ListSerializer
import java.io.File
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * [ListeningStatsRepository] in `listening_stats.json`, the iOS file and format: an array of
 * `{"date": "yyyy-MM-dd", "seconds": n}`. The constructor reads the file on the calling thread.
 */
class FileListeningStatsRepository(
    directory: File,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val clock: () -> Long = System::currentTimeMillis,
    private val zone: () -> ZoneId = ZoneId::systemDefault,
) : ListeningStatsRepository {

    private val file = AtomicJsonFile(File(directory, FILE_NAME), ListSerializer(DailyListening.serializer()))
    private val mutex = Mutex()

    /** In file order: appended as days are recorded, sorted by date after a merge, as on iOS. */
    @Volatile
    private var entries: List<DailyListening> = file.read() ?: emptyList()
    private val mutable = MutableStateFlow(summarize(entries, today()))

    override val stats: StateFlow<ListeningStats> = mutable.asStateFlow()

    override suspend fun recordListeningTime(seconds: Double) = mutex.withLock {
        val today = dateString(today())
        val index = entries.indexOfFirst { it.date == today }
        entries = if (index >= 0) {
            entries.toMutableList().also { it[index] = it[index].copy(seconds = it[index].seconds + seconds) }
        } else {
            entries + DailyListening(today, seconds)
        }
        publish()
    }

    override suspend fun save() = mutex.withLock { write() }

    /** Recomputes today-relative totals, for a day that rolled over with no listening. */
    suspend fun refresh() = mutex.withLock { publish() }

    override fun syncedDailyStats(): Map<String, Double> = entries.associate { it.date to it.seconds }

    /**
     * Max per day, so re-syncing a day never double-counts. It can under-count a day heard on
     * two devices, the safe direction for a streak.
     */
    override suspend fun mergeSyncedStats(incoming: Map<String, Double>): Boolean = mutex.withLock {
        val merged = entries.toMutableList()
        var changed = false
        for ((date, seconds) in incoming) {
            val index = merged.indexOfFirst { it.date == date }
            if (index >= 0) {
                if (seconds > merged[index].seconds) {
                    merged[index] = merged[index].copy(seconds = seconds)
                    changed = true
                }
            } else {
                merged += DailyListening(date, seconds)
                changed = true
            }
        }
        if (changed) {
            entries = merged.sortedBy { it.date }
            publish()
            write()
        }
        changed
    }

    private fun publish() {
        mutable.value = summarize(entries, today())
    }

    private suspend fun write() {
        val snapshot = entries
        withContext(ioDispatcher) { file.writeQuietly(snapshot) }
    }

    private fun today(): LocalDate = Instant.ofEpochMilli(clock()).atZone(zone()).toLocalDate()

    companion object {
        const val FILE_NAME: String = "listening_stats.json"

        /** `yyyy-MM-dd` with ASCII digits whatever the locale, like the iOS key. */
        fun dateString(date: LocalDate): String = date.format(DateTimeFormatter.ISO_LOCAL_DATE)

        internal fun summarize(entries: List<DailyListening>, today: LocalDate): ListeningStats {
            val todayString = dateString(today)
            // iOS counts from the calendar day `days` ago inclusive, so a week spans eight dates.
            fun total(days: Long): Double {
                val cutoff = dateString(today.minusDays(days))
                return entries.filter { it.date >= cutoff }.sumOf { it.seconds }
            }
            val byDate = entries.associate { it.date to it.seconds }
            var check = today
            if ((byDate[todayString] ?: 0.0) < STREAK_MINIMUM_SECONDS) check = check.minusDays(1)
            var streak = 0
            while ((byDate[dateString(check)] ?: 0.0) >= STREAK_MINIMUM_SECONDS) {
                streak++
                check = check.minusDays(1)
            }
            return ListeningStats(
                totalToday = entries.firstOrNull { it.date == todayString }?.seconds ?: 0.0,
                totalLastWeek = total(7),
                totalLastMonth = total(30),
                totalAllTime = entries.sumOf { it.seconds },
                streakDays = streak,
                distinctActiveDays = entries.count { it.seconds > 0 },
                dailyHistory = entries.takeLast(30),
            )
        }
    }
}
