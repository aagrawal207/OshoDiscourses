package com.agraabhi.oshodiscourses.core.domain.settings

import com.agraabhi.oshodiscourses.core.model.AccentTheme
import com.agraabhi.oshodiscourses.core.model.Appearance
import com.agraabhi.oshodiscourses.core.model.DenoiseStrength
import com.agraabhi.oshodiscourses.core.model.LanguageFilter
import com.agraabhi.oshodiscourses.core.model.NoiseReductionMode
import com.agraabhi.oshodiscourses.core.model.VoiceFocusPreset
import kotlinx.coroutines.flow.StateFlow

/**
 * Per-device preferences (iOS `UserSettings` over UserDefaults; DataStore here). Settings
 * are not synced between devices. Each setter persists immediately.
 */
interface SettingsRepository {
    val settings: StateFlow<UserSettings>

    suspend fun setAppearance(value: Appearance)

    /** Pins a colour. The Settings picker also turns [setDailyAccentShuffle] off, as on iOS. */
    suspend fun setAccentTheme(value: AccentTheme)

    suspend fun setDailyAccentShuffle(enabled: Boolean)

    suspend fun setLanguageFilter(value: LanguageFilter)

    suspend fun setSmartDownload(enabled: Boolean)

    suspend fun setSmartDelete(enabled: Boolean)

    suspend fun setAutoPlayNext(enabled: Boolean)

    suspend fun setAllowCellularDownloads(enabled: Boolean)

    suspend fun setNoiseReduction(enabled: Boolean)

    suspend fun setDenoiseStrength(value: DenoiseStrength)

    suspend fun setNoiseReductionMode(value: NoiseReductionMode)

    suspend fun setVoiceFocusPreset(value: VoiceFocusPreset)

    /** Stored as given; callers normalise through `PlaybackSpeed`. */
    suspend fun setDefaultPlaybackRate(value: Double)

    suspend fun setVolumeBoost(value: Double)

    suspend fun setTranscriptFontSize(value: Double)

    suspend fun setTranscriptSentenceLayout(enabled: Boolean)

    suspend fun setTranscriptSpeechSync(enabled: Boolean)

    /** Recomputes today's shuffled colour; call at launch and on returning to the foreground. */
    suspend fun refreshShuffledTheme()
}

/**
 * Every iOS `UserSettings` field with the same defaults. Persisted keys match iOS:
 *
 * | Field | iOS key | Default |
 * | --- | --- | --- |
 * | [appearance] | `settings.appearance` | `light` (first launch is light; a stored value wins) |
 * | [accentTheme] | `settings.accentTheme` | `purple` |
 * | [dailyAccentShuffle] | `settings.dailyAccentShuffle` | `false` |
 * | [languageFilter] | `settings.languageFilter` | `Both` |
 * | [smartDownload] | `settings.smartDownload` | `true` |
 * | [smartDelete] | `settings.smartDelete` | `false` |
 * | [autoPlayNext] | `settings.autoPlayNext` | `true` |
 * | [allowCellularDownloads] | `settings.allowCellularDownloads` | `false` |
 * | [noiseReduction] | `settings.noiseReduction` | `false` |
 * | [denoiseStrength] | `settings.denoiseStrength` | `medium` |
 * | [noiseReductionMode] | `settings.noiseReductionMode` | `deepFilterNet` |
 * | [voiceFocusPreset] | `settings.voiceFocusPreset` | `lift` |
 * | [defaultPlaybackRate] | `settings.defaultPlaybackRate` | `1.0` |
 * | [volumeBoost] | `settings.volumeBoost` | `2.0` |
 * | [transcriptFontSize] | `settings.transcriptFontSize` | `19` |
 * | [transcriptSentenceLayout] | `settings.transcriptSentenceLayout` | `true` |
 * | [transcriptSpeechSync] | `settings.transcriptSpeechSync` | `false` |
 *
 * [shuffledThemeToday] is derived from the date, not stored.
 */
data class UserSettings(
    val appearance: Appearance = Appearance.LIGHT,
    val accentTheme: AccentTheme = AccentTheme.PURPLE,
    /** When on, the accent advances to the next palette colour each day. */
    val dailyAccentShuffle: Boolean = false,
    val shuffledThemeToday: AccentTheme = AccentTheme.BLUE,
    val languageFilter: LanguageFilter = LanguageFilter.BOTH,
    val smartDownload: Boolean = true,
    val smartDelete: Boolean = false,
    val autoPlayNext: Boolean = true,
    /** Off keeps downloads on Wi-Fi so Smart Download never pulls 20-30 MB talks over mobile data. */
    val allowCellularDownloads: Boolean = false,
    val noiseReduction: Boolean = false,
    val denoiseStrength: DenoiseStrength = DenoiseStrength.MEDIUM,
    val noiseReductionMode: NoiseReductionMode = NoiseReductionMode.DEEP_FILTER_NET,
    val voiceFocusPreset: VoiceFocusPreset = VoiceFocusPreset.LIFT,
    /** 0.5-2.0, written back by the player's speed control. */
    val defaultPlaybackRate: Double = 1.0,
    /** New installs start at 2x; turning Boost off persists 1.0. */
    val volumeBoost: Double = 2.0,
    val transcriptFontSize: Double = DEFAULT_TRANSCRIPT_FONT_SIZE,
    val transcriptSentenceLayout: Boolean = true,
    val transcriptSpeechSync: Boolean = false,
) {
    /** The accent used app-wide. */
    val effectiveAccentTheme: AccentTheme get() = if (dailyAccentShuffle) shuffledThemeToday else accentTheme

    val hideHindi: Boolean get() = languageFilter == LanguageFilter.ENGLISH
    val hideEnglish: Boolean get() = languageFilter == LanguageFilter.HINDI

    companion object {
        val TRANSCRIPT_FONT_SIZES: List<Double> = listOf(15.0, 17.0, 19.0, 21.0, 24.0, 28.0)
        const val DEFAULT_TRANSCRIPT_FONT_SIZE: Double = 19.0
    }

    /** The iOS UserDefaults keys, reused as DataStore keys. */
    object Keys {
        const val APPEARANCE = "settings.appearance"
        const val ACCENT_THEME = "settings.accentTheme"
        const val DAILY_ACCENT_SHUFFLE = "settings.dailyAccentShuffle"
        const val LANGUAGE_FILTER = "settings.languageFilter"
        const val SMART_DOWNLOAD = "settings.smartDownload"
        const val SMART_DELETE = "settings.smartDelete"
        const val AUTO_PLAY_NEXT = "settings.autoPlayNext"
        const val ALLOW_CELLULAR_DOWNLOADS = "settings.allowCellularDownloads"
        const val NOISE_REDUCTION = "settings.noiseReduction"
        const val DENOISE_STRENGTH = "settings.denoiseStrength"
        const val NOISE_REDUCTION_MODE = "settings.noiseReductionMode"
        const val VOICE_FOCUS_PRESET = "settings.voiceFocusPreset"
        const val DEFAULT_PLAYBACK_RATE = "settings.defaultPlaybackRate"
        const val VOLUME_BOOST = "settings.volumeBoost"
        const val TRANSCRIPT_FONT_SIZE = "settings.transcriptFontSize"
        const val TRANSCRIPT_SENTENCE_LAYOUT = "settings.transcriptSentenceLayout"
        const val TRANSCRIPT_SPEECH_SYNC = "settings.transcriptSpeechSync"
    }
}
