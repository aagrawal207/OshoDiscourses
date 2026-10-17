@file:OptIn(ExperimentalCoroutinesApi::class)

package com.agraabhi.oshodiscourses.core.data.stats

import com.agraabhi.oshodiscourses.core.domain.stats.DailyListening
import com.agraabhi.oshodiscourses.core.testing.FakeClock
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.time.ZoneId
import java.time.ZoneOffset

/** Ports `ListeningStatsTests` and the stats half of `SyncMergeTests`, with a fixed clock. */
class FileListeningStatsRepositoryTest {
    @get:Rule val folder = TemporaryFolder()

    /** 2026-10-17T12:00:00Z. */
    private val clock = FakeClock(1_792_238_400_000L)

    private fun TestScope.repo(zone: ZoneId = ZoneOffset.UTC) =
        FileListeningStatsRepository(folder.root, UnconfinedTestDispatcher(testScheduler), { clock.nowMillis }, { zone })

    @Test fun recordListeningTimeAddsToToday() = runTest {
        val stats = repo()
        stats.recordListeningTime(10.0)
        stats.recordListeningTime(5.0)
        assertThat(stats.stats.value.totalToday).isEqualTo(15.0)
        assertThat(stats.stats.value.totalAllTime).isEqualTo(15.0)
        assertThat(stats.stats.value.totalLastWeek).isEqualTo(15.0)
        assertThat(stats.stats.value.totalLastMonth).isEqualTo(15.0)
        assertThat(stats.syncedDailyStats()).containsExactly("2026-10-17", 15.0)
    }

    @Test fun distinctActiveDaysCountsTodayOnce() = runTest {
        val stats = repo()
        stats.recordListeningTime(3.0)
        stats.recordListeningTime(3.0)
        stats.mergeSyncedStats(mapOf("2026-10-01" to 0.0, "2026-10-02" to 9.0))
        assertThat(stats.stats.value.distinctActiveDays).isEqualTo(2)
    }

    @Test fun weekAndMonthCountFromTheCalendarDayThatManyDaysAgo() = runTest {
        val stats = repo()
        stats.mergeSyncedStats(
            mapOf(
                "2026-10-10" to 100.0,
                "2026-10-09" to 1_000.0,
                "2026-09-17" to 10_000.0,
                "2026-09-16" to 100_000.0,
            ),
        )
        assertThat(stats.stats.value.totalLastWeek).isEqualTo(100.0)
        assertThat(stats.stats.value.totalLastMonth).isEqualTo(11_100.0)
        assertThat(stats.stats.value.totalAllTime).isEqualTo(111_100.0)
        assertThat(stats.stats.value.totalToday).isEqualTo(0.0)
    }

    @Test fun streakStartsYesterdayUntilTodayReachesAMinute() = runTest {
        val stats = repo()
        stats.mergeSyncedStats(mapOf("2026-10-16" to 60.0, "2026-10-15" to 120.0, "2026-10-14" to 59.0, "2026-10-13" to 600.0))
        assertThat(stats.stats.value.streakDays).isEqualTo(2)
        stats.recordListeningTime(30.0)
        assertThat(stats.stats.value.streakDays).isEqualTo(2)
        stats.recordListeningTime(30.0)
        assertThat(stats.stats.value.streakDays).isEqualTo(3)
    }

    @Test fun streakIsZeroAfterAMissedDay() = runTest {
        val stats = repo()
        stats.mergeSyncedStats(mapOf("2026-10-15" to 600.0))
        assertThat(stats.stats.value.streakDays).isEqualTo(0)
    }

    @Test fun todayFollowsTheLocalTimeZone() = runTest {
        // 03:00 UTC on 17 October is still the evening of the 16th in Los Angeles.
        clock.nowMillis = 1_792_206_000_000L
        val stats = repo(ZoneId.of("America/Los_Angeles"))
        stats.recordListeningTime(42.0)
        assertThat(stats.syncedDailyStats()).containsExactly("2026-10-16", 42.0)
    }

    @Test fun dailyHistoryIsTheLast30OldestFirst() = runTest {
        val stats = repo()
        val days = (1..31).associate { "2026-08-%02d".format(it) to it.toDouble() }
        stats.mergeSyncedStats(days)
        val history = stats.stats.value.dailyHistory
        assertThat(history).hasSize(30)
        assertThat(history.first()).isEqualTo(DailyListening("2026-08-02", 2.0))
        assertThat(history.last()).isEqualTo(DailyListening("2026-08-31", 31.0))
    }

    @Test fun statsMergeAddsMissingDaysAndIsIdempotent() = runTest {
        val stats = repo()
        assertThat(stats.mergeSyncedStats(mapOf("2000-01-01" to 123.0))).isTrue()
        assertThat(stats.syncedDailyStats()["2000-01-01"]).isEqualTo(123.0)
        assertThat(stats.mergeSyncedStats(mapOf("2000-01-01" to 123.0))).isFalse()
    }

    @Test fun statsMergeKeepsLargerValue() = runTest {
        val stats = repo()
        assertThat(stats.mergeSyncedStats(mapOf("2000-01-02" to 500.0))).isTrue()
        assertThat(stats.mergeSyncedStats(mapOf("2000-01-02" to 100.0))).isFalse()
        assertThat(stats.syncedDailyStats()["2000-01-02"]).isEqualTo(500.0)
        assertThat(stats.mergeSyncedStats(mapOf("2000-01-02" to 900.0))).isTrue()
        assertThat(stats.syncedDailyStats()["2000-01-02"]).isEqualTo(900.0)
    }

    @Test fun recordedTimeIsOnDiskOnlyAfterSave() = runTest {
        val stats = repo()
        stats.recordListeningTime(70.0)
        assertThat(repo().syncedDailyStats()).isEmpty()
        stats.save()
        assertThat(repo().syncedDailyStats()).containsExactly("2026-10-17", 70.0)
    }

    @Test fun mergedDaysAreSavedSortedByDate() = runTest {
        val stats = repo()
        stats.recordListeningTime(5.0)
        stats.mergeSyncedStats(mapOf("2026-10-01" to 1.0))
        val text = File(folder.root, "listening_stats.json").readText()
        assertThat(text).isEqualTo("""[{"date":"2026-10-01","seconds":1.0},{"date":"2026-10-17","seconds":5.0}]""")
    }
}
