# Integration notes (A14 wiring checklist)

Collected from worker handoffs. Tick when wired in `:app` and verified on the emulator.

Emulator checks use the debug-only `DebugCommandReceiver`, for example
`adb shell am broadcast -a com.agraabhi.oshodiscourses.DEBUG -p com.agraabhi.oshodiscourses --es cmd state`
(commands: `state`, `play`, `pause`, `resume`, `download`, `delete`, `sleep`, `sleep_end`,
`sleep_cancel`, `denoise`, `cellular`; output in logcat tag `DebugCmd`). A local R8 build:
`./gradlew :app:assembleRelease -Posho.debugSignRelease=true`.

## A2 Catalog
- [x] `AppContainer.catalog = BundledCatalogRepository()`; call `catalog.warmUp()` once at launch on `Dispatchers.IO`.
- [x] Measure catalog warm-up on the emulator (JVM: 91 ms cold). — Emulator (Pixel 9, Android 16): debug 430–610 ms, release (R8) 28–46 ms.
- [x] Downloads build the oshoworld URL with `URLEncoding.requestURL(discourse.audioURL)`; the archive URL comes from `catalog.archiveAudioURL(discourse)`, already encoded. — `DownloadEngine.sources` now encodes through `URLEncoding.requestURL`.

## A7 Transcript data
- [x] `AppContainer.transcripts = Transcripts.create(context, sharedOkHttpClient)`. — also passes the catalog repository's `TranscriptCatalog`.
- [x] Downloads call `prefetch(id, allowsCellular)` after each committed download and `remove(id)` when audio is deleted. — prefetch now passes the cellular setting.
- [x] Launch `backfill(downloadedIDs, allowsCellular)` once after startup. — 5 s after launch.
- [x] Pass `state.copy(alignment = null)` to `timing()` when the speech-sync setting is off. — done in `TranscriptViewModel.rebuildModel`.
- [x] The reader uses `transcripts.timing()` and shows the sentence highlight only when `source != ESTIMATE`; reconcile with A10's own sync model port. — one `TranscriptSyncModel` in `:core:domain`.
- [x] Consider moving `TranscriptCatalog` into `:core:model` so the 568 KB JSON is parsed once (A2 also reads its keys). — parsed once by `BundledCatalogRepository.transcriptCatalog`.

## A13 Drive sync
- [x] `sync = DriveSync.create(context, store = <SnapshotStore adapter over A3 CloudSnapshotCoordinator>, localChanges = DriveSync.localChanges(playbackState, bookmarks, listeningStats, transcriptState, downloads), activityProvider = { resumed ComponentActivity })` in `Application.onCreate`; `sync.start()` once on an app scope. — store is `CoordinatorSnapshotStore`; local changes are the coordinator's plus download history.
- [x] Settings Sync row calls `requestAuthorization()`; decide whether `disconnect()` joins the `SyncController` contract. — `disconnect()` joined the contract (default signs out); Settings calls `requestAuthorization()` to sign in and `disconnect()` for Stop Syncing.
- [x] Add catalog alias `androidx-activity` and replace the string coordinate in `sync/build.gradle.kts`.
- [x] R8 keep rules for kotlinx serialization (`CloudSnapshot`) and Play services in release. — libraries ship consumer rules; only a `-dontwarn` for review-ktx was needed. Release ran on the emulator; Drive itself is untested (no OAuth client).
- [x] `PRIVACY.md`: add an Android paragraph on Drive app-data sync.
- [ ] Human: Google Cloud project, Drive API, consent screen, three Android OAuth clients (`android/docs/google-drive-sync.md`).

