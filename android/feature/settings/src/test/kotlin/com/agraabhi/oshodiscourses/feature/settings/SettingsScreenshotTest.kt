package com.agraabhi.oshodiscourses.feature.settings

import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.hasScrollToNodeAction
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.agraabhi.oshodiscourses.core.domain.settings.UserSettings
import com.agraabhi.oshodiscourses.core.domain.support.PurchaseState
import com.agraabhi.oshodiscourses.core.domain.sync.SyncStatus
import com.agraabhi.oshodiscourses.core.model.AccentTheme
import com.agraabhi.oshodiscourses.core.model.Appearance
import com.agraabhi.oshodiscourses.core.model.LanguageFilter
import com.agraabhi.oshodiscourses.core.model.NoiseReductionMode
import com.agraabhi.oshodiscourses.core.testing.FakeAppServices
import com.agraabhi.oshodiscourses.core.testing.FakeClock
import com.agraabhi.oshodiscourses.core.testing.FakeSettingsRepository
import com.agraabhi.oshodiscourses.core.testing.FakeSyncController
import com.github.takahirom.roborazzi.captureRoboImage
import com.github.takahirom.roborazzi.captureScreenRoboImage
import com.google.common.truth.Truth.assertThat
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

private const val DIR = "src/test/screenshots"
private const val FULL = "w393dp-h2300dp-xxhdpi"

@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], qualifiers = "w393dp-h852dp-xxhdpi")
class SettingsScreenshotTest {
    @get:Rule
    val compose = createComposeRule()

    private var denoiseOpened = 0
    private var supportOpened = 0

    private fun services(
        settings: UserSettings = UserSettings(),
        sync: SyncStatus = SyncStatus.SignInNeeded,
    ): FakeAppServices {
        val clock = FakeClock()
        return FakeAppServices(clock = clock, settings = FakeSettingsRepository(settings), sync = FakeSyncController(sync, clock))
    }

    private fun settings(services: FakeAppServices, appearance: Appearance = Appearance.LIGHT, fontScale: Float = 1f) {
        compose.show(services, appearance, fontScale) {
            SettingsScreen(
                onOpenDenoise = { denoiseOpened++ },
                onOpenListeningStats = {},
                versionName = "1.16.3",
                onOpenSupport = { supportOpened++ },
            )
        }
    }

    private fun capture(name: String) = compose.onRoot().captureRoboImage("$DIR/$name.png")

    @Test fun light() = settings(services()).also { capture("settings_light") }

    @Test fun dark() = settings(services(), Appearance.DARK).also { capture("settings_dark") }

    @Test
    fun fullLight() {
        RuntimeEnvironment.setQualifiers(FULL)
        settings(services())
        capture("settings_full_light")
    }

    @Test
    fun fullDark() {
        RuntimeEnvironment.setQualifiers(FULL)
        settings(services(), Appearance.DARK)
        capture("settings_full_dark")
    }

    @Test
    fun syncedShuffleAndDenoiseOn() {
        RuntimeEnvironment.setQualifiers(FULL)
        val s = UserSettings(
            dailyAccentShuffle = true,
            shuffledThemeToday = AccentTheme.TEAL,
            noiseReduction = true,
            noiseReductionMode = NoiseReductionMode.RNNOISE,
            languageFilter = LanguageFilter.HINDI,
            allowCellularDownloads = true,
        )
        settings(services(s, SyncStatus.UpToDate(0)))
        capture("settings_synced_shuffle_light")
    }

    @Test
    fun syncFailedDark() {
        RuntimeEnvironment.setQualifiers(FULL)
        settings(services(sync = SyncStatus.Failed("Couldn't reach Google Drive. Check your connection.")), Appearance.DARK)
        capture("settings_sync_failed_dark")
    }

    @Test
    fun font150() {
        RuntimeEnvironment.setQualifiers(FULL)
        settings(services(), fontScale = 1.5f)
        capture("settings_font150")
    }

