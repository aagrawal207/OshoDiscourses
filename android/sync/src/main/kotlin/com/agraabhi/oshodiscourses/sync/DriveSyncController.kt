package com.agraabhi.oshodiscourses.sync

import com.agraabhi.oshodiscourses.core.domain.sync.SyncController
import com.agraabhi.oshodiscourses.core.domain.sync.SyncStatus
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean

/**
 * [SyncController] over one snapshot file in Google Drive's hidden app-data folder (iOS
 * `CloudSyncService`). Opt-in: nothing touches the network until [requestAuthorization] succeeds.
 */
class DriveSyncController internal constructor(
    store: SnapshotStore,
    api: DriveApi,
    private val authorizer: DriveAuthorizer,
    private val preferences: SyncPreferences,
    private val scheduler: SyncScheduler,
    private val scope: CoroutineScope,
    private val localChanges: Flow<Unit>,
    private val appVisibility: Flow<Boolean>,
    private val clock: () -> Long,
    private val timing: SyncTiming = SyncTiming(),
    codec: SnapshotCodec = SnapshotJson,
) : SyncController {
    private val engine = DriveSyncEngine(api, store, codec = codec)
    private val mutableStatus = MutableStateFlow<SyncStatus>(SyncStatus.Idle)
    override val status: StateFlow<SyncStatus> = mutableStatus.asStateFlow()

    /** Serialises rounds, so the engine's cache and the Drive file see one writer per device. */
    private val mutex = Mutex()
    private val observing = AtomicBoolean(false)

    /** Local data may differ from Drive. Restored when a round fails, so the change is not lost. */
    private val pendingPush = AtomicBoolean(false)
    private val pushSignals = Channel<Unit>(Channel.CONFLATED)

    @Volatile private var lastRoundAt: Long? = null

    @Volatile private var lastToken: String? = null

    internal enum class RoundResult { DONE, RETRY }

    init {
        active = this
    }

    override suspend fun start() {
        observe()
        if (!preferences.enabled) {
            mutableStatus.value = SyncStatus.SignInNeeded
            return
        }
        scheduler.schedulePeriodic()
        round(fromWorker = false)
    }

    override suspend fun syncNow() {
        round(fromWorker = false)
    }

    override suspend fun requestAuthorization() {
        observe()
        when (val outcome = authorizer.authorize(interactive = true)) {
            is AuthOutcome.Granted -> {
                remember(outcome)
                preferences.enabled = true
                scheduler.schedulePeriodic()
                round(fromWorker = false)
            }
            AuthOutcome.NeedsConsent -> mutableStatus.value = SyncStatus.SignInNeeded
            is AuthOutcome.Failed -> mutableStatus.value = SyncStatus.Failed(outcome.message)
        }
    }

    override suspend fun signOut() {
        mutex.withLock {
            preferences.enabled = false
            scheduler.cancelAll()
            lastToken?.let { authorizer.clearToken(it) }
            lastToken = null
            engine.reset()
            mutableStatus.value = SyncStatus.SignInNeeded
        }
    }

    /**
     * Signs out and withdraws the app's Drive grant from the Google account. The snapshot file
     * stays in Drive. False if Google could not be reached; the device is signed out regardless.
     */
    override suspend fun disconnect(): Boolean {
        val account = preferences.accountName
        signOut()
        preferences.accountName = null
        return authorizer.revoke(account)
    }

    /** Marks local data as changed; [localChanges] calls this for every emission. */
    fun notifyLocalChange() {
        pendingPush.set(true)
        pushSignals.trySend(Unit)
    }

    internal suspend fun runFromWorker(): RoundResult = round(fromWorker = true)

    private fun observe() {
        if (!observing.compareAndSet(false, true)) return
        scope.launch { localChanges.collect { notifyLocalChange() } }
        scope.launch {
            while (true) {
                pushSignals.receive()
                pushWhenDue()
            }
        }
        scope.launch {
            appVisibility.collect { visible -> if (visible) onForeground() else onBackground() }
        }
    }

    /**
     * Gathers a burst of changes, then pushes at most once per [SyncTiming.minPushIntervalMillis].
     * Not a pure debounce: playback saves every 10 s and stats tick faster, so a quiet gap never comes.
     */
    private suspend fun pushWhenDue() {
        delay(timing.pushDelayMillis)
        lastRoundAt?.let { last ->
            val wait = last + timing.minPushIntervalMillis - clock()
            if (wait > 0) delay(wait)
        }
        // Changes that arrived while waiting are in this round's export.
        pushSignals.tryReceive()
        if (pendingPush.get() && preferences.enabled) round(fromWorker = false)
    }

    private suspend fun onForeground() {
        if (!preferences.enabled) return
        val last = lastRoundAt
        if (last == null || clock() - last >= timing.foregroundMinGapMillis) round(fromWorker = false)
    }

    /** The process may die in the background, so WorkManager owns pushing what is still unsent. */
    private fun onBackground() {
        if (preferences.enabled && pendingPush.get()) scheduler.scheduleRetry()
    }

    private suspend fun round(fromWorker: Boolean): RoundResult = mutex.withLock {
        if (!preferences.enabled) {
            mutableStatus.value = SyncStatus.SignInNeeded
            return@withLock RoundResult.DONE
        }
        lastRoundAt = clock()
        val hadPending = pendingPush.getAndSet(false)
        mutableStatus.value = SyncStatus.Syncing
        try {
            withToken { engine.sync(it) }
            mutableStatus.value = SyncStatus.UpToDate(clock())
            RoundResult.DONE
        } catch (e: CancellationException) {
            if (hadPending) pendingPush.set(true)
            throw e
        } catch (e: Exception) {
            if (hadPending) pendingPush.set(true)
            val failure = describe(e)
            mutableStatus.value = failure.status
            if (failure.transient && !fromWorker) scheduler.scheduleRetry()
            if (failure.transient) RoundResult.RETRY else RoundResult.DONE
        }
    }

    /** One silent re-authorization on 401, since access tokens expire after about an hour. */
    private suspend fun <T> withToken(block: suspend (String) -> T): T {
        val token = token()
        return try {
            block(token)
        } catch (_: DriveException.Unauthorized) {
            authorizer.clearToken(token)
            val fresh = token()
            try {
                block(fresh)
            } catch (_: DriveException.Unauthorized) {
                authorizer.clearToken(fresh)
                throw AuthNeededException()
            }
        }
    }

    private suspend fun token(): String = when (val outcome = authorizer.authorize(interactive = false)) {
        is AuthOutcome.Granted -> {
            remember(outcome)
            outcome.accessToken
        }
        AuthOutcome.NeedsConsent -> throw AuthNeededException()
        is AuthOutcome.Failed -> throw AuthFailedException(outcome)
    }

    private fun remember(granted: AuthOutcome.Granted) {
        lastToken = granted.accessToken
        val name = granted.accountName
        if (name != null && name != preferences.accountName) preferences.accountName = name
    }

    private data class Failure(val status: SyncStatus, val transient: Boolean)

    private fun describe(e: Exception): Failure = when (e) {
        is AuthNeededException -> Failure(SyncStatus.SignInNeeded, transient = false)
        is AuthFailedException -> Failure(SyncStatus.Failed(e.outcome.message), transient = e.outcome.offline)
        is IOException -> Failure(SyncStatus.Failed(SyncMessages.OFFLINE), transient = true)
        is DriveException.Forbidden -> Failure(SyncStatus.Failed(SyncMessages.CANNOT_CONNECT), transient = false)
        is DriveException -> Failure(SyncStatus.Failed(SyncMessages.DRIVE_UNAVAILABLE), transient = e.transient)
        else -> Failure(SyncStatus.Failed(SyncMessages.DRIVE_UNAVAILABLE), transient = true)
    }

    private class AuthNeededException : Exception()

    private class AuthFailedException(val outcome: AuthOutcome.Failed) : Exception(outcome.message)

    internal companion object {
        /** The process's controller, for [DriveSyncWorker]. `:app` creates it in `Application.onCreate`. */
        @Volatile
        var active: DriveSyncController? = null
    }
}

/** Times in milliseconds. */
internal data class SyncTiming(
    /** Gathers a burst of edits (bookmark plus note, several stats ticks) into one push. */
    val pushDelayMillis: Long = 5_000,
    /** Caps pushes while playing; each round is two to four Drive requests. */
    val minPushIntervalMillis: Long = 30_000,
    /** Skips a foreground pull right after launch or a quick app switch. */
    val foregroundMinGapMillis: Long = 30_000,
)
