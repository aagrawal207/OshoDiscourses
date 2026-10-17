package com.agraabhi.oshodiscourses.core.data.settings

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.doublePreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.emptyPreferences
import androidx.datastore.preferences.core.stringPreferencesKey
import com.agraabhi.oshodiscourses.core.domain.settings.SettingsRepository
import com.agraabhi.oshodiscourses.core.domain.settings.UserSettings
import com.agraabhi.oshodiscourses.core.domain.settings.UserSettings.Keys
import com.agraabhi.oshodiscourses.core.model.AccentTheme
import com.agraabhi.oshodiscourses.core.model.Appearance
import com.agraabhi.oshodiscourses.core.model.DenoiseStrength
import com.agraabhi.oshodiscourses.core.model.LanguageFilter
import com.agraabhi.oshodiscourses.core.model.NoiseReductionMode
import com.agraabhi.oshodiscourses.core.model.VoiceFocusPreset
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.IOException
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.temporal.ChronoUnit

/**
 * [SettingsRepository] over DataStore Preferences with the iOS UserDefaults keys. A key that
 * was never written reads as the iOS registered default; a saved value always wins.
 */
class DataStoreSettingsRepository(
    private val dataStore: DataStore<Preferences>,
    private val clock: () -> Long = System::currentTimeMillis,
    private val zone: () -> ZoneId = ZoneId::systemDefault,
) : SettingsRepository {

    private val writeLock = Mutex()

    // A blocking first read, as iOS reads UserDefaults in init: the first frame needs the
    // stored appearance and accent, not the defaults.
    private val mutable = MutableStateFlow(
        decode(runBlocking { dataStore.data.catch { if (it is IOException) emit(emptyPreferences()) else throw it }.first() }),
    )

    override val settings: StateFlow<UserSettings> = mutable.asStateFlow()

    override suspend fun setAppearance(value: Appearance) = put(APPEARANCE, value.rawValue) { copy(appearance = value) }

    override suspend fun setAccentTheme(value: AccentTheme) = put(ACCENT_THEME, value.rawValue) { copy(accentTheme = value) }

    override suspend fun setDailyAccentShuffle(enabled: Boolean) =
        put(DAILY_ACCENT_SHUFFLE, enabled) { copy(dailyAccentShuffle = enabled, shuffledThemeToday = todaysShuffledTheme()) }

    override suspend fun setLanguageFilter(value: LanguageFilter) = put(LANGUAGE_FILTER, value.rawValue) { copy(languageFilter = value) }

    override suspend fun setSmartDownload(enabled: Boolean) = put(SMART_DOWNLOAD, enabled) { copy(smartDownload = enabled) }

    override suspend fun setSmartDelete(enabled: Boolean) = put(SMART_DELETE, enabled) { copy(smartDelete = enabled) }

    override suspend fun setAutoPlayNext(enabled: Boolean) = put(AUTO_PLAY_NEXT, enabled) { copy(autoPlayNext = enabled) }

    override suspend fun setAllowCellularDownloads(enabled: Boolean) =
        put(ALLOW_CELLULAR_DOWNLOADS, enabled) { copy(allowCellularDownloads = enabled) }

    override suspend fun setNoiseReduction(enabled: Boolean) = put(NOISE_REDUCTION, enabled) { copy(noiseReduction = enabled) }

    override suspend fun setDenoiseStrength(value: DenoiseStrength) = put(DENOISE_STRENGTH, value.rawValue) { copy(denoiseStrength = value) }

    override suspend fun setNoiseReductionMode(value: NoiseReductionMode) =
        put(NOISE_REDUCTION_MODE, value.rawValue) { copy(noiseReductionMode = value) }

    override suspend fun setVoiceFocusPreset(value: VoiceFocusPreset) =
        put(VOICE_FOCUS_PRESET, value.rawValue) { copy(voiceFocusPreset = value) }

    override suspend fun setDefaultPlaybackRate(value: Double) = put(DEFAULT_PLAYBACK_RATE, value) { copy(defaultPlaybackRate = value) }

    override suspend fun setVolumeBoost(value: Double) = put(VOLUME_BOOST, value) { copy(volumeBoost = value) }

    override suspend fun setTranscriptFontSize(value: Double) = put(TRANSCRIPT_FONT_SIZE, value) { copy(transcriptFontSize = value) }

    override suspend fun setTranscriptSentenceLayout(enabled: Boolean) =
        put(TRANSCRIPT_SENTENCE_LAYOUT, enabled) { copy(transcriptSentenceLayout = enabled) }

    override suspend fun setTranscriptSpeechSync(enabled: Boolean) =
        put(TRANSCRIPT_SPEECH_SYNC, enabled) { copy(transcriptSpeechSync = enabled) }

    override suspend fun refreshShuffledTheme() {
        writeLock.withLock { mutable.update { it.copy(shuffledThemeToday = todaysShuffledTheme()) } }
    }

    /** Whole local-calendar days from the day of the Unix epoch to today, as iOS counts them. */
    fun daysSinceEpoch(): Long {
        val z = zone()
        val start = Instant.EPOCH.atZone(z).toLocalDate()
        val today = Instant.ofEpochMilli(clock()).atZone(z).toLocalDate()
        return ChronoUnit.DAYS.between(start, today)
    }

    private fun todaysShuffledTheme(): AccentTheme = AccentTheme.shuffled(daysSinceEpoch())

    // Serialised so a slower edit cannot publish an older value over a newer one.
    private suspend fun <T> put(key: Preferences.Key<T>, value: T, transform: UserSettings.() -> UserSettings) {
        writeLock.withLock {
            try {
                dataStore.edit { it[key] = value }
            } catch (_: IOException) {
                // iOS never fails a defaults write; keep the choice for this session.
            }
            mutable.update(transform)
        }
    }

    private fun decode(p: Preferences) = UserSettings(
        appearance = Appearance.fromRawValue(p[APPEARANCE]) ?: Appearance.LIGHT,
        accentTheme = AccentTheme.fromRawValue(p[ACCENT_THEME]) ?: AccentTheme.PURPLE,
        dailyAccentShuffle = p[DAILY_ACCENT_SHUFFLE] ?: false,
        shuffledThemeToday = todaysShuffledTheme(),
        languageFilter = LanguageFilter.fromRawValue(p[LANGUAGE_FILTER]) ?: LanguageFilter.BOTH,
        smartDownload = p[SMART_DOWNLOAD] ?: true,
        smartDelete = p[SMART_DELETE] ?: false,
        autoPlayNext = p[AUTO_PLAY_NEXT] ?: true,
        allowCellularDownloads = p[ALLOW_CELLULAR_DOWNLOADS] ?: false,
        noiseReduction = p[NOISE_REDUCTION] ?: false,
        denoiseStrength = DenoiseStrength.fromRawValue(p[DENOISE_STRENGTH]) ?: DenoiseStrength.MEDIUM,
        noiseReductionMode = NoiseReductionMode.fromRawValue(p[NOISE_REDUCTION_MODE]) ?: NoiseReductionMode.DEEP_FILTER_NET,
        voiceFocusPreset = VoiceFocusPreset.fromRawValue(p[VOICE_FOCUS_PRESET]) ?: VoiceFocusPreset.LIFT,
        defaultPlaybackRate = p[DEFAULT_PLAYBACK_RATE] ?: 1.0,
        volumeBoost = p[VOLUME_BOOST] ?: 2.0,
        transcriptFontSize = p[TRANSCRIPT_FONT_SIZE] ?: UserSettings.DEFAULT_TRANSCRIPT_FONT_SIZE,
        transcriptSentenceLayout = p[TRANSCRIPT_SENTENCE_LAYOUT] ?: true,
        transcriptSpeechSync = p[TRANSCRIPT_SPEECH_SYNC] ?: false,
    )

    companion object {
        /** DataStore file name; the coordinator creates exactly one store over it per process. */
        const val DATA_STORE_NAME: String = "settings"

        internal val APPEARANCE = stringPreferencesKey(Keys.APPEARANCE)
        internal val ACCENT_THEME = stringPreferencesKey(Keys.ACCENT_THEME)
        internal val DAILY_ACCENT_SHUFFLE = booleanPreferencesKey(Keys.DAILY_ACCENT_SHUFFLE)
        internal val LANGUAGE_FILTER = stringPreferencesKey(Keys.LANGUAGE_FILTER)
        internal val SMART_DOWNLOAD = booleanPreferencesKey(Keys.SMART_DOWNLOAD)
        internal val SMART_DELETE = booleanPreferencesKey(Keys.SMART_DELETE)
        internal val AUTO_PLAY_NEXT = booleanPreferencesKey(Keys.AUTO_PLAY_NEXT)
        internal val ALLOW_CELLULAR_DOWNLOADS = booleanPreferencesKey(Keys.ALLOW_CELLULAR_DOWNLOADS)
        internal val NOISE_REDUCTION = booleanPreferencesKey(Keys.NOISE_REDUCTION)
        internal val DENOISE_STRENGTH = stringPreferencesKey(Keys.DENOISE_STRENGTH)
        internal val NOISE_REDUCTION_MODE = stringPreferencesKey(Keys.NOISE_REDUCTION_MODE)
        internal val VOICE_FOCUS_PRESET = stringPreferencesKey(Keys.VOICE_FOCUS_PRESET)
        internal val DEFAULT_PLAYBACK_RATE = doublePreferencesKey(Keys.DEFAULT_PLAYBACK_RATE)
        internal val VOLUME_BOOST = doublePreferencesKey(Keys.VOLUME_BOOST)
        internal val TRANSCRIPT_FONT_SIZE = doublePreferencesKey(Keys.TRANSCRIPT_FONT_SIZE)
        internal val TRANSCRIPT_SENTENCE_LAYOUT = booleanPreferencesKey(Keys.TRANSCRIPT_SENTENCE_LAYOUT)
        internal val TRANSCRIPT_SPEECH_SYNC = booleanPreferencesKey(Keys.TRANSCRIPT_SPEECH_SYNC)
    }
}