## A3 Persistence
- [x] `DataRepositories(context, appScope)` once in `OshoApplication.onCreate` (`SupervisorJob() + Dispatchers.Default`); a second instance breaks DataStore.
- [x] Point `settings`, `playbackState`, `bookmarks`, `listeningStats`, `transcriptState` at `data.*`; pass `data.cloudSnapshotCoordinator(downloads)` to sync.
- [x] Sync adapter should use `CloudSnapshotCodec`/`exportBytes`/`mergeBytes` so the Drive file keeps the iOS shape (A13 serialises the domain type itself today). — `:sync` takes a `SnapshotCodec`; `:app` passes `IosSnapshotCodec`.
- [x] `data.playbackState.onRemotePositionAdvanced`: seek a paused player on that discourse (hop to main). — not wired: `PlaybackEngine.onProgressChanged` already seeks a paused player when the stored position moves ahead.
- [x] Foreground: `settings.refreshShuffledTheme()`, `listeningStats.refresh()`. `ON_STOP`: `transcriptState.flush()`. — `ProcessLifecycleOwner` observer in `AppContainer.start`.
- [x] Accent picker also calls `setDailyAccentShuffle(false)`. — A11 `SettingsViewModel`.
- [x] Sync `localChanges` must include `DownloadManager.downloadHistory`.
- [x] Player tick calls `listeningStats.recordListeningTime` then `save()` (A4). — `PlaybackEngine.autoSaveTick`.
- [x] Keep `filesDir` JSON + DataStore in Auto Backup; exclude downloads and transcript cache. — `app/src/main/res/xml/backup_rules.xml` and `data_extraction_rules.xml`.

## A12 Billing
- [x] `PlaySupportStore(context, activityTracker::current, appScope, licenseKey = BuildConfig.PLAY_LICENSE_KEY)`; `LocalEngagementService(context)`; `PlayReviewPrompter(context, activityTracker::current, appScope, engagement, listeningStats, sleepTimer, isPlaying = { player.state.value.isPlaying })`.
- [x] `support.recoverPurchases()` on process `ON_START`.
- [x] Player calls `reviewPrompter.discourseDidFinish(...)` and `listenerDidPause()`. — the engine calls `discourseDidFinish`; A9's `PlayerViewModel` calls `listenerDidPause`.
- [x] License key from a Gradle property; release must set it. — `-Posho.playLicenseKey=...` becomes `BuildConfig.PLAY_LICENSE_KEY`.
- [x] Add `clearDeclinedRequest()` to `SupportStore` (+ fake) so Settings can reach `PlaySupportStore.clearDeclinedAnnualRequest()`.
- [ ] Human: create Play products per `android/docs/play-products.md`.
- [x] Activity tracker in `:app` (shared by billing, review, Drive auth; must return a `ComponentActivity`). — `ForegroundActivityTracker` (resumed, else started).

## A5 Downloads
- [x] `downloads = Downloads.createEngine(context, catalog, settings, transcripts, scope, okHttpClient)`; `OshoApplication` implements `DownloadEngineOwner` and creates the engine in `onCreate`. — screens get `PromptingDownloadManager` over the engine; playback uses the engine directly.
- [x] `MainActivity.onStart`: `resumePendingTransfers()`.
- [x] Debug: `applyDebugNetworkArgument(intent.getStringExtra("debugDownloadNetwork"))`. — `onCreate` and `onNewIntent`.
- [x] Manifest: `fullBackupContent`/`dataExtractionRules` from downloads, merged with the transcript cache (A7 uses `noBackupFilesDir`, already excluded).
- [x] Request `POST_NOTIFICATIONS` (Android 13+) at the first download. — once, on the first listener-started download (`NotificationPermissionPrompt`).
- [x] Sync push on `downloadHistory` changes; `transcripts.backfill(...)` 5 s after launch.
- [x] Smart Download/Delete owned by A4 or app wiring; confirm. — owned by `PlaybackEngine`.
- [x] Emulator: job service, worker, notification, process-death recovery. — user-initiated job ran with the screen off and app in background; after `kill -9` the system restarted the job and the engine recovered the queue and finished.
- [ ] Play Console: `FOREGROUND_SERVICE_DATA_SYNC` declaration.

