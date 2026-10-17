# Integration notes (A14 wiring checklist)

Collected from worker handoffs. Tick when wired in `:app` and verified on the emulator.

## A2 Catalog
- [ ] `AppContainer.catalog = BundledCatalogRepository()`; call `catalog.warmUp()` once at launch on `Dispatchers.IO`.
- [ ] Measure catalog warm-up on the emulator (JVM: 91 ms cold).
- [ ] Downloads build the oshoworld URL with `URLEncoding.requestURL(discourse.audioURL)`; the archive URL comes from `catalog.archiveAudioURL(discourse)`, already encoded.

## A7 Transcript data
- [ ] `AppContainer.transcripts = Transcripts.create(context, sharedOkHttpClient)`.
- [ ] Downloads call `prefetch(id, allowsCellular)` after each committed download and `remove(id)` when audio is deleted.
- [ ] Launch `backfill(downloadedIDs, allowsCellular)` once after startup.
- [ ] Pass `state.copy(alignment = null)` to `timing()` when the speech-sync setting is off.
- [ ] The reader uses `transcripts.timing()` and shows the sentence highlight only when `source != ESTIMATE`; reconcile with A10's own sync model port.
- [ ] Consider moving `TranscriptCatalog` into `:core:model` so the 568 KB JSON is parsed once (A2 also reads its keys).

## A13 Drive sync
- [ ] `sync = DriveSync.create(context, store = <SnapshotStore adapter over A3 CloudSnapshotCoordinator>, localChanges = DriveSync.localChanges(playbackState, bookmarks, listeningStats, transcriptState, downloads), activityProvider = { resumed ComponentActivity })` in `Application.onCreate`; `sync.start()` once on an app scope.
- [ ] Settings Sync row calls `requestAuthorization()`; decide whether `disconnect()` joins the `SyncController` contract.
- [ ] Add catalog alias `androidx-activity` and replace the string coordinate in `sync/build.gradle.kts`.
- [ ] R8 keep rules for kotlinx serialization (`CloudSnapshot`) and Play services in release.
- [ ] `PRIVACY.md`: add an Android paragraph on Drive app-data sync.
- [ ] Human: Google Cloud project, Drive API, consent screen, three Android OAuth clients (`android/docs/google-drive-sync.md`).

## A3 Persistence
- [ ] `DataRepositories(context, appScope)` once in `OshoApplication.onCreate` (`SupervisorJob() + Dispatchers.Default`); a second instance breaks DataStore.
- [ ] Point `settings`, `playbackState`, `bookmarks`, `listeningStats`, `transcriptState` at `data.*`; pass `data.cloudSnapshotCoordinator(downloads)` to sync.
- [ ] Sync adapter should use `CloudSnapshotCodec`/`exportBytes`/`mergeBytes` so the Drive file keeps the iOS shape (A13 serialises the domain type itself today).
- [ ] `data.playbackState.onRemotePositionAdvanced`: seek a paused player on that discourse (hop to main).
- [ ] Foreground: `settings.refreshShuffledTheme()`, `listeningStats.refresh()`. `ON_STOP`: `transcriptState.flush()`.
- [ ] Accent picker also calls `setDailyAccentShuffle(false)`.
- [ ] Sync `localChanges` must include `DownloadManager.downloadHistory`.
- [ ] Player tick calls `listeningStats.recordListeningTime` then `save()` (A4).
- [ ] Keep `filesDir` JSON + DataStore in Auto Backup; exclude downloads and transcript cache.

## A12 Billing
- [ ] `PlaySupportStore(context, activityTracker::current, appScope, licenseKey = BuildConfig.PLAY_LICENSE_KEY)`; `LocalEngagementService(context)`; `PlayReviewPrompter(context, activityTracker::current, appScope, engagement, listeningStats, sleepTimer, isPlaying = { player.state.value.isPlaying })`.
- [ ] `support.recoverPurchases()` on process `ON_START`.
- [ ] Player calls `reviewPrompter.discourseDidFinish(...)` and `listenerDidPause()`.
- [ ] License key from a Gradle property; release must set it.
- [ ] Add `clearDeclinedRequest()` to `SupportStore` (+ fake) so Settings can reach `PlaySupportStore.clearDeclinedAnnualRequest()`.
- [ ] Human: create Play products per `android/docs/play-products.md`.
- [ ] Activity tracker in `:app` (shared by billing, review, Drive auth; must return a `ComponentActivity`).

