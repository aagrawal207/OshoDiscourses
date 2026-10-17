package com.agraabhi.oshodiscourses.feature.settings

import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasScrollToNodeAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.agraabhi.oshodiscourses.core.domain.support.PurchaseState
import com.agraabhi.oshodiscourses.core.model.Appearance
import com.github.takahirom.roborazzi.captureRoboImage
import com.github.takahirom.roborazzi.captureScreenRoboImage
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.flow.update
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

private const val DIR = "src/test/screenshots"
private const val FULL = "w393dp-h1700dp-xxhdpi"

@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], qualifiers = "w393dp-h852dp-xxhdpi")
class TipJarScreenshotTest {
    @get:Rule
    val compose = createComposeRule()

    private var done = 0
    private var cleared = 0

    private fun page(services: ScriptedServices, appearance: Appearance = Appearance.LIGHT, fontScale: Float = 1f, withClear: Boolean = false) {
        compose.show(services, appearance, fontScale, elevated = true) {
            SupportDevelopmentPage(onDone = { done++ }, onClearDeclinedRequest = if (withClear) ({ cleared++ }) else null)
        }
    }

    private fun capture(name: String) = compose.onRoot().captureRoboImage("$DIR/$name.png")

    private fun settle() {
        compose.waitForIdle()
        compose.mainClock.advanceTimeBy(1_000)
        compose.waitForIdle()
    }

    @Test fun light() = page(ScriptedServices()).also { capture("tipjar_light") }

    @Test fun dark() = page(ScriptedServices(), Appearance.DARK).also { capture("tipjar_dark") }

    @Test
    fun fullLight() {
        RuntimeEnvironment.setQualifiers(FULL)
        page(ScriptedServices().also { it.store.tipJar.update { s -> s.copy(tipCount = 3) } })
        capture("tipjar_full_light")
    }

    @Test
    fun fullDark() {
        RuntimeEnvironment.setQualifiers(FULL)
        page(ScriptedServices(), Appearance.DARK)
        capture("tipjar_full_dark")
    }

    @Test fun loading() = page(ScriptedServices(ScriptedSupportStore(loadsHang = true))).also { capture("tipjar_loading") }

    @Test
    fun loadErrors() {
        RuntimeEnvironment.setQualifiers(FULL)
        val store = ScriptedSupportStore(
            tipsError = "Couldn't load tips from Google Play. Check your connection and try again.",
            annualError = "Couldn't load yearly support from Google Play. Check your connection and try again.",
        )
        store.annualSupport.update { it.copy(statusError = "Couldn't check your existing yearly support. Try again before starting a subscription.") }
        page(ScriptedServices(store))
        capture("tipjar_errors")
    }

    @Test
    fun subscribedAndRestored() {
        RuntimeEnvironment.setQualifiers(FULL)
        val services = ScriptedServices()
        page(services, Appearance.DARK)
        compose.onNode(hasText("Generous yearly support") and hasClickAction()).performClick()
        compose.onNodeWithText("OK").performClick()
        compose.onNodeWithText("Restore Subscription").performClick()
        settle()
        capture("tipjar_subscribed_dark")
    }

    @Test
    fun pendingYearlyRequest() {
        RuntimeEnvironment.setQualifiers(FULL)
        val services = ScriptedServices(ScriptedSupportStore(nextResult = PurchaseState.Pending))
        page(services, withClear = true)
        compose.onNode(hasText("Small yearly support") and hasClickAction()).performClick()
        settle()
        capture("tipjar_pending")
        compose.onNodeWithText("Got It").performClick()
        compose.waitForIdle()
        compose.onNodeWithText("Purchase pending").assertDoesNotExist()
        compose.onNodeWithText("Awaiting approval").assertExists()
        compose.onNodeWithText("Request Was Declined").performClick()
        settle()
        captureScreenRoboImage("$DIR/tipjar_clear_pending_dialog.png")
        compose.onNodeWithText("Clear Declined Request").performClick()
        assertThat(cleared).isEqualTo(1)
    }

    @Test
    fun thankYouAlertAfterATip() {
        val services = ScriptedServices()
        page(services)
        compose.onNode(hasText("Small tip") and hasClickAction()).performClick()
        settle()
        captureScreenRoboImage("$DIR/tipjar_thank_you_alert.png")
        compose.onNodeWithText("Your tip keeps this app going. Enjoy the talks.").assertExists()
        compose.onNodeWithText("OK").performClick()
        compose.waitForIdle()
        compose.onNode(hasScrollToNodeAction()).performScrollToNode(hasText("One tip recorded on this device. Thank you."))
        assertThat(services.store.calls).contains("purchaseTip:com.agraabhi.oshodiscourses.tip.small")
        assertThat(services.store.tipJar.value.state).isEqualTo(PurchaseState.Idle)
        compose.onNodeWithText("One tip recorded on this device. Thank you.").assertExists()
    }

    @Test
    fun failedTipShowsTheStoreMessage() {
        val services = ScriptedServices(ScriptedSupportStore(nextResult = PurchaseState.Failed("This tip is not available. Please reload the tip jar.")))
        page(services)
        compose.onNode(hasText("Big tip") and hasClickAction()).performClick()
        compose.onNodeWithText("Couldn't confirm tip").assertExists()
        compose.onNodeWithText("This tip is not available. Please reload the tip jar.").assertExists()
    }

    @Test
    fun yearlyRowsWaitForAStatusCheckAndLockAfterSubscribing() {
        RuntimeEnvironment.setQualifiers(FULL)
        val services = ScriptedServices()
        page(services)
        compose.onNode(hasText("Extra yearly support") and hasClickAction()).assertIsEnabled()
        compose.onNode(hasText("Extra yearly support") and hasClickAction()).performClick()
        compose.onNodeWithText("OK").performClick()
        compose.waitForIdle()
        compose.onNodeWithText("Current yearly plan").assertExists()
        compose.onNode(hasText("Small yearly support") and hasClickAction()).assertIsNotEnabled()
        compose.onNodeWithText("Thank you for your yearly support").assertExists()
    }

    @Test
    fun sheetRegistersWithEngagementAndDoneCallsBack() {
        val services = ScriptedServices()
        page(services)
        assertThat(services.base.engagement.isSupportPresentationActive.value).isTrue()
        compose.onNodeWithText("Done").performClick()
        assertThat(done).isEqualTo(1)
    }

    @Test
    fun font200StacksRows() {
        RuntimeEnvironment.setQualifiers("w393dp-h3000dp-xxhdpi")
        page(ScriptedServices(), fontScale = 2f)
        capture("tipjar_font200")
    }

    @Test
    fun font150() {
        RuntimeEnvironment.setQualifiers(FULL)
        page(ScriptedServices(), fontScale = 1.5f)
        capture("tipjar_font150")
    }

    @Test
    fun smallPhone() {
        RuntimeEnvironment.setQualifiers("w360dp-h740dp-xhdpi")
        page(ScriptedServices())
        capture("tipjar_small_phone")
    }
}
