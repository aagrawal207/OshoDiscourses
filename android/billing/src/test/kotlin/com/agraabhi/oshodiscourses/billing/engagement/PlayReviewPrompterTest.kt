package com.agraabhi.oshodiscourses.billing.engagement

import com.agraabhi.oshodiscourses.billing.JsonFileStore
import com.agraabhi.oshodiscourses.core.domain.engagement.EngagementHistory
import com.agraabhi.oshodiscourses.core.domain.engagement.SubscriptionStatus
import com.agraabhi.oshodiscourses.core.domain.engagement.SupportContext
import com.agraabhi.oshodiscourses.core.domain.sleep.SleepTimerMode
import com.agraabhi.oshodiscourses.core.domain.sleep.SleepTimerState
import com.agraabhi.oshodiscourses.core.domain.stats.ListeningStats
import com.agraabhi.oshodiscourses.core.testing.FakeClock
import com.agraabhi.oshodiscourses.core.testing.FakeListeningStatsRepository
import com.agraabhi.oshodiscourses.core.testing.FakeSleepTimer
import com.google.common.truth.Truth.assertThat
import java.io.File
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class PlayReviewPrompterTest {
    @get:Rule val folder = TemporaryFolder()

    private val clock = FakeClock(1_800_000_000_000L)
    private val day = 86_400_000L
    private val stats = FakeListeningStatsRepository(ListeningStats(distinctActiveDays = 3, totalToday = 20 * 60.0))
    private val sleepTimer = FakeSleepTimer()
    private var playing = false
    private var foreground = true

    private val engagementFile get() = File(folder.root, "engagement.json")
    private val reviewFile get() = File(folder.root, "review_prompt.json")

    private fun engagement() =
        LocalEngagementService(JsonFileStore(engagementFile, EngagementRecord.serializer(), EngagementRecord())) { clock.nowMillis }

    private fun prompter(engagement: LocalEngagementService, version: String = "2.0", onLaunch: () -> Unit = {}) = PlayReviewPrompter(
        engagement = engagement,
        listeningStats = stats,
        sleepTimer = sleepTimer,
        isPlaying = { playing },
        isForeground = { foreground },
        currentVersion = version,
        store = JsonFileStore(reviewFile, ReviewRecord.serializer(), ReviewRecord()),
        launcher = ReviewLauncher(onLaunch),
    )

    private fun savedVersion(): String? = JsonFileStore(reviewFile, ReviewRecord.serializer(), ReviewRecord()).read().lastPromptedVersion

    private suspend fun PlayReviewPrompter.attempt(
        activeDays: Int = 3,
        isForeground: Boolean = true,
        isPlaying: Boolean = false,
        sleepTimerArmed: Boolean = false,
    ) = attemptReview(activeDays, isForeground, isPlaying, sleepTimerArmed)

    @Test
    fun requiresThreeActiveDays() {
        assertThat(ReviewPolicy.isEligible(activeDays = 2, lastPromptedVersion = null, currentVersion = "2.0")).isFalse()
        assertThat(ReviewPolicy.isEligible(activeDays = 3, lastPromptedVersion = null, currentVersion = "2.0")).isTrue()
    }

    @Test
    fun suppressesRepeatForSameVersion() {
        assertThat(ReviewPolicy.isEligible(activeDays = 20, lastPromptedVersion = "2.0", currentVersion = "2.0")).isFalse()
        assertThat(ReviewPolicy.isEligible(activeDays = 20, lastPromptedVersion = "1.9", currentVersion = "2.0")).isTrue()
    }

    @Test
    fun onlyNaturalIdleCompletionIsAGoodMoment() {
        assertThat(ReviewPolicy.isGoodMoment(completionWasNatural = true, playbackContinues = false, sleepTimerWasArmed = false)).isTrue()
        assertThat(ReviewPolicy.isGoodMoment(completionWasNatural = false, playbackContinues = false, sleepTimerWasArmed = false)).isFalse()
        assertThat(ReviewPolicy.isGoodMoment(completionWasNatural = true, playbackContinues = true, sleepTimerWasArmed = false)).isFalse()
        assertThat(ReviewPolicy.isGoodMoment(completionWasNatural = true, playbackContinues = false, sleepTimerWasArmed = true)).isFalse()
    }

    @Test
    fun pauseAfterTwentyMinutesTodayIsAGoodMoment() {
        assertThat(ReviewPolicy.isGoodPauseMoment(listenedToday = 19 * 60 + 59.0, sleepTimerWasArmed = false)).isFalse()
        assertThat(ReviewPolicy.isGoodPauseMoment(listenedToday = 20 * 60.0, sleepTimerWasArmed = false)).isTrue()
        assertThat(ReviewPolicy.isGoodPauseMoment(listenedToday = 3 * 3600.0, sleepTimerWasArmed = true)).isFalse()
    }

    @Test
    fun writeReviewLinkTargetsThisAppOnPlay() {
        val url = java.net.URI(prompter(engagement()).writeReviewURL)
        assertThat(url.host).isEqualTo("play.google.com")
        assertThat(url.path).isEqualTo("/store/apps/details")
        assertThat(url.query).contains("id=com.agraabhi.oshodiscourses")
    }

    @Test
    fun recordsVersionAndCooldownBeforeRequestingAndSuppressesReentry() = runTest {
        val engagement = engagement()
        var requests = 0
        lateinit var prompter: PlayReviewPrompter
        prompter = prompter(engagement) {
            requests++
            assertThat(savedVersion()).isEqualTo("2.0")
            assertThat(engagement.history.value.lastRatingAttempt).isEqualTo(clock.nowMillis)
            assertThat(runBlocking { prompter.attempt() }).isFalse()
        }
        assertThat(prompter.attempt()).isTrue()
        assertThat(requests).isEqualTo(1)
    }

    @Test
    fun existingVersionKeyStillPreventsARequestWithoutATimestamp() = runTest {
        reviewFile.writeText("""{"review.lastPromptedVersion":"2.0"}""")
        val engagement = engagement()
        assertThat(prompter(engagement).attempt()).isFalse()
        assertThat(engagement.history.value.lastRatingAttempt).isNull()
        assertThat(prompter(engagement, version = "2.1").attempt()).isTrue()
    }

    @Test
    fun newVersionDoesNotBypassNinetyDayCooldownAcrossRelaunch() = runTest {
        val firstAttempt = clock.nowMillis
        assertThat(prompter(engagement()).attempt()).isTrue()
        val relaunched = engagement()
        clock.nowMillis = firstAttempt + 90 * day - 1
        assertThat(prompter(relaunched, version = "2.1").attempt()).isFalse()
        clock.nowMillis = firstAttempt + 90 * day
        assertThat(prompter(relaunched).attempt()).isFalse()
        assertThat(prompter(relaunched, version = "2.1").attempt()).isTrue()
    }

    @Test
    fun futurePersistedRatingTimestampDoesNotAllowANewVersionRequest() = runTest {
        engagementFile.writeText("""{"${EngagementHistory.Keys.LAST_RATING_ATTEMPT}":${clock.nowMillis + day}}""")
        val relaunched = engagement()
        assertThat(prompter(relaunched).attempt()).isFalse()
        assertThat(savedVersion()).isNull()
    }

    @Test
    fun freshUsersPlaybackSleepAndBackgroundDoNotConsumeTheRequest() = runTest {
        val engagement = engagement()
        var launches = 0
        val prompter = prompter(engagement) { launches++ }
        assertThat(prompter.attempt(activeDays = 2)).isFalse()
        assertThat(prompter.attempt(isForeground = false)).isFalse()
        assertThat(prompter.attempt(isPlaying = true)).isFalse()
        assertThat(prompter.attempt(sleepTimerArmed = true)).isFalse()
        assertThat(engagement.history.value.lastRatingAttempt).isNull()
        assertThat(savedVersion()).isNull()
        assertThat(launches).isEqualTo(0)
        assertThat(prompter.attempt()).isTrue()
        assertThat(launches).isEqualTo(1)
    }

    @Test
    fun visibleSupportAndRecentSupportExposureBlockNativeRequests() = runTest {
        val engagement = engagement()
        val prompter = prompter(engagement)
        val owner = "home-card"
        val context = SupportContext(
            activeDays = 7, totalListening = 7_200.0, subscriptionStatus = SubscriptionStatus.NOT_SUBSCRIBED,
            isForeground = true, isHomeVisible = true,
        )
        assertThat(engagement.beginSupportPresentation(owner, context)).isTrue()
        assertThat(prompter.attempt()).isFalse()
        assertThat(engagement.recordSupportExposure(owner, context)).isTrue()
        engagement.endSupportPresentation(owner)
        clock.nowMillis += 14 * day - 1
        assertThat(prompter.attempt()).isFalse()
        assertThat(savedVersion()).isNull()
        clock.nowMillis += 1
        assertThat(prompter.attempt()).isTrue()
    }

    @Test
    fun pauseAndFinishHooksReadTheLiveListeningState() = runTest {
        var launches = 0
        val prompter = prompter(engagement()) { launches++ }

        stats.stats.value = ListeningStats(distinctActiveDays = 3, totalToday = 19 * 60.0)
        prompter.listenerDidPause()
        sleepTimer.state.value = SleepTimerState(SleepTimerMode.END_OF_DISCOURSE)
        prompter.discourseDidFinish(naturally = true, playbackContinues = false, sleepTimerWasArmed = false)
        sleepTimer.state.value = SleepTimerState()
        prompter.discourseDidFinish(naturally = true, playbackContinues = true, sleepTimerWasArmed = false)
        prompter.discourseDidFinish(naturally = false, playbackContinues = false, sleepTimerWasArmed = false)
        playing = true
        prompter.discourseDidFinish(naturally = true, playbackContinues = false, sleepTimerWasArmed = false)
        playing = false
        foreground = false
        prompter.discourseDidFinish(naturally = true, playbackContinues = false, sleepTimerWasArmed = false)
        foreground = true
        assertThat(launches).isEqualTo(0)

        stats.stats.value = ListeningStats(distinctActiveDays = 3, totalToday = 20 * 60.0)
        prompter.listenerDidPause()
        assertThat(launches).isEqualTo(1)
    }

    @Test
    fun naturalFinishAsksOnce() = runTest {
        var launches = 0
        val prompter = prompter(engagement()) { launches++ }
        prompter.discourseDidFinish(naturally = true, playbackContinues = false, sleepTimerWasArmed = false)
        prompter.discourseDidFinish(naturally = true, playbackContinues = false, sleepTimerWasArmed = false)
        assertThat(launches).isEqualTo(1)
    }
}
