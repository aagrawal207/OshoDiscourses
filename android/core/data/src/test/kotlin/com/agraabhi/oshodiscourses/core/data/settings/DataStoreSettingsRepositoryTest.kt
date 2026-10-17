package com.agraabhi.oshodiscourses.core.data.settings

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.doublePreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import com.agraabhi.oshodiscourses.core.domain.settings.UserSettings
import com.agraabhi.oshodiscourses.core.model.AccentTheme
import com.agraabhi.oshodiscourses.core.model.Appearance
import com.agraabhi.oshodiscourses.core.model.DenoiseStrength
import com.agraabhi.oshodiscourses.core.model.LanguageFilter
import com.agraabhi.oshodiscourses.core.model.NoiseReductionMode
import com.agraabhi.oshodiscourses.core.model.VoiceFocusPreset
import com.agraabhi.oshodiscourses.core.testing.FakeClock
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.job
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.time.ZoneId
import java.time.ZoneOffset

/** Ports `UserSettingsTests` against a real DataStore file. */
class DataStoreSettingsRepositoryTest {
    @get:Rule val folder = TemporaryFolder()

    /** 2026-10-17T12:00:00Z, local-calendar day 20743 since the epoch in UTC. */
    private val clock = FakeClock(1_792_238_400_000L)
    private val scopes = mutableListOf<CoroutineScope>()
    private val file by lazy { File(folder.root, "settings.preferences_pb") }

    @After fun tearDown() = closeStores()

    private fun closeStores() = runBlocking { scopes.forEach { it.coroutineContext.job.cancelAndJoin() } }

    // DataStore allows one active store per file, so a relaunch closes the previous one first.
    private fun store(): DataStore<Preferences> {
        closeStores()
        val scope = CoroutineScope(Dispatchers.IO + SupervisorJob()).also { scopes += it }
        return PreferenceDataStoreFactory.create(scope = scope, produceFile = { file })
    }

    private fun repo(store: DataStore<Preferences> = store(), zone: ZoneId = ZoneOffset.UTC) =
        DataStoreSettingsRepository(store, { clock.nowMillis }, { zone })

    private fun saved(store: DataStore<Preferences>): Preferences = runBlocking { store.data.first() }

    @Test fun firstLaunchUsesTheRegisteredDefaults() {
        val s = repo().settings.value
        assertThat(s).isEqualTo(UserSettings(shuffledThemeToday = AccentTheme.MINT))
        assertThat(s.appearance).isEqualTo(Appearance.LIGHT)
        assertThat(s.noiseReduction).isFalse()
        assertThat(s.noiseReductionMode).isEqualTo(NoiseReductionMode.DEEP_FILTER_NET)
        assertThat(s.denoiseStrength).isEqualTo(DenoiseStrength.MEDIUM)
        assertThat(s.voiceFocusPreset).isEqualTo(VoiceFocusPreset.LIFT)
        assertThat(s.volumeBoost).isEqualTo(2.0)
        assertThat(s.defaultPlaybackRate).isEqualTo(1.0)
        assertThat(s.allowCellularDownloads).isFalse()
    }

    @Test fun defaultsAreNotWrittenToTheStore() {
        val store = store()
        repo(store)
        assertThat(saved(store).asMap()).isEmpty()
    }

    @Test fun savedValuesWinOverDefaults() {
        val store = store()
        runBlocking {
            store.edit {
                it[stringPreferencesKey("settings.appearance")] = "dark"
                it[booleanPreferencesKey("settings.smartDownload")] = false
                it[doublePreferencesKey("settings.volumeBoost")] = 1.0
                it[stringPreferencesKey("settings.noiseReductionMode")] = "cadence"
                it[stringPreferencesKey("settings.voiceFocusPreset")] = "strong"
                it[stringPreferencesKey("settings.denoiseStrength")] = "light"
                it[booleanPreferencesKey("settings.noiseReduction")] = true
            }
        }
        val s = repo(store).settings.value
        assertThat(s.appearance).isEqualTo(Appearance.DARK)
        assertThat(s.smartDownload).isFalse()
        assertThat(s.volumeBoost).isEqualTo(1.0)
        assertThat(s.noiseReductionMode).isEqualTo(NoiseReductionMode.CADENCE)
        assertThat(s.voiceFocusPreset).isEqualTo(VoiceFocusPreset.STRONG)
        assertThat(s.denoiseStrength).isEqualTo(DenoiseStrength.LIGHT)
        assertThat(s.noiseReduction).isTrue()
    }

    @Test fun unknownStoredValuesFallBackToDefaults() {
        val store = store()
        runBlocking {
            store.edit {
                it[stringPreferencesKey("settings.accentTheme")] = "chartreuse"
                it[stringPreferencesKey("settings.languageFilter")] = "French"
            }
        }
        val s = repo(store).settings.value
        assertThat(s.accentTheme).isEqualTo(AccentTheme.PURPLE)
        assertThat(s.languageFilter).isEqualTo(LanguageFilter.BOTH)
    }

    @Test fun defaultPlaybackRatePersists() = runBlocking {
        val store = store()
        repo(store).setDefaultPlaybackRate(1.25)
        assertThat(saved(store)[doublePreferencesKey("settings.defaultPlaybackRate")]).isEqualTo(1.25)
        assertThat(repo().settings.value.defaultPlaybackRate).isEqualTo(1.25)
    }

