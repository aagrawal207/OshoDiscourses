package com.agraabhi.oshodiscourses

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.agraabhi.oshodiscourses.core.domain.bookmarks.BookmarkCategory
import com.agraabhi.oshodiscourses.core.model.Appearance
import com.agraabhi.oshodiscourses.core.model.NoiseReductionMode
import java.time.LocalDate
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Emulator checks without the UI, e.g.
 * `adb shell am broadcast -a com.agraabhi.oshodiscourses.DEBUG -p com.agraabhi.oshodiscourses --es cmd state`.
 * Commands: state, play (id, from), pause, resume, download (id), delete (id), sleep (minutes),
 * sleep_end, sleep_cancel, denoise (on, mode), cellular (on), appearance (value), seed, seed_bookmarks.
 * Results go to logcat tag `DebugCmd`.
 */
class DebugCommandReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val container = (context.applicationContext as OshoApplication).container
        val pending = goAsync()
        scope.launch {
            try {
                run(container, intent)
            } catch (e: Exception) {
                Log.w(TAG, "command failed", e)
            } finally {
                pending.finish()
            }
        }
    }

    private suspend fun run(c: AppContainer, intent: Intent) {
        val id = intent.getStringExtra("id")
        when (val cmd = intent.getStringExtra("cmd")) {
            "play" -> Log.i(TAG, "play=${c.player.play(checkNotNull(id), intent.getStringExtra("from")?.toDouble())}")
            "pause" -> c.player.pause()
            "resume" -> c.player.resume()
            "download" -> c.downloads.enqueue(checkNotNull(id))
            "delete" -> c.downloads.delete(checkNotNull(id))
            "sleep" -> c.sleepTimer.start(intent.getIntExtra("minutes", 1))
            "sleep_end" -> c.sleepTimer.startUntilEndOfDiscourse()
            "sleep_cancel" -> c.sleepTimer.cancel()
            "denoise" -> {
                intent.getStringExtra("mode")?.let { NoiseReductionMode.fromRawValue(it) }?.let { c.denoise.setMode(it) }
                c.denoise.setEnabled(intent.getBooleanExtra("on", true))
            }
            "cellular" -> c.settings.setAllowCellularDownloads(intent.getBooleanExtra("on", true))
            "appearance" -> Appearance.fromRawValue(intent.getStringExtra("value"))?.let { c.settings.setAppearance(it) }
            "seed" -> seedParityState(c)
            "seed_bookmarks" -> seedParityBookmarks(c)
            "state", null -> Unit
            else -> Log.w(TAG, "unknown cmd=$cmd")
        }
        val p = c.player.state.value
        Log.i(
            TAG,
            "player track=${p.currentTrackId} playing=${p.isPlaying} buffering=${p.isBuffering} t=${"%.1f".format(p.currentTime)}" +
                " d=${"%.1f".format(p.duration)} queue=${p.queue.size} error=${p.error?.message}" +
                " processing=${p.audioProcessingStatus.outcome} boost=${p.isBoostAvailable}",
        )
        val d = c.denoise.state.value
        Log.i(TAG, "denoise enabled=${d.isEnabled} mode=${d.mode.rawValue} status=${d.status.outcome} label=\"${d.status.label}\" model=${d.deepFilterStatus.label}" +
            " boost=${d.isBoostAvailable} inStep=${d.status == p.audioProcessingStatus}")
        Log.i(TAG, "sleep ${c.sleepTimer.state.value}")
        Log.i(TAG, "downloads states=${c.downloads.states.value} downloaded=${c.downloads.downloadedIDs.value} network=${c.downloads.network.value}")
        id?.let { Log.i(TAG, "progress $it position=${c.playbackState.getPosition(it)} duration=${c.playbackState.getDuration(it)}") }
    }

    /** The iOS reference-screenshot state: saved positions, recents, a week of stats and settings. */
    private suspend fun seedParityState(c: AppContainer) {
        val now = System.currentTimeMillis()
        // Undo what earlier runs changed: finished talks, later positions and extra recents.
        listOf(BIRD_1, BIRD_2, MRITYU_1).forEach {
            c.playbackState.unmarkCompleted(it)
            c.playbackState.dismissListenedComplete(it)
            c.playbackState.clearPosition(it)
        }
        c.playbackState.savePosition(BIRD_1, 1520.0, 5901.9, savedAt = now - 3_600_000)
        c.playbackState.savePosition(MRITYU_1, 610.0, 4400.9, savedAt = now - 86_400_000)
        // recordPlay moves to the front, so the older talk goes first.
        c.playbackState.recordPlay(MRITYU_1)
        c.playbackState.recordPlay(BIRD_1)
        val today = LocalDate.now()
        val minutesByDaysAgo = mapOf(0L to 34, 1L to 52, 3L to 41, 4L to 18, 6L to 27)
        // Merging takes the larger value per day, so this tops up but never lowers today's total.
        c.listeningStats.mergeSyncedStats(minutesByDaysAgo.entries.associate { (ago, min) -> today.minusDays(ago).toString() to min * 60.0 })
        c.settings.setSmartDownload(false)
        c.settings.setSmartDelete(false)
        c.settings.setDefaultPlaybackRate(1.0)
    }

    /** Exactly the two bookmarks the iOS player run adds on Bird #1. */
    private suspend fun seedParityBookmarks(c: AppContainer) {
        c.bookmarks.bookmarks.value.forEach { c.bookmarks.remove(it.id) }
        val title = "A Bird on the Wing - #1"
        c.bookmarks.add(BIRD_1, "A Bird on the Wing", title, 3354.0, "The bird on the wing — no clinging", BookmarkCategory.PROFOUND)
        c.bookmarks.add(BIRD_1, "A Bird on the Wing", title, 3968.0, "", BookmarkCategory.MEDITATION)
    }

    private companion object {
        const val TAG = "DebugCmd"
        const val BIRD_1 = "english-A_Bird_on_the_Wing__-1"
        const val BIRD_2 = "english-A_Bird_on_the_Wing__-2"
        const val MRITYU_1 = "hindi-Main_Mrityu_Sikhata_Hun-1"
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    }
}
