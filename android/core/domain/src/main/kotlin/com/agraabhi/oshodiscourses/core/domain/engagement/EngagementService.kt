package com.agraabhi.oshodiscourses.core.domain.engagement

import kotlinx.coroutines.flow.StateFlow

/**
 * Gentle support and rating asks (iOS `EngagementService`). The Home support card appears only
 * after 7 listening days and 2 hours of use, at a quiet Home moment, never during playback;
 * it can be snoozed for 90 days or turned off. Rating and support asks keep 14 days apart.
 * [owner] identifies one presentation (a card or sheet instance).
 */
interface EngagementService {
    val history: StateFlow<EngagementHistory>

    val isSupportPresentationActive: StateFlow<Boolean>

    fun canShowSupportCard(owner: String, context: SupportContext): Boolean

    fun beginSupportPresentation(owner: String, context: SupportContext): Boolean

    /** Starts the next cooldown the first time a card is actually seen. */
    suspend fun recordSupportExposure(owner: String, context: SupportContext): Boolean

    fun endSupportPresentation(owner: String)

    /** "Not now" snoozes for 90 days; [permanently] opts out. */
    suspend fun dismissSupport(owner: String, context: SupportContext, permanently: Boolean)

    suspend fun openSupportSheet(owner: String, context: SupportContext): Boolean

    fun endSupportSheet(owner: String)

    /** A support sheet opened from Settings, which blocks the card and rating asks. */
    fun registerSupportSheet(owner: String)

    fun unregisterSupportSheet(owner: String)

    /** Consumes the rating gates when allowed; returns whether a rating request may be shown. */
    suspend fun recordRatingAttemptIfAllowed(): Boolean

    /** Refreshes subscription status only when it is unknown and everything else allows a card. */
    suspend fun refreshSupportStatusIfNeeded(context: SupportContext, refresh: suspend () -> Unit)

    companion object {
        const val SUPPORT_ACTIVE_DAYS_THRESHOLD: Int = 7
        const val SUPPORT_LISTENING_THRESHOLD_SECONDS: Double = 2.0 * 60 * 60
        const val PROMPT_COOLDOWN_MILLIS: Long = 90L * 24 * 60 * 60 * 1000
        const val CROSS_PROMPT_COOLDOWN_MILLIS: Long = 14L * 24 * 60 * 60 * 1000
    }
}

enum class SubscriptionStatus { UNKNOWN, NOT_SUBSCRIBED, SUBSCRIBED }

/** Everything that decides whether this is a quiet moment for a support card. */
data class SupportContext(
    val activeDays: Int = 0,
    /** Seconds. */
    val totalListening: Double = 0.0,
    val tipCount: Int = 0,
    val subscriptionStatus: SubscriptionStatus = SubscriptionStatus.UNKNOWN,
    val isForeground: Boolean = false,
    val isHomeVisible: Boolean = false,
    val isPlaying: Boolean = false,
    val sleepTimerArmed: Boolean = false,
    val playerPresented: Boolean = false,
    val otherPresentationActive: Boolean = false,
    val storeIsBusy: Boolean = false,
)

/** Epoch milliseconds. iOS keys: `review.lastPromptedAt`, `engagement.lastSupportExposureAt`, ... */
data class EngagementHistory(
    val lastRatingAttempt: Long? = null,
    val lastSupportExposure: Long? = null,
    val supportSnoozedAt: Long? = null,
    val supportOptedOut: Boolean = false,
) {
    object Keys {
        const val LAST_RATING_ATTEMPT = "review.lastPromptedAt"
        const val LAST_SUPPORT_EXPOSURE = "engagement.lastSupportExposureAt"
        const val SUPPORT_SNOOZED_AT = "engagement.supportSnoozedAt"
        const val SUPPORT_OPTED_OUT = "engagement.supportOptedOut"
    }
}