    @Test
    fun font200() {
        RuntimeEnvironment.setQualifiers("w393dp-h3200dp-xxhdpi")
        settings(services(), fontScale = 2f)
        capture("settings_font200")
    }

    @Test
    fun smallPhone() {
        RuntimeEnvironment.setQualifiers("w360dp-h740dp-xhdpi")
        settings(services())
        capture("settings_small_phone")
    }

    @Test
    fun swatchPinsTheColourAndStopsShuffle() {
        val services = services(UserSettings(dailyAccentShuffle = true))
        settings(services)
        compose.onNodeWithContentDescription("Green").performClick()
        compose.waitForIdle()
        val s = services.settings.settings.value
        assertThat(s.accentTheme).isEqualTo(AccentTheme.GREEN)
        assertThat(s.dailyAccentShuffle).isFalse()
    }

    @Test
    fun segmentsAndTogglesWriteSettings() {
        val services = services()
        settings(services)
        compose.onNodeWithText("Hindi").performClick()
        compose.onNodeWithText("Smart Delete").performClick()
        compose.onNodeWithText("Download over Cellular").performClick()
        compose.onNode(hasScrollToNodeAction()).performScrollToNode(hasText("Dark"))
        compose.onNodeWithText("Dark").performClick()
        compose.waitForIdle()
        val s = services.settings.settings.value
        assertThat(s.languageFilter).isEqualTo(LanguageFilter.HINDI)
        assertThat(s.smartDelete).isTrue()
        assertThat(s.allowCellularDownloads).isTrue()
        assertThat(s.appearance).isEqualTo(Appearance.DARK)
    }

    @Test
    fun denoiseAndSupportRowsCallBack() {
        RuntimeEnvironment.setQualifiers(FULL)
        settings(services())
        compose.onNode(hasText("DeNoise") and hasClickAction()).performClick()
        compose.onNode(hasText("Support Development") and hasClickAction()).performClick()
        assertThat(denoiseOpened).isEqualTo(1)
        assertThat(supportOpened).isEqualTo(1)
        compose.onNodeWithText("My Other Apps").assertDoesNotExist()
        compose.onNodeWithText("1.16.3").assertExists()
        compose.onNodeWithText("2").assertExists()
        compose.onNodeWithText("5").assertExists()
    }

    @Test
    fun syncSignInThenStop() {
        RuntimeEnvironment.setQualifiers(FULL)
        val services = services()
        settings(services)
        compose.onNodeWithText("Not connected").assertExists()
        compose.onNodeWithText("Sign In").performClick()
        compose.waitForIdle()
        assertThat(services.sync.status.value).isInstanceOf(SyncStatus.UpToDate::class.java)
        compose.onNodeWithText("Sync Now").performClick()
        compose.waitForIdle()
        assertThat(services.sync.syncCount).isEqualTo(2)
        compose.onNodeWithText("Stop Syncing").performClick()
        compose.waitForIdle()
        assertThat(services.sync.status.value).isEqualTo(SyncStatus.SignInNeeded)
        // Stop Syncing also withdraws the Drive grant.
        assertThat(services.sync.disconnectCount).isEqualTo(1)
    }

    @Test
    fun builtInSupportSheetOpensFromAbout() {
        RuntimeEnvironment.setQualifiers(FULL)
        val scripted = ScriptedServices()
        compose.show(scripted) { SettingsScreen(onOpenDenoise = {}, onOpenListeningStats = {}, versionName = "1.16.3") }
        compose.onNode(hasText("Support Development") and hasClickAction()).performClick()
        compose.waitForIdle()
        compose.mainClock.advanceTimeBy(1_000)
        compose.onNodeWithText("Small tip").assertExists()
        captureScreenRoboImage("$DIR/settings_support_sheet.png")
        assertThat(scripted.store.calls).containsAtLeast("loadTips", "loadAnnual", "refresh")
        assertThat(PurchaseState.Idle).isEqualTo(scripted.store.tipJar.value.state)
    }
}
