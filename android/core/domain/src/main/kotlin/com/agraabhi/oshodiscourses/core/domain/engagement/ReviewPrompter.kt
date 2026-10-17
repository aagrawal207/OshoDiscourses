package com.agraabhi.oshodiscourses.core.domain.engagement

/**
 * Native Play In-App Review requests at idle listening breaks (iOS `ReviewRequestService`).
 * Asks only after [ACTIVE_DAYS_THRESHOLD] listening days, once per app version, never while
 * playing or with the sleep timer armed, and only when [EngagementService] allows it.
 */
interface ReviewPrompter {
    /** After a pause from an on-screen control, with at least 20 minutes listened today. */
    suspend fun listenerDidPause()

    /** After a discourse finishes; asks only on a natural finish where playback stops. */
    suspend fun discourseDidFinish(naturally: Boolean, playbackContinues: Boolean, sleepTimerWasArmed: Boolean)

    /** Settings > About > Rate Osho Talks opens the store listing directly. */
    val writeReviewURL: String

    companion object {
        const val ACTIVE_DAYS_THRESHOLD: Int = 3
        const val PAUSE_MOMENT_LISTENING_SECONDS: Double = 20.0 * 60
        const val LAST_PROMPTED_VERSION_KEY: String = "review.lastPromptedVersion"
    }
}
