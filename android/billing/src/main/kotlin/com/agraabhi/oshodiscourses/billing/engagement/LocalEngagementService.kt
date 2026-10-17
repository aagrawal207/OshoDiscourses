package com.agraabhi.oshodiscourses.billing.engagement

import android.content.Context
import com.agraabhi.oshodiscourses.billing.JsonFileStore
import com.agraabhi.oshodiscourses.core.domain.engagement.EngagementHistory
import com.agraabhi.oshodiscourses.core.domain.engagement.EngagementService
import com.agraabhi.oshodiscourses.core.domain.engagement.SubscriptionStatus
import com.agraabhi.oshodiscourses.core.domain.engagement.SupportContext
import java.io.File
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** The persisted [EngagementHistory], under the iOS `UserDefaults` key names. */
@Serializable
internal data class EngagementRecord(
    @SerialName(EngagementHistory.Keys.LAST_RATING_ATTEMPT) val lastRatingAttempt: Long? = null,
    @SerialName(EngagementHistory.Keys.LAST_SUPPORT_EXPOSURE) val lastSupportExposure: Long? = null,
    @SerialName(EngagementHistory.Keys.SUPPORT_SNOOZED_AT) val supportSnoozedAt: Long? = null,
    @SerialName(EngagementHistory.Keys.SUPPORT_OPTED_OUT) val supportOptedOut: Boolean = false,
) {
    fun toHistory() = EngagementHistory(lastRatingAttempt, lastSupportExposure, supportSnoozedAt, supportOptedOut)
}

internal fun EngagementHistory.toRecord() =
    EngagementRecord(lastRatingAttempt, lastSupportExposure, supportSnoozedAt, supportOptedOut)

/**
 * Gentle support and rating asks (iOS `EngagementService`), persisted in `engagement.json`.
 * Only one owner can hold the Home card; open support sheets block the card and rating asks.
 */
class LocalEngagementService internal constructor(
    private val store: JsonFileStore<EngagementRecord>,
    private val now: () -> Long,
) : EngagementService {
    constructor(context: Context) : this(
        JsonFileStore(File(context.filesDir, FILE_NAME), EngagementRecord.serializer(), EngagementRecord()),
        System::currentTimeMillis,
    )

    private val lock = Any()
    private val _history = MutableStateFlow(store.read().toHistory())
    override val history: StateFlow<EngagementHistory> = _history

    private val active = MutableStateFlow(false)
    override val isSupportPresentationActive: StateFlow<Boolean> = active

    internal var supportCardOwner: String? = null
        private set
    internal var supportSheetOwner: String? = null
        private set
    private val externalSupportSheets = mutableSetOf<String>()
    private var exposedOwner: String? = null
    private var checkingSupportStatus = false

    private fun refreshActive() {
        active.value = supportCardOwner != null || supportSheetOwner != null || externalSupportSheets.isNotEmpty()
    }

    override fun canShowSupportCard(owner: String, context: SupportContext): Boolean {
        synchronized(lock) {
            if (supportSheetOwner != null || externalSupportSheets.isNotEmpty()) return false
            val cardOwner = supportCardOwner
            if (cardOwner != null) {
                if (cardOwner != owner) return false
                // Exposure starts the next cooldown without removing the card being read.
                return EngagementPolicy.hasEstablishedUse(context) && EngagementPolicy.isQuietHomeMoment(context) &&
                    context.tipCount == 0 && context.subscriptionStatus == SubscriptionStatus.NOT_SUBSCRIBED &&
                    !_history.value.supportOptedOut
            }
            return EngagementPolicy.isSupportEligible(context, _history.value, now())
        }
    }

    override fun beginSupportPresentation(owner: String, context: SupportContext): Boolean {
        synchronized(lock) {
            if (!canShowSupportCard(owner, context)) return false
            supportCardOwner = owner
            refreshActive()
            return true
        }
    }

    override suspend fun recordSupportExposure(owner: String, context: SupportContext): Boolean {
        synchronized(lock) {
            if (supportCardOwner != owner || !canShowSupportCard(owner, context)) return false
            if (exposedOwner == owner) return true
            _history.value = _history.value.copy(lastSupportExposure = now())
            exposedOwner = owner
        }
        persist()
        return true
    }

    override fun endSupportPresentation(owner: String) {
        synchronized(lock) {
            if (supportCardOwner != owner) return
            supportCardOwner = null
            exposedOwner = null
            refreshActive()
        }
    }

    override suspend fun dismissSupport(owner: String, context: SupportContext, permanently: Boolean) {
        if (!recordSupportExposure(owner, context)) return
        synchronized(lock) {
            _history.value = if (permanently) {
                _history.value.copy(supportOptedOut = true)
            } else {
                _history.value.copy(supportSnoozedAt = now())
            }
        }
        persist()
        endSupportPresentation(owner)
    }

    override suspend fun openSupportSheet(owner: String, context: SupportContext): Boolean {
        if (!recordSupportExposure(owner, context)) return false
        synchronized(lock) {
            supportSheetOwner = owner
            endSupportPresentation(owner)
            refreshActive()
        }
        return true
    }

    override fun endSupportSheet(owner: String) {
        synchronized(lock) {
            if (supportSheetOwner == owner) supportSheetOwner = null
            refreshActive()
        }
    }

    override fun registerSupportSheet(owner: String) {
        synchronized(lock) {
            externalSupportSheets += owner
            refreshActive()
        }
    }

    override fun unregisterSupportSheet(owner: String) {
        synchronized(lock) {
            externalSupportSheets -= owner
            refreshActive()
        }
    }

    override suspend fun recordRatingAttemptIfAllowed(): Boolean {
        synchronized(lock) {
            val time = now()
            if (!EngagementPolicy.isRatingEligible(_history.value, active.value, time)) return false
            _history.value = _history.value.copy(lastRatingAttempt = time)
        }
        persist()
        return true
    }

    override suspend fun refreshSupportStatusIfNeeded(context: SupportContext, refresh: suspend () -> Unit) {
        synchronized(lock) {
            if (checkingSupportStatus || !EngagementPolicy.shouldCheckSupportStatus(context, _history.value, now())) return
            checkingSupportStatus = true
        }
        try {
            refresh()
        } finally {
            synchronized(lock) { checkingSupportStatus = false }
        }
    }

    private suspend fun persist() = store.write { _history.value.toRecord() }

    internal companion object {
        const val FILE_NAME = "engagement.json"
    }
}

