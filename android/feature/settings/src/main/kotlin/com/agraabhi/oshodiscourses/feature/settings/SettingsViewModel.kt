package com.agraabhi.oshodiscourses.feature.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.agraabhi.oshodiscourses.core.domain.settings.SettingsRepository
import com.agraabhi.oshodiscourses.core.domain.settings.UserSettings
import com.agraabhi.oshodiscourses.core.domain.sync.SyncController
import com.agraabhi.oshodiscourses.core.domain.sync.SyncStatus
import com.agraabhi.oshodiscourses.core.model.AccentTheme
import com.agraabhi.oshodiscourses.core.model.Appearance
import com.agraabhi.oshodiscourses.core.model.CatalogRepository
import com.agraabhi.oshodiscourses.core.model.LanguageFilter
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

internal data class SettingsUiState(
    val settings: UserSettings = UserSettings(),
    val sync: SyncStatus = SyncStatus.Idle,
    val seriesCount: Int = 0,
    val discourseCount: Int = 0,
) {
    /** Idle covers a device that never connected; both need the user to sign in. */
    val isSyncConnected: Boolean get() = sync !is SyncStatus.Idle && sync !is SyncStatus.SignInNeeded

    val syncSubtitle: String
        get() = when (val s = sync) {
            SyncStatus.Idle, SyncStatus.SignInNeeded -> "Not connected"
            SyncStatus.Syncing -> "Syncing…"
            is SyncStatus.UpToDate -> "On"
            is SyncStatus.Failed -> s.message
        }
}

/** iOS `SettingsView` over `UserSettings`, plus the Android-only Google Drive sync row. */
internal class SettingsViewModel(
    private val settings: SettingsRepository,
    private val sync: SyncController,
    catalog: CatalogRepository,
) : ViewModel() {
    private val seriesCount = catalog.allSeries.size
    private val discourseCount = catalog.allSeries.sumOf { it.count }

    val state: StateFlow<SettingsUiState> = combine(settings.settings, sync.status) { s, status ->
        SettingsUiState(s, status, seriesCount, discourseCount)
    }.stateIn(
        viewModelScope,
        SharingStarted.Eagerly,
        SettingsUiState(settings.settings.value, sync.status.value, seriesCount, discourseCount),
    )

    fun setLanguage(value: LanguageFilter) = launch { settings.setLanguageFilter(value) }

    fun setAutoPlayNext(enabled: Boolean) = launch { settings.setAutoPlayNext(enabled) }

    fun setSmartDownload(enabled: Boolean) = launch { settings.setSmartDownload(enabled) }

    fun setSmartDelete(enabled: Boolean) = launch { settings.setSmartDelete(enabled) }

    /** The download engine observes the setting and moves waiting transfers onto mobile data. */
    fun setAllowCellular(enabled: Boolean) = launch { settings.setAllowCellularDownloads(enabled) }

    fun setAppearance(value: Appearance) = launch { settings.setAppearance(value) }

    /** Tapping a colour pins it and turns off the daily shuffle. */
    fun pickAccent(value: AccentTheme) = launch {
        settings.setDailyAccentShuffle(false)
        settings.setAccentTheme(value)
    }

    fun setShuffle(enabled: Boolean) = launch { settings.setDailyAccentShuffle(enabled) }

    fun signIn() = launch { sync.requestAuthorization() }

    fun syncNow() = launch { sync.syncNow() }

    /** "Stop Syncing" also withdraws the Drive grant, so the account no longer lists the app. */
    fun stopSyncing() = launch { sync.disconnect() }

    private fun launch(block: suspend () -> Unit) = viewModelScope.launch { block() }
}
