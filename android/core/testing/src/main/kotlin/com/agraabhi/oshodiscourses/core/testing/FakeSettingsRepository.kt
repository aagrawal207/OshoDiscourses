package com.agraabhi.oshodiscourses.core.testing

import com.agraabhi.oshodiscourses.core.domain.settings.SettingsRepository
import com.agraabhi.oshodiscourses.core.domain.settings.UserSettings
import com.agraabhi.oshodiscourses.core.model.AccentTheme
import com.agraabhi.oshodiscourses.core.model.Appearance
import com.agraabhi.oshodiscourses.core.model.DenoiseStrength
import com.agraabhi.oshodiscourses.core.model.LanguageFilter
import com.agraabhi.oshodiscourses.core.model.NoiseReductionMode
import com.agraabhi.oshodiscourses.core.model.VoiceFocusPreset
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update

class FakeSettingsRepository(
    initial: UserSettings = UserSettings(),
    private val daysSinceEpoch: () -> Long = { 0 },
) : SettingsRepository {
    private val mutable = MutableStateFlow(initial)
    override val settings: StateFlow<UserSettings> = mutable

    private fun set(transform: UserSettings.() -> UserSettings) = mutable.update(transform)

    override suspend fun setAppearance(value: Appearance) = set { copy(appearance = value) }
    override suspend fun setAccentTheme(value: AccentTheme) = set { copy(accentTheme = value) }
    override suspend fun setDailyAccentShuffle(enabled: Boolean) = set {
        copy(dailyAccentShuffle = enabled, shuffledThemeToday = AccentTheme.shuffled(daysSinceEpoch()))
    }
    override suspend fun setLanguageFilter(value: LanguageFilter) = set { copy(languageFilter = value) }
    override suspend fun setSmartDownload(enabled: Boolean) = set { copy(smartDownload = enabled) }
    override suspend fun setSmartDelete(enabled: Boolean) = set { copy(smartDelete = enabled) }
    override suspend fun setAutoPlayNext(enabled: Boolean) = set { copy(autoPlayNext = enabled) }
    override suspend fun setAllowCellularDownloads(enabled: Boolean) = set { copy(allowCellularDownloads = enabled) }
    override suspend fun setNoiseReduction(enabled: Boolean) = set { copy(noiseReduction = enabled) }
    override suspend fun setDenoiseStrength(value: DenoiseStrength) = set { copy(denoiseStrength = value) }
    override suspend fun setNoiseReductionMode(value: NoiseReductionMode) = set { copy(noiseReductionMode = value) }
    override suspend fun setVoiceFocusPreset(value: VoiceFocusPreset) = set { copy(voiceFocusPreset = value) }
    override suspend fun setDefaultPlaybackRate(value: Double) = set { copy(defaultPlaybackRate = value) }
    override suspend fun setVolumeBoost(value: Double) = set { copy(volumeBoost = value) }
    override suspend fun setTranscriptFontSize(value: Double) = set { copy(transcriptFontSize = value) }
    override suspend fun setTranscriptSentenceLayout(enabled: Boolean) = set { copy(transcriptSentenceLayout = enabled) }
    override suspend fun setTranscriptSpeechSync(enabled: Boolean) = set { copy(transcriptSpeechSync = enabled) }
    override suspend fun refreshShuffledTheme() = set { copy(shuffledThemeToday = AccentTheme.shuffled(daysSinceEpoch())) }
}