    @Test fun volumeBoostOffPersistsAcrossRelaunch() = runBlocking {
        val store = store()
        val settings = repo(store)
        settings.setVolumeBoost(2.0)
        assertThat(saved(store)[doublePreferencesKey("settings.volumeBoost")]).isEqualTo(2.0)
        settings.setVolumeBoost(1.0)
        assertThat(settings.settings.value.volumeBoost).isEqualTo(1.0)
        assertThat(repo().settings.value.volumeBoost).isEqualTo(1.0)
    }

    @Test fun cellularDownloadsPersists() = runBlocking {
        val store = store()
        val settings = repo(store)
        settings.setAllowCellularDownloads(true)
        assertThat(saved(store)[booleanPreferencesKey("settings.allowCellularDownloads")]).isTrue()
        settings.setAllowCellularDownloads(false)
        assertThat(saved(store)[booleanPreferencesKey("settings.allowCellularDownloads")]).isFalse()
    }

    @Test fun enumsPersistTheirIosRawValues() = runBlocking {
        val store = store()
        val settings = repo(store)
        settings.setLanguageFilter(LanguageFilter.HINDI)
        settings.setNoiseReductionMode(NoiseReductionMode.CADENCE)
        settings.setAppearance(Appearance.SYSTEM)
        settings.setAccentTheme(AccentTheme.INDIGO)
        settings.setDenoiseStrength(DenoiseStrength.STRONG)
        settings.setVoiceFocusPreset(VoiceFocusPreset.FOCUS)
        val p = saved(store)
        assertThat(p[stringPreferencesKey("settings.languageFilter")]).isEqualTo("Hindi")
        assertThat(p[stringPreferencesKey("settings.noiseReductionMode")]).isEqualTo("cadence")
        assertThat(p[stringPreferencesKey("settings.appearance")]).isEqualTo("system")
        assertThat(p[stringPreferencesKey("settings.accentTheme")]).isEqualTo("indigo")
        assertThat(p[stringPreferencesKey("settings.denoiseStrength")]).isEqualTo("strong")
        assertThat(p[stringPreferencesKey("settings.voiceFocusPreset")]).isEqualTo("focus")
    }

    @Test fun everySetterRoundTripsThroughARelaunch() = runBlocking {
        val settings = repo()
        settings.setSmartDownload(false)
        settings.setSmartDelete(true)
        settings.setAutoPlayNext(false)
        settings.setNoiseReduction(true)
        settings.setTranscriptFontSize(24.0)
        settings.setTranscriptSentenceLayout(false)
        settings.setTranscriptSpeechSync(true)
        settings.setDailyAccentShuffle(true)
        val expected = settings.settings.value
        assertThat(repo().settings.value).isEqualTo(expected)
        assertThat(expected.smartDelete).isTrue()
        assertThat(expected.transcriptFontSize).isEqualTo(24.0)
    }

    // Daily accent shuffle

    @Test fun daysSinceEpochCountsLocalCalendarDays() {
        assertThat(repo().daysSinceEpoch()).isEqualTo(20_743)
        // In Los Angeles the epoch fell on 31 December 1969, and noon UTC is still the 17th.
        assertThat(repo(zone = ZoneId.of("America/Los_Angeles")).daysSinceEpoch()).isEqualTo(20_744)
        clock.nowMillis = 0
        assertThat(repo(zone = ZoneId.of("America/Los_Angeles")).daysSinceEpoch()).isEqualTo(0)
    }

    @Test fun shuffleAdvancesEachDayAndCyclesThePalette() {
        for (day in 0L until 30L) assertThat(AccentTheme.shuffled(day)).isNotEqualTo(AccentTheme.shuffled(day + 1))
        assertThat((0L until 8L).map(AccentTheme::shuffled).toSet()).hasSize(8)
        assertThat(AccentTheme.shuffled(-3)).isEqualTo(AccentTheme.GREEN)
    }

    @Test fun effectiveThemeIgnoresShuffleWhenOff() = runBlocking {
        val settings = repo()
        settings.setDailyAccentShuffle(false)
        settings.setAccentTheme(AccentTheme.PINK)
        assertThat(settings.settings.value.effectiveAccentTheme).isEqualTo(AccentTheme.PINK)
    }

    @Test fun effectiveThemeUsesTodaysShuffleWhenOn() = runBlocking {
        val settings = repo()
        settings.setAccentTheme(AccentTheme.PINK)
        settings.setDailyAccentShuffle(true)
        // 20743 % 8 == 7, the eighth palette colour.
        assertThat(settings.settings.value.effectiveAccentTheme).isEqualTo(AccentTheme.MINT)
    }

    @Test fun refreshPicksUpADayRollover() = runBlocking {
        val settings = repo()
        settings.setDailyAccentShuffle(true)
        clock.advance(86_400_000L)
        assertThat(settings.settings.value.effectiveAccentTheme).isEqualTo(AccentTheme.MINT)
        settings.refreshShuffledTheme()
        assertThat(settings.settings.value.effectiveAccentTheme).isEqualTo(AccentTheme.BLUE)
    }
}