/** The pure eligibility rules, separate so tests can check exact boundaries. */
internal object EngagementPolicy {
    fun hasEstablishedUse(context: SupportContext): Boolean =
        context.activeDays >= EngagementService.SUPPORT_ACTIVE_DAYS_THRESHOLD &&
            context.totalListening.isFinite() &&
            context.totalListening >= EngagementService.SUPPORT_LISTENING_THRESHOLD_SECONDS

    fun isQuietHomeMoment(context: SupportContext): Boolean =
        context.isForeground && context.isHomeVisible && !context.isPlaying && !context.sleepTimerArmed &&
            !context.playerPresented && !context.otherPresentationActive && !context.storeIsBusy

    fun isSupportEligible(context: SupportContext, history: EngagementHistory, now: Long): Boolean =
        hasEstablishedUse(context) && isQuietHomeMoment(context) && context.tipCount == 0 &&
            context.subscriptionStatus == SubscriptionStatus.NOT_SUBSCRIBED && supportTimingAllows(history, now)

    fun shouldCheckSupportStatus(context: SupportContext, history: EngagementHistory, now: Long): Boolean =
        hasEstablishedUse(context) && isQuietHomeMoment(context) && context.tipCount == 0 &&
            context.subscriptionStatus == SubscriptionStatus.UNKNOWN && supportTimingAllows(history, now)

    fun isRatingEligible(history: EngagementHistory, supportPresentationActive: Boolean, now: Long): Boolean =
        !supportPresentationActive &&
            cooldownHasElapsed(history.lastRatingAttempt, EngagementService.PROMPT_COOLDOWN_MILLIS, now) &&
            cooldownHasElapsed(history.lastSupportExposure, EngagementService.CROSS_PROMPT_COOLDOWN_MILLIS, now)

    private fun supportTimingAllows(history: EngagementHistory, now: Long): Boolean =
        !history.supportOptedOut &&
            cooldownHasElapsed(history.lastSupportExposure, EngagementService.PROMPT_COOLDOWN_MILLIS, now) &&
            cooldownHasElapsed(history.supportSnoozedAt, EngagementService.PROMPT_COOLDOWN_MILLIS, now) &&
            cooldownHasElapsed(history.lastRatingAttempt, EngagementService.CROSS_PROMPT_COOLDOWN_MILLIS, now)

    // A clock rollback must not turn a recent attempt into permission to ask again.
    private fun cooldownHasElapsed(since: Long?, interval: Long, now: Long): Boolean = since == null || now - since >= interval
}