## A5 Downloads
- [ ] `downloads = Downloads.createEngine(context, catalog, settings, transcripts, scope, okHttpClient)`; `OshoApplication` implements `DownloadEngineOwner` and creates the engine in `onCreate`.
- [ ] `MainActivity.onStart`: `resumePendingTransfers()`.
- [ ] Debug: `applyDebugNetworkArgument(intent.getStringExtra("debugDownloadNetwork"))`.
- [ ] Manifest: `fullBackupContent`/`dataExtractionRules` from downloads, merged with the transcript cache (A7 uses `noBackupFilesDir`, already excluded).
- [ ] Request `POST_NOTIFICATIONS` (Android 13+) at the first download.
- [ ] Sync push on `downloadHistory` changes; `transcripts.backfill(...)` 5 s after launch.
- [ ] Smart Download/Delete owned by A4 or app wiring; confirm.
- [ ] Emulator: job service, worker, notification, process-death recovery.
- [ ] Play Console: `FOREGROUND_SERVICE_DATA_SYNC` declaration.

## A10 Transcript reader
- [ ] Deduplicate `TranscriptSyncModel` (`:transcript` and `:feature:transcript`): one pure copy in `:core:domain` or `:core:model`.
- [ ] Add `CatalogRepository.transcriptPageURL(discourseID)` and pass `pageURL` (Open on oshoworld.com).
- [ ] Add `TranscriptTiming.matchedParagraphs` so the Timing note shows "<m> of <n> paragraphs".
- [ ] Select Text hint: drop "or drag them into another app" (no drag-out on Android).
- [ ] Promote `ReplayFifteenIcon` and glass toolbar buttons to `:core:ui` (also needed by the player).
- [ ] Emulator: keep-screen-on, share chooser, clipboard.

## A4 Playback
- [ ] Main thread: `sleepTimer = SleepTimerService(mainScope)`; `player = PlaybackEngine.create(context, catalog, downloads, bookmarks, settings, playbackState, listeningStats, sleepTimer, denoisePipeline, reviewPrompter)`; `sleepTimer.onExpire = { player.setPlaying(false) }`.
- [ ] `OshoApplication` implements `PlaybackEngineProvider`.
- [ ] `player.restoreLastSession()` after progress and downloads load.
- [ ] Smart Download lead is 20 s, as the iOS code (CLAUDE.md's "10 min" is stale).
- [ ] A6 pipeline applies boost gain from `settings.volumeBoost`.
- [ ] Add `onPlaybackResumption` + media button receiver (Bluetooth play after process death).
- [ ] Custom notification small icon; check Previous/Next visibility in system media controls.
- [ ] Emulator: `:playback:connectedDebugAndroidTest`.

## A6 DeNoise
- [ ] `denoise = DenoiseEngine.create(context, settings, appScope)`; expose as `AppServices.denoise` and pass to playback as the pipeline.
- [ ] `player.state.collect { denoise.onPlaybackChanged(it.hasTrack, it.isPlaying && !it.isBuffering, it.error != null) }`.
- [ ] Move NDK version into the version catalog.
- [ ] Emulator: `:denoise:connectedDebugAndroidTest` + `DenoiseBenchmark` real-time factor.
- [ ] Release: App Bundle with ABI splits (debug APK is 75 MB). ABIs are arm64-v8a + x86_64 only.

## A8 Home, Library, Series
- [ ] `SeriesScreen(onBack = navigator::pop, onOpenTranscript = navigator::showTranscript, onAddBookmark = …)`; `HomeScreen(onOpenSupport = tip-jar sheet, isPlayerPresented = navigator.isPlayerPresented)`.
- [ ] Rows start playback and show the mini-player only (iOS); the full player no longer opens on a row tap.
- [ ] Fix `AppShellTest` (duplicate series names on Home, row label "Discourse 1", player not auto-opened) and re-record `app_shell_*.png`.
- [ ] Promote shared chrome to `:core:ui`: `LargeTitlePage` (duplicated in home + library), `CappedFontScale`, `GlassIconButton`, `InlineTopBar`, `OshoMenu`, `ActionSheet`, `DownloadRing`.
- [ ] Emulator: thumbnail and menu shadows, support-card exposure timing.

## A11 Downloads, Bookmarks, Stats, Settings, Support
- [ ] `BookmarksScreen(onBack)`, `ListeningStatsScreen(onBack, onOpenHistory = push ListeningHistoryRoute)`, `entry<ListeningHistoryRoute>`, `DownloadsScreen(onAddBookmark)`, `SettingsScreen(versionName = BuildConfig.VERSION_NAME)`; Home support card opens `SupportDevelopmentSheet`.
- [ ] Pass `onClearDeclinedRequest` once `SupportStore.clearDeclinedRequest()` exists.
- [ ] Add `SupportProduct.priceMicros` for true price ordering.
- [ ] Feature modules need `activity-compose` on the compile classpath for `BackHandler` (feature convention plugin).
- [ ] Promote grouped list, card rows, action sheet, menu, segmented control and switch from `:feature:downloads/settings` `ui/` into `:core:ui`; remove the copies.
- [ ] Emulator: `ModalBottomSheet` status-bar inset on the tip jar, blur, haptics.
