package com.agraabhi.oshodiscourses.billing.engagement

import android.app.Activity
import android.content.Context
import com.agraabhi.oshodiscourses.billing.JsonFileStore
import com.agraabhi.oshodiscourses.core.domain.engagement.EngagementService
import com.agraabhi.oshodiscourses.core.domain.engagement.ReviewPrompter
import com.agraabhi.oshodiscourses.core.domain.sleep.SleepTimer
import com.agraabhi.oshodiscourses.core.domain.stats.ListeningStatsRepository
import com.google.android.play.core.ktx.launchReview
import com.google.android.play.core.ktx.requestReview
import com.google.android.play.core.review.ReviewManagerFactory
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
internal data class ReviewRecord(
    @SerialName(ReviewPrompter.LAST_PROMPTED_VERSION_KEY) val lastPromptedVersion: String? = null,
)

/** Shows Play's in-app review card; Play decides whether it actually appears. */
internal fun interface ReviewLauncher {
    fun launch()
}

/**
 * Rating requests at idle listening breaks (iOS `ReviewRequestService`). [isPlaying] is a provider
 * so `:app` can wire the player after this prompter exists.
 */
class PlayReviewPrompter internal constructor(
    private val engagement: EngagementService,
    private val listeningStats: ListeningStatsRepository,
    private val sleepTimer: SleepTimer,
    private val isPlaying: () -> Boolean,
    private val isForeground: () -> Boolean,
    private val currentVersion: String,
    private val store: JsonFileStore<ReviewRecord>,
    private val launcher: ReviewLauncher,
) : ReviewPrompter {
    constructor(
        context: Context,
        activityProvider: () -> Activity?,
        scope: CoroutineScope,
        engagement: EngagementService,
        listeningStats: ListeningStatsRepository,
        sleepTimer: SleepTimer,
        isPlaying: () -> Boolean,
    ) : this(
        engagement = engagement,
        listeningStats = listeningStats,
        sleepTimer = sleepTimer,
        isPlaying = isPlaying,
        isForeground = { activityProvider() != null },
        currentVersion = appVersion(context),
        store = JsonFileStore(File(context.filesDir, FILE_NAME), ReviewRecord.serializer(), ReviewRecord()),
        launcher = PlayReviewLauncher(context, activityProvider, scope),
    )

    private var lastPromptedVersion: String? = store.read().lastPromptedVersion

    override val writeReviewURL: String = WRITE_REVIEW_URL

    override suspend fun listenerDidPause() {
        if (!ReviewPolicy.isGoodPauseMoment(listeningStats.stats.value.totalToday, sleepTimer.state.value.isActive)) return
        requestReviewIfAppropriate()
    }

    override suspend fun discourseDidFinish(naturally: Boolean, playbackContinues: Boolean, sleepTimerWasArmed: Boolean) {
        if (!ReviewPolicy.isGoodMoment(naturally, playbackContinues, sleepTimerWasArmed)) return
        requestReviewIfAppropriate()
    }

    private suspend fun requestReviewIfAppropriate() {
        attemptReview(
            activeDays = listeningStats.stats.value.distinctActiveDays,
            isForeground = isForeground(),
            isPlaying = isPlaying(),
            sleepTimerArmed = sleepTimer.state.value.isActive,
        )
    }

    internal suspend fun attemptReview(activeDays: Int, isForeground: Boolean, isPlaying: Boolean, sleepTimerArmed: Boolean): Boolean {
        if (!isForeground || isPlaying || sleepTimerArmed) return false
        if (!ReviewPolicy.isEligible(activeDays, lastPromptedVersion, currentVersion)) return false
        if (!engagement.recordRatingAttemptIfAllowed()) return false
        // Play may not show the card; the attempt still consumes both gates.
        lastPromptedVersion = currentVersion
        store.write { ReviewRecord(lastPromptedVersion) }
        launcher.launch()
        return true
    }

    internal companion object {
        const val FILE_NAME = "review_prompt.json"
        const val WRITE_REVIEW_URL =
            "https://play.google.com/store/apps/details?id=com.agraabhi.oshodiscourses&showAllReviews=true"

        fun appVersion(context: Context): String =
            context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: "0"
    }
}

internal object ReviewPolicy {
    fun isEligible(activeDays: Int, lastPromptedVersion: String?, currentVersion: String): Boolean =
        activeDays >= ReviewPrompter.ACTIVE_DAYS_THRESHOLD && lastPromptedVersion != currentVersion

    fun isGoodMoment(completionWasNatural: Boolean, playbackContinues: Boolean, sleepTimerWasArmed: Boolean): Boolean =
        completionWasNatural && !playbackContinues && !sleepTimerWasArmed

    fun isGoodPauseMoment(listenedToday: Double, sleepTimerWasArmed: Boolean): Boolean =
        listenedToday >= ReviewPrompter.PAUSE_MOMENT_LISTENING_SECONDS && !sleepTimerWasArmed
}

/** Runs in [scope] so the player's pause or finish handling never waits on the review card. */
private class PlayReviewLauncher(
    context: Context,
    private val activityProvider: () -> Activity?,
    private val scope: CoroutineScope,
) : ReviewLauncher {
    private val manager = ReviewManagerFactory.create(context.applicationContext)

    override fun launch() {
        scope.launch(Dispatchers.Main) {
            try {
                val info = manager.requestReview()
                val activity = activityProvider() ?: return@launch
                manager.launchReview(activity, info)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                // Play quota, no Play Store or no network: the attempt is spent either way.
            }
        }
    }
}
