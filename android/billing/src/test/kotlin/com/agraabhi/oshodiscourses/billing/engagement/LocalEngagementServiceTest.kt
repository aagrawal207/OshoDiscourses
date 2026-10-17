package com.agraabhi.oshodiscourses.billing.engagement

import com.agraabhi.oshodiscourses.billing.Gate
import com.agraabhi.oshodiscourses.billing.JsonFileStore
import com.agraabhi.oshodiscourses.core.domain.engagement.EngagementHistory
import com.agraabhi.oshodiscourses.core.domain.engagement.SubscriptionStatus
import com.agraabhi.oshodiscourses.core.domain.engagement.SupportContext
import com.agraabhi.oshodiscourses.core.testing.FakeClock
import com.google.common.truth.Truth.assertThat
import java.io.File
import java.util.UUID
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class LocalEngagementServiceTest {
    @get:Rule val folder = TemporaryFolder()

    private val date = 1_800_000_000_000L
    private val day = 24L * 60 * 60 * 1000
    private val clock = FakeClock(date)

    private val established = SupportContext(
        activeDays = 7,
        totalListening = 7_200.0,
        subscriptionStatus = SubscriptionStatus.NOT_SUBSCRIBED,
        isForeground = true,
        isHomeVisible = true,
    )

    private val interruptedContexts = listOf(
        established.copy(isForeground = false),
        established.copy(isHomeVisible = false),
        established.copy(isPlaying = true),
        established.copy(sleepTimerArmed = true),
        established.copy(playerPresented = true),
        established.copy(otherPresentationActive = true),
        established.copy(storeIsBusy = true),
    )

    private val file get() = File(folder.root, "engagement.json")

    private fun service() =
        LocalEngagementService(JsonFileStore(file, EngagementRecord.serializer(), EngagementRecord())) { clock.nowMillis }

    private fun owner() = UUID.randomUUID().toString()

    private fun eligible(context: SupportContext, history: EngagementHistory = EngagementHistory(), now: Long = date) =
        EngagementPolicy.isSupportEligible(context, history, now)

    private fun ratingEligible(history: EngagementHistory, now: Long = date) =
        EngagementPolicy.isRatingEligible(history, supportPresentationActive = false, now = now)

    @Test
    fun supportRequiresBothSevenListeningDaysAndTwoHours() {
        assertThat(eligible(established)).isTrue()
        assertThat(eligible(established.copy(activeDays = 0))).isFalse()
        assertThat(eligible(established.copy(activeDays = 6, totalListening = 100_000.0))).isFalse()
        assertThat(eligible(established.copy(totalListening = 7_199.0))).isFalse()
        assertThat(eligible(established.copy(activeDays = 100, totalListening = 7_199.0))).isFalse()
        assertThat(eligible(established.copy(activeDays = 100))).isTrue()
        assertThat(eligible(established.copy(totalListening = Double.NaN))).isFalse()
        assertThat(eligible(established.copy(totalListening = Double.POSITIVE_INFINITY))).isFalse()
    }

    @Test
    fun contributorsAndUnknownSubscriptionStatusNeverSeeSupport() {
        assertThat(eligible(established.copy(tipCount = 1))).isFalse()
        assertThat(eligible(established.copy(subscriptionStatus = SubscriptionStatus.SUBSCRIBED))).isFalse()
        assertThat(eligible(established.copy(subscriptionStatus = SubscriptionStatus.UNKNOWN))).isFalse()
        assertThat(eligible(established)).isTrue()
    }

    @Test
    fun supportRequiresAnUncoveredIdleForegroundHome() {
        for (context in interruptedContexts) {
            assertThat(eligible(context)).isFalse()
            assertThat(EngagementPolicy.isQuietHomeMoment(context)).isFalse()
        }
        assertThat(eligible(established)).isTrue()
    }

    @Test
    fun exposureAndSnoozeHaveExactNinetyDayBoundaries() {
        for (history in listOf(EngagementHistory(lastSupportExposure = date), EngagementHistory(supportSnoozedAt = date))) {
            assertThat(eligible(established, history, date + 90 * day - 1)).isFalse()
            assertThat(eligible(established, history, date + 90 * day)).isTrue()
        }
    }

    @Test
    fun ratingHasAnExactNinetyDayBoundary() {
        val history = EngagementHistory(lastRatingAttempt = date)
        assertThat(ratingEligible(history, date + 90 * day - 1)).isFalse()
        assertThat(ratingEligible(history, date + 90 * day)).isTrue()
    }

    @Test
    fun crossPromptSpacingHasAnExactFourteenDayBoundaryInBothDirections() {
        val rating = EngagementHistory(lastRatingAttempt = date)
        assertThat(eligible(established, rating, date + 14 * day - 1)).isFalse()
        assertThat(eligible(established, rating, date + 14 * day)).isTrue()
        val support = EngagementHistory(lastSupportExposure = date)
        assertThat(ratingEligible(support, date + 14 * day - 1)).isFalse()
        assertThat(ratingEligible(support, date + 14 * day)).isTrue()
    }

    @Test
    fun futureTimestampsFailClosedForOwnAndCrossPromptCooldowns() {
        val future = date + day
        assertThat(eligible(established, EngagementHistory(lastSupportExposure = future))).isFalse()
        assertThat(eligible(established, EngagementHistory(supportSnoozedAt = future))).isFalse()
        assertThat(eligible(established, EngagementHistory(lastRatingAttempt = future))).isFalse()
        assertThat(ratingEligible(EngagementHistory(lastRatingAttempt = future))).isFalse()
        assertThat(ratingEligible(EngagementHistory(lastSupportExposure = future))).isFalse()
        assertThat(eligible(established, EngagementHistory(lastSupportExposure = future), date + 90 * day)).isFalse()
        assertThat(eligible(established, EngagementHistory(lastSupportExposure = future), future + 90 * day)).isTrue()
    }

    @Test
    fun claimingACardIsNotAnExposureAndOnlyOneWindowCanClaim() = runTest {
        val service = service()
        val first = owner()
        val second = owner()
        assertThat(service.beginSupportPresentation(first, established)).isTrue()
        assertThat(service.beginSupportPresentation(second, established)).isFalse()
        assertThat(service.history.value.lastSupportExposure).isNull()
        assertThat(service.isSupportPresentationActive.value).isTrue()
        assertThat(service.recordRatingAttemptIfAllowed()).isFalse()
        service.endSupportPresentation(second)
        assertThat(service.supportCardOwner).isEqualTo(first)
        service.endSupportPresentation(first)
        assertThat(service.isSupportPresentationActive.value).isFalse()
        assertThat(service.beginSupportPresentation(second, established)).isTrue()
    }

    @Test
    fun exposurePersistsBeforeRelaunchWithoutHidingTheVisibleCard() = runTest {
        val service = service()
        val owner = owner()
        assertThat(service.beginSupportPresentation(owner, established)).isTrue()
        assertThat(service.recordSupportExposure(owner, established)).isTrue()
        assertThat(service.history.value.lastSupportExposure).isEqualTo(date)
        val saved = Json.parseToJsonElement(file.readText()).jsonObject
        assertThat(saved[EngagementHistory.Keys.LAST_SUPPORT_EXPOSURE].toString()).isEqualTo(date.toString())
        assertThat(service.canShowSupportCard(owner, established)).isTrue()
        clock.nowMillis = date + day
        assertThat(service.recordSupportExposure(owner, established)).isTrue()
        assertThat(service.history.value.lastSupportExposure).isEqualTo(date)
        assertThat(service.canShowSupportCard(owner, established)).isTrue()

        val relaunched = service()
        assertThat(relaunched.beginSupportPresentation(owner(), established)).isFalse()
        assertThat(relaunched.recordRatingAttemptIfAllowed()).isFalse()
        service.endSupportPresentation(owner)
        assertThat(service.canShowSupportCard(owner, established)).isFalse()
        clock.nowMillis = date + 90 * day
        assertThat(relaunched.beginSupportPresentation(owner(), established)).isTrue()
    }

    @Test
    fun unexposedCardCanBeOfferedAfterRelaunch() {
        val service = service()
        assertThat(service.beginSupportPresentation(owner(), established)).isTrue()
        assertThat(service().beginSupportPresentation(owner(), established)).isTrue()
    }

    @Test
    fun staleOrUnsafeExposureCallbacksDoNotRecordAnything() = runTest {
        val service = service()
        val owner = owner()
        assertThat(service.recordSupportExposure(owner, established)).isFalse()
        assertThat(service.beginSupportPresentation(owner, established)).isTrue()
        assertThat(service.recordSupportExposure(owner(), established)).isFalse()
        for (context in interruptedContexts) {
            assertThat(service.canShowSupportCard(owner, context)).isFalse()
            assertThat(service.recordSupportExposure(owner, context)).isFalse()
        }
        for (contributor in listOf(
            established.copy(tipCount = 1),
            established.copy(subscriptionStatus = SubscriptionStatus.SUBSCRIBED),
            established.copy(subscriptionStatus = SubscriptionStatus.UNKNOWN),
        )) {
            assertThat(service.canShowSupportCard(owner, contributor)).isFalse()
            assertThat(service.recordSupportExposure(owner, contributor)).isFalse()
        }
        assertThat(service.history.value.lastSupportExposure).isNull()
    }

    @Test
    fun notNowSnoozesForNinetyDaysFromDismissalAndSurvivesRelaunch() = runTest {
        val service = service()
        val owner = owner()
        assertThat(service.beginSupportPresentation(owner, established)).isTrue()
        assertThat(service.recordSupportExposure(owner, established)).isTrue()
        clock.nowMillis = date + day
        service.dismissSupport(owner, established, permanently = false)
        assertThat(service.isSupportPresentationActive.value).isFalse()
        assertThat(service.history.value.supportSnoozedAt).isEqualTo(date + day)
        val relaunched = service()
        clock.nowMillis = date + 91 * day - 1
        assertThat(relaunched.beginSupportPresentation(owner(), established)).isFalse()
        clock.nowMillis = date + 91 * day
        assertThat(relaunched.beginSupportPresentation(owner(), established)).isTrue()
    }

    @Test
    fun dontAskAgainIsPermanentAcrossRelaunchesButDoesNotDisableRatings() = runTest {
        val service = service()
        val owner = owner()
        assertThat(service.beginSupportPresentation(owner, established)).isTrue()
        service.dismissSupport(owner, established, permanently = true)
        assertThat(service.history.value.supportOptedOut).isTrue()
        assertThat(service.history.value.lastSupportExposure).isEqualTo(date)
        clock.nowMillis = date + 365 * day
        val relaunched = service()
        assertThat(relaunched.beginSupportPresentation(owner(), established)).isFalse()
        val unknown = established.copy(subscriptionStatus = SubscriptionStatus.UNKNOWN)
        assertThat(EngagementPolicy.shouldCheckSupportStatus(unknown, relaunched.history.value, clock.nowMillis)).isFalse()
        assertThat(relaunched.recordRatingAttemptIfAllowed()).isTrue()
    }

    @Test
    fun staleWindowCannotDismissOrOpenAnotherWindowsCard() = runTest {
        val service = service()
        val owner = owner()
        val staleOwner = owner()
        assertThat(service.beginSupportPresentation(owner, established)).isTrue()
        service.dismissSupport(staleOwner, established, permanently = true)
        assertThat(service.history.value.supportOptedOut).isFalse()
        assertThat(service.openSupportSheet(staleOwner, established)).isFalse()
        assertThat(service.supportCardOwner).isEqualTo(owner)
        assertThat(service.history.value.lastSupportExposure).isNull()
    }

    @Test
    fun openingSupportRecordsExposureAndKeepsRatingsBlockedUntilSheetCloses() = runTest {
        val service = service()
        val owner = owner()
        assertThat(service.beginSupportPresentation(owner, established)).isTrue()
        assertThat(service.openSupportSheet(owner, established)).isTrue()
        assertThat(service.history.value.lastSupportExposure).isEqualTo(date)
        assertThat(service.supportCardOwner).isNull()
        assertThat(service.supportSheetOwner).isEqualTo(owner)
        assertThat(service.beginSupportPresentation(owner(), established)).isFalse()
        clock.nowMillis = date + 14 * day
        assertThat(service.recordRatingAttemptIfAllowed()).isFalse()
        service.endSupportSheet(owner())
        assertThat(service.recordRatingAttemptIfAllowed()).isFalse()
        service.endSupportSheet(owner)
        assertThat(service.recordRatingAttemptIfAllowed()).isTrue()
    }

    @Test
    fun anOpenCardBlocksRatingsEvenAfterCrossPromptCooldown() = runTest {
        val service = service()
        val owner = owner()
        assertThat(service.beginSupportPresentation(owner, established)).isTrue()
        assertThat(service.recordSupportExposure(owner, established)).isTrue()
        clock.nowMillis = date + 14 * day
        assertThat(service.recordRatingAttemptIfAllowed()).isFalse()
        service.endSupportPresentation(owner)
        assertThat(service.recordRatingAttemptIfAllowed()).isTrue()
    }

    @Test
    fun manuallyOpenedSupportSheetsBlockRatingsAcrossWindows() = runTest {
        val service = service()
        val first = owner()
        val second = owner()
        service.registerSupportSheet(first)
        service.registerSupportSheet(second)
        assertThat(service.recordRatingAttemptIfAllowed()).isFalse()
        assertThat(service.canShowSupportCard(owner(), established)).isFalse()
        service.unregisterSupportSheet(first)
        assertThat(service.recordRatingAttemptIfAllowed()).isFalse()
        service.unregisterSupportSheet(second)
        assertThat(service.recordRatingAttemptIfAllowed()).isTrue()
    }

    @Test
    fun ratingAttemptsPersistAcrossRelaunchAndBlockSupportForFourteenDays() = runTest {
        val service = service()
        assertThat(service.recordRatingAttemptIfAllowed()).isTrue()
        assertThat(service.history.value.lastRatingAttempt).isEqualTo(date)
        val relaunched = service()
        assertThat(relaunched.recordRatingAttemptIfAllowed()).isFalse()
        clock.nowMillis = date + 14 * day - 1
        assertThat(relaunched.beginSupportPresentation(owner(), established)).isFalse()
        clock.nowMillis = date + 14 * day
        assertThat(relaunched.canShowSupportCard(owner(), established)).isTrue()
        clock.nowMillis = date + 90 * day - 1
        assertThat(relaunched.recordRatingAttemptIfAllowed()).isFalse()
        clock.nowMillis = date + 90 * day
        assertThat(relaunched.recordRatingAttemptIfAllowed()).isTrue()
    }

    @Test
    fun statusCheckRequiresEstablishedUseWithoutContributionsOrInterruptions() = runTest {
        val service = service()
        val unknown = established.copy(subscriptionStatus = SubscriptionStatus.UNKNOWN)
        val blocked = interruptedContexts.map { it.copy(subscriptionStatus = SubscriptionStatus.UNKNOWN) } + listOf(
            established,
            unknown.copy(activeDays = 6),
            unknown.copy(totalListening = 7_199.0),
            unknown.copy(tipCount = 1),
            unknown.copy(subscriptionStatus = SubscriptionStatus.SUBSCRIBED),
        )
        var calls = 0
        for (context in blocked) service.refreshSupportStatusIfNeeded(context) { calls++ }
        assertThat(calls).isEqualTo(0)
        service.refreshSupportStatusIfNeeded(unknown) { calls++ }
        assertThat(calls).isEqualTo(1)
    }

    @Test
    fun statusCheckRespectsAllPersistedSupportGates() {
        val unknown = established.copy(subscriptionStatus = SubscriptionStatus.UNKNOWN)
        for (history in listOf(
            EngagementHistory(lastSupportExposure = date),
            EngagementHistory(supportSnoozedAt = date),
            EngagementHistory(lastRatingAttempt = date),
            EngagementHistory(supportOptedOut = true),
        )) {
            assertThat(EngagementPolicy.shouldCheckSupportStatus(unknown, history, date)).isFalse()
        }
    }

    @Test
    fun concurrentWindowsShareOneInFlightStatusLookupAndCanRetryLater() = runTest {
        val service = service()
        val unknown = established.copy(subscriptionStatus = SubscriptionStatus.UNKNOWN)
        val entered = Gate()
        val release = Gate()
        var calls = 0
        val checking = launch {
            service.refreshSupportStatusIfNeeded(unknown) {
                calls++
                entered.open()
                release.await()
            }
        }
        entered.await()
        service.refreshSupportStatusIfNeeded(unknown) { calls++ }
        assertThat(calls).isEqualTo(1)
        release.open()
        checking.join()
        service.refreshSupportStatusIfNeeded(unknown) { calls++ }
        assertThat(calls).isEqualTo(2)
    }
}
