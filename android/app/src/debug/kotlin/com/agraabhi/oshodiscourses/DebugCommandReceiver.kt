package com.agraabhi.oshodiscourses

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.agraabhi.oshodiscourses.core.model.NoiseReductionMode
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Emulator checks without the UI, e.g.
 * `adb shell am broadcast -a com.agraabhi.oshodiscourses.DEBUG -p com.agraabhi.oshodiscourses --es cmd state`.
 * Commands: state, play (id, from), pause, resume, download (id), delete (id), sleep (minutes),
 * sleep_end, sleep_cancel, denoise (on, mode), cellular (on). Results go to logcat tag `DebugCmd`.
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
            "state", null -> Unit
            else -> Log.w(TAG, "unknown cmd=$cmd")
        }
        val p = c.player.state.value
        Log.i(
            TAG,
            "player track=${p.currentTrackId} playing=${p.isPlaying} buffering=${p.isBuffering} t=${"%.1f".format(p.currentTime)}" +
                " d=${"%.1f".format(p.duration)} queue=${p.queue.size} error=${p.error?.message}",
        )
        val d = c.denoise.state.value
        Log.i(TAG, "denoise enabled=${d.isEnabled} mode=${d.mode.rawValue} status=${d.status.outcome} label=\"${d.status.label}\" model=${d.deepFilterStatus.label}")
        Log.i(TAG, "sleep ${c.sleepTimer.state.value}")
        Log.i(TAG, "downloads states=${c.downloads.states.value} downloaded=${c.downloads.downloadedIDs.value} network=${c.downloads.network.value}")
        id?.let { Log.i(TAG, "progress $it position=${c.playbackState.getPosition(it)} duration=${c.playbackState.getDuration(it)}") }
    }

    private companion object {
        const val TAG = "DebugCmd"
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    }
}