## A10 Transcript reader
- [x] Deduplicate `TranscriptSyncModel` (`:transcript` and `:feature:transcript`): one pure copy in `:core:domain` or `:core:model`.
- [x] Add `CatalogRepository.transcriptPageURL(discourseID)` and pass `pageURL` (Open on oshoworld.com).
- [x] Add `TranscriptTiming.matchedParagraphs` so the Timing note shows "<m> of <n> paragraphs". — emulator shows "Synced from speech: 89 of 93 paragraphs".
- [x] Select Text hint: drop "or drag them into another app" (no drag-out on Android).
- [x] Promote `ReplayFifteenIcon` and glass toolbar buttons to `:core:ui` (also needed by the player). — one `SkipIntervalIcon`/`ReplayFifteenIcon` in `TransportIcons.kt`; the player copy is gone.
- [x] Emulator: keep-screen-on, share chooser, clipboard (A17a).

## A4 Playback
- [x] Main thread: `sleepTimer = SleepTimerService(mainScope)`; `player = PlaybackEngine.create(context, catalog, downloads, bookmarks, settings, playbackState, listeningStats, sleepTimer, denoisePipeline, reviewPrompter)`; `sleepTimer.onExpire = { player.setPlaying(false) }`.
- [x] `OshoApplication` implements `PlaybackEngineProvider`.
- [x] `player.restoreLastSession()` at launch, after `catalog.warmUp()` and `downloadEngine.awaitReady()` (#41). It loads the first talk of Home's Continue Listening (`ContinueListening.discourseIDs`, shared with `HomeContent`), paused at its saved position. The file checks run on `Dispatchers.IO`. ExoPlayer gets the queue only on the first play, so a restore takes no audio focus, binds no service and posts no notification. A headset play key still goes through `onPlaybackResumption` → `resumptionItems()`. DeNoise sees `hasTrack && isAudioOpen`, so a restored talk reads "Ready for playback" like a paused one. Process `ON_STOP` and `PlaybackService.onTaskRemoved` call `saveProgressNow()`, which skips the write when the position has not moved.
- [x] Smart Download lead is 20 s, as the iOS code (CLAUDE.md's "10 min" is stale). — `PlaybackRules.SMART_DOWNLOAD_LEAD_SECONDS`; root CLAUDE.md still says 10 min.
- [x] A6 pipeline applies boost gain from `settings.volumeBoost`. — `DenoiseEngine.Choices`.
- [x] Add `onPlaybackResumption` + media button receiver (Bluetooth play after process death). — verified: after `kill -9`, a media play key started the service, restored the last talk and played from its saved position.
- [x] Custom notification small icon; check Previous/Next visibility in system media controls. — `ic_stat_lotus`; Previous and Next stay visible (Media3 always offers restart).
- [x] Emulator: `:playback:connectedDebugAndroidTest`. — 1/1 pass.

## A6 DeNoise
- [x] `denoise = DenoiseEngine.create(context, settings, appScope)`; expose as `AppServices.denoise` and pass to playback as the pipeline.
- [x] `player.state.collect { denoise.onPlaybackChanged(it.hasTrack, it.isPlaying && !it.isBuffering, it.error != null) }`.
- [x] Move NDK version into the version catalog.
- [x] Emulator: `:denoise:connectedDebugAndroidTest` + `DenoiseBenchmark` real-time factor. — 40/40 pass; Best Quality 44.1 kHz stereo RTF 0.047.
- [x] Release: App Bundle with ABI splits (debug APK is 75 MB). ABIs are arm64-v8a + x86_64 only. — `bundleRelease` builds a 39 MB AAB that Play splits per ABI; the R8 universal APK is 52 MB.

## A8 Home, Library, Series
- [x] `SeriesScreen(onBack = navigator::pop, onOpenTranscript = navigator::showTranscript, onAddBookmark = …)`; `HomeScreen(onOpenSupport = tip-jar sheet, isPlayerPresented = navigator.isPlayerPresented)`. — Add Bookmark opens `:feature:player`'s public `AddBookmarkSheet` over the window (iOS `windowBookmarkBinding`); the Home card and Settings open one shell-level `SupportDevelopmentSheet` through `AppNavigator.showSupport`. Emulator: series menu → Add Bookmark saved and listed in Bookmarks.
- [x] Rows start playback and show the mini-player only (iOS); the full player no longer opens on a row tap. — `AppShellTest` checks it.
- [x] Fix `AppShellTest` (duplicate series names on Home, row label "Discourse 1", player not auto-opened) and re-record `app_shell_*.png`.
- [x] Promote shared chrome to `:core:ui`: `LargeTitlePage` (duplicated in home + library), `CappedFontScale`, `GlassIconButton`, `InlineTopBar`, `OshoMenu`, `ActionSheet`, `DownloadRing`. — home, library, series and transcript use the `:core:ui` copies.
- [ ] Emulator: thumbnail and menu shadows, support-card exposure timing.

## A11 Downloads, Bookmarks, Stats, Settings, Support
- [x] `BookmarksScreen(onBack)`, `ListeningStatsScreen(onBack, onOpenHistory = push ListeningHistoryRoute)`, `entry<ListeningHistoryRoute>`, `DownloadsScreen(onAddBookmark)`, `SettingsScreen(versionName = BuildConfig.VERSION_NAME)`; Home support card opens `SupportDevelopmentSheet`. — `AppShellTest` covers the series bookmark, Stats → History → back, and Settings → Support. Settings "Stop Syncing" calls `sync.disconnect()`.
- [x] Pass `onClearDeclinedRequest` once `SupportStore.clearDeclinedRequest()` exists.
- [x] Add `SupportProduct.priceMicros` for true price ordering. — nullable, default null; billing passes Play's micros. Rows sort by it when every product has one, else by the US ladder.
- [x] Feature modules need `activity-compose` on the compile classpath for `BackHandler` (feature convention plugin). — also on `:core:ui` for the shared sheets; in-place History in Stats handles system back.
- [x] Promote grouped list, card rows, action sheet, menu, segmented control and switch from `:feature:downloads/settings` `ui/` into `:core:ui`; remove the copies. — `GroupedList.kt`, `ListControls.kt`, `ActionSheet.kt`, `OshoMenu`, `IosControls.kt`; only Settings' `ToggleRow`, `AccentSwatch` and `IosAlert` stay local.
- [ ] Emulator: `ModalBottomSheet` status-bar inset on the tip jar, blur, haptics. — inset checked: the sheet stops 10 dp below the status bar like the in-window sheets. Blur and haptics not checked.

## A9 Player, mini-player, DeNoise
- [x] `PlayerScreen(onDismiss, onOpenTranscript, onOpenSeries)`, `MiniPlayer(onOpenPlayer, onHeightChanged)`, `DenoiseScreen(onBack = navigator::pop)` from Settings. — emulator: mini-player opens the player, a drag past a quarter dismisses it; speed, sleep, queue, Add Bookmark and DeNoise from the player and from Settings.
- [x] `AppShell.ModalLayer`: drop the full-screen background behind the player (it draws its own and follows the finger). — a black @ 40 % scrim fades in behind it instead.
- [x] Keep `DenoiseState` and `PlayerState.audioProcessingStatus` in step (UI reads `DenoiseState`); boost via `DenoiseController.setBoost`. — both come from `DenoiseEngine.status`; the debug `state` command prints `inStep`, true while playing, paused, off and re-enabled.
- [x] Check the playback error line wording (`PlayerState.error`). — the engine uses the iOS `setupFailed(.playback)` detail verbatim.
- [x] Promote `IosSlider`, `IosSwitch`, `SegmentedControl`, `SheetHost`, `AnchoredPopover`, glass buttons, grouped sections, `SkipIntervalIcon`/`ReplayFifteenIcon` into `:core:ui` and remove module copies (with A11's and A8's). — the player's `InlineTopBar` is `SheetToolbar`; `PortraitArtwork`, `PlayingBars` and `ShrinkToFitText` stay in the player.

## Testing
- Test layers, commands, Maestro flows and real-phone-only checks: `android/docs/testing.md`.
- Debug seeding for parity runs (`seed`, `seed_bookmarks`, `appearance`): see `android/docs/parity.md`.
