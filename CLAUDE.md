# OshoDiscourses — Native iOS App

App for browsing, downloading, and playing Osho audio discourses from oshoworld.com on iPhone, iPad, Mac (Catalyst), Apple Watch and CarPlay. Native Swift/SwiftUI with Apple frameworks and vendored RNNoise and DeepFilterNet; no app package-manager dependencies.

## Quick start

```bash
cd ~/projects/OshoDiscourses-Swift
xcodegen generate
xcodebuild -project OshoDiscourses.xcodeproj -scheme OshoDiscourses \
  -destination 'platform=iOS Simulator,name=Osho iPhone 17 Pro' build
```

Regenerate `.xcodeproj` after adding/removing files:
```bash
xcodegen generate
```

| Scheme | Builds / tests | Notes |
| --- | --- | --- |
| `OshoDiscourses` | App (iOS + Catalyst, embeds the Watch app) / `OshoDiscoursesTests` | Normal development and release; no CarPlay entitlement |
| `OshoDiscoursesUI` | `OshoDiscoursesUITests` | iPhone/iPad UI scenarios |
| `OshoDiscoursesCarPlay` | Same app with `Debug-CarPlay` / `Release-CarPlay` | Signs with `Signing/CarPlay.entitlements`; needs Apple's approval to sign for device |
| `OshoDiscoursesWatch` | `OshoDiscoursesWatch` + phone app / `OshoDiscoursesWatchTests` | watchOS 11+ |
| `OshoDiscoursesWatchUI` | `OshoDiscoursesWatchUITests` | Fixture UI tests; opt-in paired-simulator test |

Mac: `Tools/MacCatalyst/run-local.sh [build|test|launch]` (see Dev notes).

## Stack

- Swift 6.0, SwiftUI, iOS 18+, Mac Catalyst 18 (macOS 15+), watchOS 11+
- AVFoundation + MediaPlayer (audio playback + lock screen controls)
- CarPlay (list templates + shared Now Playing) and WatchConnectivity, both iOS-only
- StoreKit 2 (optional consumable tips)
- Vendored native dependencies: RNNoise C sources and DeepFilterNet 3
  (Rust/tract, built into `Vendor/DeepFilterBridge.xcframework`, with a bundled model)
- No SwiftData — catalog is static structs, settings use UserDefaults, downloads tracked by filesystem

## Architecture

```
OshoDiscourses/
├── App/OshoDiscoursesApp.swift         # @main entry, environment injection
├── App/AppRuntime.swift                # Process-owned services shared by windows, CarPlay and the Watch session
├── App/AppCommands.swift               # Mac menu bar / iPad keyboard menu: View and Playback commands
├── Companion/                          # CompanionLibrary (lists for CarPlay/Watch) + PlaybackLauncher (play by id)
├── Companion/Watch/                    # WCSession transport, request handler, snapshot publisher, file transfers, position merger
├── CarPlay/                            # Scene delegate, session controller, list templates, Now Playing buttons, navigator
├── Views/
│   ├── ContentView.swift               # Sidebar-adaptable TabView: Home, Library, Downloads, Settings (+ Bookmarks in regular width)
│   ├── AppNavigation.swift             # Per-window tab, player and series navigation state
│   ├── Watch/AppleWatchView.swift      # Settings screen: talks on the Watch, transfers, pairing guidance
│   ├── Home/HomeView.swift             # Home — Continue Listening (series name links to series), curated sections
│   ├── Library/LibraryView.swift       # Full series list with dynamic filter chips + sort
│   ├── Series/SeriesDetailView.swift   # Hero header, discourse list, download/play actions
│   ├── Player/PlayerView.swift         # Full player: artwork, transport, speed, sleep timer; side-by-side transcript in regular width
│   ├── Player/AudioEnhancementView.swift # Shared player/settings screen: recommended cleanup, noise amount, boost and quiet-speech options
│   ├── Player/TranscriptView.swift     # Lyrics-style transcript sheet or embedded pane — highlight, auto-follow, anchors, search, font size
│   ├── Player/MiniPlayerView.swift     # Floating mini-player bar, or tab-bar accessory in regular width (iOS 26.1+)
│   ├── Downloads/DownloadsView.swift   # Downloads, storage meter, stats and bookmarks
│   ├── BookmarksView.swift             # Bookmark list (built) — filter chips, swipe-delete, play/redownload
│   ├── Settings/SettingsView.swift     # Preferences: language, player/downloads, noise reduction, appearance, about
│   ├── Settings/TipJarView.swift       # Support Development sheet: consumable tips via StoreKit 2
│   └── Settings/ListeningStatsView.swift # Listening stats dashboard
├── Services/
│   ├── AudioPlayerService.swift        # AVPlayer + lock screen controls + audio-session interruption/route recovery
│   ├── DownloadService.swift           # Background URLSession downloads (survive app switch/lock/process death); excludes downloads from iCloud backup
│   ├── PlaybackStateService.swift      # Auto-saves position per discourse every 10s; owns cloud merge logic
│   ├── CloudSyncService.swift          # Silent NSUbiquitousKeyValueStore sync of progress + bookmarks + daily stats
│   ├── SleepTimerService.swift         # Countdown + end-of-discourse sleep modes
│   ├── BookmarkService.swift           # Bookmarks persisted to bookmarks.json; union-by-id cloud merge
│   ├── ListeningStatsService.swift     # Daily listening totals + streak (listening_stats.json); max-per-day cloud merge
│   ├── NoiseReductionProcessor.swift   # Control facade selecting the current tap generation
│   ├── NoiseReductionTapContext.swift  # Per-generation stream ownership and deferred format preparation
│   ├── SourceAudioTimeline.swift       # Asset-time continuity, including unflagged seeks and invalid timing
│   ├── NoiseReductionStream.swift      # RNNoise/Cadence/DeepFilter routing, buffer outcomes, deferred resets, boost
│   ├── RNNoiseProcessor.swift          # 48 kHz RNNoise with a two-hop aligned dry/wet mix
│   ├── DenoiserStream.swift            # Shared source/model rate conversion and fixed-hop buffering
│   ├── DeepFilterProcessor.swift       # Rust/tract model, async load, live attenuation, eight-hop reset flush
│   ├── PolyphaseResampler.swift        # Kaiser-filtered rate conversion with preallocated streaming buffers
│   ├── VoiceFocusChain.swift           # Voice-forward presets: SNR ducking + quiet-speech lift + emphasis
│   ├── PeakLimiter.swift               # Reconstruction headroom and filtered-output boost ceiling
│   ├── TranscriptService.swift         # Fetch + disk cache of transcripts; prefetch behind downloads, backfill, delete-with-audio
│   ├── TranscriptFetcher.swift         # oshoworld JSON API with __NEXT_DATA__ page-scrape fallback
│   ├── TranscriptParser.swift          # Transcript model + oshoworld HTML -> paragraphs (emphasis blocks = question/sutra)
│   ├── TranscriptSyncModel.swift       # Time <-> paragraph map: text-fraction estimate bent by anchors/aligned knots
│   ├── TranscriptStateService.swift    # Per-discourse anchors, read position, alignment; transcript_state.json; cloud merge
│   ├── SpeechAlignmentService.swift    # On-device fallback (iOS 26) for discourses AlignmentCatalog lacks -> paragraph timings
│   ├── SpeechWordRecognizer.swift      # SpeechAnalyzer wrapper: SpeechTranscriber (English) / DictationTranscriber (Hindi), words with time ranges
│   ├── TranscriptAligner.swift         # Unique-trigram landmarks + LIS chain -> paragraph start times (any script)
│   ├── MacWindowConfigurator.swift     # 900 × 600 minimum window size on Mac; no-op elsewhere
│   ├── TipJarService.swift             # StoreKit 2 consumables: verified finish, local dedup, updates/recovery
│   └── UserSettings.swift              # @Observable singleton over UserDefaults
├── RNNoise/                            # Vendored RNNoise C sources + bridging header
├── Bridging/                           # Single Obj-C bridging header (RNNoise + DeepFilter)
├── Resources/
│   ├── Catalog.swift                   # 351 series, 5,481 discourses — static data + URL builder
│   ├── OshoworldCatalog.swift/.json    # crawled oshoworld mp3 paths for the 923 discourses the URL patterns get wrong
│   ├── TranscriptCatalog.swift/.json   # discourse id -> oshoworld audio id/slug for the 4,946 discourses with a transcript
│   ├── AlignmentCatalog.swift/.json    # shipped paragraph start times per discourse (from Tools/AlignTranscripts); works on iOS 18+
│   ├── DeepFilterNet3_onnx.tar.gz      # Bundled DFN3 model (48 kHz, 480-sample hop)
│   └── Assets.xcassets/                # App icon placeholder
scripts/build-transcript-catalog.py     # Regenerates TranscriptCatalog.json (+ --audio-out OshoworldCatalog.json, --list-missing) from the oshoworld API
scripts/extend-archive-catalog.py       # Adds ArchiveCatalog.json entries for app series the archive mirrors but the JSON lacks
Tools/AlignTranscripts/                 # macOS 26 CLI (build.sh + main.swift): downloads every transcribed discourse, runs Apple's recogniser, aligns, writes AlignmentCatalog.json
Tools/NoiseReductionLab/                # macOS DSP snapshots, reference mixtures, measurements and audition WAVs
Tools/MacCatalyst/                      # run-local.sh + ad-hoc LocalRun entitlements/xcconfig for local Mac runs and tests
native/deepfilter-bridge/               # Rust crate + build-xcframework.sh (pinned upstream commit)
Vendor/DeepFilterBridge.xcframework     # Committed static lib: ios-arm64, arm64/x86_64 simulator, arm64/x86_64 Mac Catalyst
Shared/Companion/CompanionProtocol.swift # Watch/iPhone wire models (version 1), compiled into both apps
Signing/                                # App, CarPlay (opt-in configs) and Mac Catalyst sandbox entitlements
WatchApp/                               # watchOS app: Connectivity/, Model/, Offline/ (store, player, position reports), Views/, Debug/ fixtures
WatchTests/                             # Protocol, request client, snapshot ordering, model, offline store, position reports, accent
WatchUITests/                           # Fixture UI tests + opt-in paired-simulator OshoWatchConnectivityUITests
OshoDiscoursesUITests/                  # Adaptive iPad/phone layout, DeNoise presentation, player release visibility
OshoDiscoursesTests/
├── OshoDiscoursesTests.swift           # Catalog + URL builder tests
├── DeepFilterNetTests.swift            # Real model load, bridge contract, denoising, resampled 22.05kHz path, Voice Focus contrast
├── DeepFilterLifecycleTests.swift      # Async load/configuration races and continuous live parameter changes
├── DenoiserStreamTests.swift           # Ragged callbacks across sample rates, failed/oversized buffer recovery
├── NoiseReductionProcessorTests.swift  # RNNoise wet/dry delay, PCM layouts, buffer validation and local counters
├── NoiseDiscontinuityTests.swift       # Source boundaries/read failures, deferred resets and all-channel bypass
├── NoiseTapGenerationTests.swift       # Retired taps, delayed preparation/model loads and per-generation counters
├── SourceAudioTimelineTests.swift      # Timestamp gaps, rational rounding, speed changes and stereo reset boundaries
├── AudioPlayerIntegrationTests.swift   # AVPlayer/tap lifecycle, seek/resume, status and boost availability
├── PolyphaseResamplerTests.swift       # Kaiser stopband, consonant-band fidelity, DC gain and output bounds
├── VolumeBoostTests.swift              # Filtered boost ladder/ceiling and untouched raw bypass
├── TipJarServiceTests.swift            # Fake-backed purchase/verification policy, retries, finish/dedup and pending
├── CarPlay*Tests.swift                 # Templates, scene delegate, session navigation/refresh/disconnect, AppRuntime adapter (serialized CarPlayTests)
├── WatchPhoneSessionTests.swift        # Request validation, cached resends, snapshot throttling and publication
├── WatchRequestHandlerTests.swift      # Expected-discourse guard, rate clamp, playItem routing, receipts, payload bound
├── WatchTransferTests.swift            # Staged transfers, dedupe, inventory + WatchPositionMergerTests
├── MacWindowConfiguratorTests.swift    # Minimum window size on Catalyst, inert elsewhere
├── UnclaimedDownloadTests.swift        # Keep/discard rules for transfers that finish with no app process waiting
├── PlaybackStateTests.swift            # Position/recent/completed + cloud-merge tests
├── ListeningStatsTests.swift           # Daily totals + streak tests
├── SeriesMetadataTests.swift           # Theme/metadata tests
├── UserSettingsTests.swift             # Defaults + persisted-rate/cellular tests
├── SleepTimerTests.swift               # Countdown + end-of-discourse mode tests
├── CloudSyncTests.swift                # Convergent merge rules + snapshot round-trip
├── AudioSessionInterruptionTests.swift # Resume-after-interruption decision
├── SyncMergeTests.swift                # Bookmark union + daily-stats max merge
└── TranscriptTests.swift               # Parser, sync model, state merge, fetcher payloads, service cache, catalog, aligner
```

## Data

### Catalog (static, not in database)
- 351 series (175 English, 176 Hindi)
- 5,481 total discourses — everything oshoworld.com lists (its "Geeta Darshan" placeholder has no audio)
- Source: oshoworld.com (3 URL patterns: underscore, slug, OSHO-prefix, plus `.catalog` for
  series no pattern fits). `buildAudioURL` first consults `OshoworldCatalog.json`, the crawled
  path for each discourse whose pattern URL is wrong — the site renamed files inside ~57 folders
  ("The Perfect Master Vol 1 01.mp3"), and some series skip numbers or mix volumes. Regenerate
  with `scripts/build-transcript-catalog.py --audio-out`; `--list-missing` prints SeriesInfo
  lines for any series the site has added since.
- Archive.org mirror: `Resources/ArchiveCatalog.json` maps ~89% of discourses
  (4,875 across 325 series) to the archive item
  `osho-audio-discourses-collection` — ~12x faster downloads. Downloads try
  archive first, fall back to oshoworld (see `DownloadService.downloadSources`).
  Mirror also provides per-series cover art (first track's extracted PNG),
  shown in thumbnails via `ArchiveCatalog.coverURL`. The original mapping was
  generated offline; `scripts/extend-archive-catalog.py` adds entries for
  series the JSON lacks (folder matched by title; files paired by sorted order
  when the counts agree, or by volume number). Its `UNUSABLE_AUDIO` exclusions
  keep damaged mirrors out, including Wisdom of the Sands #3, whose archive
  file contains less than five minutes of a roughly 90-minute talk.
- Curated lists: Popular English/Hindi, Beginner English/Hindi
- All in `Resources/Catalog.swift` — `Catalog.allSeries`, `Catalog.allDiscourses()`

### Transcripts
- Source: oshoworld.com. Each discourse page is rendered from a JSON API
  (`/api/server/audio/get-description/{audioId}`) that returns the full
  transcript as light HTML (`<br>`/CRLF breaks; `<strong>`, `<q>`, `<cr>`
  mark the quoted question or sutra). No timestamps.
- `Resources/TranscriptCatalog.json` maps discourse id -> oshoworld audio
  `_id` + page `slug` for the **4,946 of 5,481** discourses whose page has
  real text (English 2,968/3,020, Hindi 1,978/2,461; 317 series). Most of the
  Hindi series added in 2026-09 have blank pages on the site. Generated
  by `scripts/build-transcript-catalog.py`: matches by mp3 path, then by
  upload folder + index, then by normalised series title, and probes every
  page's word count so blanks are excluded. Re-run it to pick up new text.
- Text is fetched behind each committed audio download (and backfilled for
  existing downloads), cached in `Application Support/transcripts/` excluded
  from backup, and deleted with the audio. Opening a transcript that isn't
  cached fetches it on demand.
- Sync: paragraph start times come from `AlignmentCatalog.json` (computed on
  a Mac by `Tools/AlignTranscripts`, ~83% of paragraphs matched in the full run, gaps
  interpolated), else on iOS 26 from on-device speech alignment, else from a
  text-length estimate (share of characters = share of duration, 50-character
  floor). The user's "Audio is here" anchors bend all three and win over
  aligned starts they contradict. With aligned timing the reader also marks
  the sentence being spoken (interpolated within the paragraph). By default
  each sentence is its own row (`TranscriptBlocks.sentenceRanges`, fragments
  under 40 letters fold into the previous sentence) so the highlight and
  anchors point at one sentence; the "One sentence per line" toggle in the
  reader menu (`UserSettings.transcriptSentenceLayout`) falls back to blocks
  of ~240 letters cut at sentence boundaries for paragraphs over ~360. The
  highlight, "Play from here" and "Audio is here" act on a row, and a row anchor stores
  its position in the paragraph (`TranscriptAnchor.fraction`, nil = middle
  for anchors from older versions). Anchors +
  last-read paragraph live in `transcript_state.json` and sync via iCloud;
  device alignments stay local. A shipped entry is used only when its
  paragraph count matches the parsed transcript and its duration is within
  2.5 s of the file being played.
- Shipped timing covers 4,932 of 4,946 transcribed discourses: 2,960 English
  and 1,972 Hindi. The remaining 14 failed text matching after all download
  failures were recovered; some site pages contain another discourse's text.

### Translated narration (deferred)

Translated narration is not on `main`. It is preserved on branch
`wip/translated-narration-1.16` (commit `17c9039`) for a later release.

### URL patterns
- English underscore: `https://www.oshoworld.com/wp-content/uploads/newAudios/{Folder}_(count)/{Prefix}_{num}.mp3`
- English slug: `https://www.oshoworld.com/wp-content/uploads/newAudios/{slug}/{Title} {num}.mp3`
- Hindi/English OSHO: `https://www.oshoworld.com/wp-content/uploads/2020/11/{Language} Audio/OSHO-{Prefix}_{num}.mp3`
- Spaces become %20 at request time. Numbers zero-padded to 2 digits (3 if series >= 100).

### Persistence (no SwiftData)
- **Playback positions / recently-played / completed** — `PlaybackStateService` over UserDefaults.
- **Settings** — `UserSettings` over UserDefaults.
- **Tips**: local transaction-ID ledger and legacy count in UserDefaults. Consumables grant no entitlement; the count is device-local.
- **Transcripts** — `Application Support/transcripts/<discourseID>.json` (cached text, backup-excluded) and `transcript_state.json` (anchors, read position, alignment) via `TranscriptStateService`.
- **Downloads** — files on disk, tracked by a JSON manifest in `DownloadService`. The audio folder (`Documents/Osho Discourses/`) is flagged `isExcludedFromBackup` since it's re-downloadable (avoids iCloud-backup bloat + App Store 5.1 rejection).
- **Bookmarks** — `bookmarks.json`; **listening stats** — `listening_stats.json`.
- **Watch (phone side)**: last reported Watch inventory in `watch.inventory.v1`, applied position-report times in `watch.positionApplied.v1`. **Watch side**: `Application Support/Offline/` (audio + `index.json`, backup-excluded). See [Apple Watch](docs/apple-watch.md).

### iCloud sync (live, cross-device) vs device backup
- **Live sync** — `CloudSyncService` mirrors one `CloudSnapshot` through `NSUbiquitousKeyValueStore` (the user's own iCloud, no account/server/toggle). Synced: recent playback positions+durations, completed set, recently-played/completed lists, **bookmarks** (union by id), **daily listening stats** (max seconds per day), and **transcript anchors + read positions** (anchor union replayed oldest-first through the contradiction filter; newest read position wins, with "following again" stored as a timestamped tombstone so it beats a stale position). Merge rules are convergent + idempotent so devices agree regardless of write order; no merge UI, no "last synced" timestamp. Push fires on each progress auto-save and on bookmark add/remove; pull/merge on external change.
- **NOT live-synced** — `UserSettings` (accent, language, speed, toggles) stays per-device. Bookmark *deletions* don't propagate (union-by-id, no tombstones — deletes can resurrect from another device).
- **Device backup**: settings, position history and persistent state files use normal device backup. Downloaded audio and cached transcripts are excluded.

## What's built (MVP)

- [x] Browse 351 series with search + language filters
- [x] Curated sections (Popular/Beginner for English and Hindi)
- [x] Series detail with hero header and discourse list
- [x] Download with progress tracking (background URLSession — continues when app is backgrounded/locked/killed)
- [x] Audio playback (AVPlayer with queue management)
- [x] Background audio + lock screen / Control Center / AirPods controls (MPRemoteCommandCenter, with interruption + route-change recovery)
- [x] Seek slider, playback speed (0.5x–2x, persisted across launches), volume boost (1.5x/2x/3x/4x, gain + peak limiter in the tap)
- [x] Mini-player bar (ultraThinMaterial glass)
- [x] Full player screen (Apple Music style)
- [x] Downloads screen grouped by series + total storage-used meter
- [x] Smart Download (auto-download next 10 min before end)
- [x] Smart Delete (remove after finishing)
- [x] Download-over-cellular toggle (default off; guards Smart Download data use)
- [x] Settings (appearance, language, player/download prefs, noise reduction)
- [x] Playback position persistence (auto-save every 10s)
- [x] Series thumbnails (gradient hash + initials)
- [x] Light/Dark/System appearance switching
- [x] Bookmarks — list with filter chips, swipe-delete, play/redownload (BookmarksView)
- [x] Sleep timer — 5/10/15/30/45/60 min + "End of discourse" mode
- [x] Listening stats dashboard + streak (My Activity tab)
- [x] Noise reduction: RNNoise with Light/Medium/Strong wet/dry mix, 48 kHz conversion and correct two-hop mix alignment, released in 1.15.
- [x] Noise reduction: DeepFilterNet 3 (native Rust/tract, 48 kHz), selected when noise reduction is enabled. Light/Medium/Strong model suppression is 6 dB/12 dB/unlimited; Medium remains the default and noise reduction defaults off.
- [x] Voice Focus: Natural/Gentle Lift/Extra Lift post-processing, independently selectable from model suppression in Settings and the player. Gentle Lift is the first-use default.
- [x] DeNoise interface (1.15): Player > DeNoise and Settings > DeNoise share one screen. Best Quality (DeepFilterNet) is recommended with a battery-use note; Balanced (RNNoise) and Gentle Cleanup (Cadence) are secondary. Boost uses Off/Low/Medium/High/Max levels in the same screen; quiet-speech presets are under Fine-tune the voice. Transcript sits beside DeNoise in the player's bottom controls.
- [x] Neural resampling (1.15): both neural paths use `DenoiserStream` and the Kaiser filter; the earlier resampling implementation covered only DeepFilterNet
- [x] Recently Played / Continue Listening + Recently Completed on Home
- [x] iCloud sync of progress + bookmarks + daily stats (silent, NSUbiquitousKeyValueStore)
- [x] Downloads excluded from iCloud backup (re-downloadable content)
- [x] Feedback (mailto) + on-device-data privacy note in Settings > About
- [x] Tip jar (released in 1.15): Support Development is visible in Settings > About, with the service and view enabled in Release. All five optional consumables are approved and unlock nothing. A full physical-device walkthrough, including Home Screen launch, core screens and a Small tip sandbox purchase, is attached to App Review. The support page is published and the App Store Support URL is updated. See [Tip jar release](#tip-jar-release).
- [x] Transcripts — lyrics-style reader (highlight + auto-follow + "Now playing" pill), per-discourse read position, tap-a-paragraph action bar (Play from here / Audio is here / Copy / Share), search, font size, series-row indicator, fetched with downloads
- [x] Transcript timing shipped for every aligned discourse (AlignmentCatalog, iOS 18+, both languages) + sentence-level highlight
- [x] Transcript shown one sentence per row (lyrics style; toggle back to 4-8 line blocks); state stays per source paragraph
- [x] Transcript speech sync on device (iOS 26) for discourses the catalog lacks — English via SpeechTranscriber, Hindi via DictationTranscriber
- [x] Home > Continue Listening: series name is a link to the series page (Downloads-header style)
- [x] CarPlay (1.16): Continue Listening, Downloads and Bookmarks lists plus shared Now Playing with speed and bookmark buttons. Unit-tested only; never shown on a CarPlay display. Apple approved the audio entitlement on 2026-10-02; it is enabled on the App ID and in App Store profile `A8XF3V4XNH` (docs/app-store/carplay/entitlement-request.md). See [CarPlay](docs/carplay.md).
- [x] Apple Watch (1.16): remote control and browsing of the iPhone, plus Save to Watch for offline listening on Bluetooth headphones with position reports back to the phone. See [Apple Watch](docs/apple-watch.md).
- [x] iPad layout (1.16): sidebar navigation, two-column player with live transcript, adaptive grids, context menus, hover, keyboard shortcuts and menus, multiple windows. See [iPad and Mac](docs/ipad-and-mac.md).
- [x] Mac Catalyst (1.16): Optimize for Mac build of the same target and bundle ID, with DeepFilterNet, Now Playing and the menu bar. Not yet distributed on the Mac App Store. See [iPad and Mac](docs/ipad-and-mac.md#app-store-distribution).

## What's remaining (post-MVP)

- [ ] Favourites — heart toggle on discourses
- [ ] Skip silence / condense pauses
- [ ] Share bookmarks (readable-text export via ShareLink)
- [ ] Osho portrait refinements as player artwork
- [ ] Download size preview before downloading (HEAD request or static estimate)
- [ ] Widget (home screen widget showing current/last played)
- [ ] App Store submission (icon, screenshots, description)

## Key decisions

- **DeNoise first-use defaults:** Best Quality, Medium noise reduction, Medium volume boost (2×) and Gentle Lift. DeNoise starts off; saved preferences take precedence over registered defaults.
- **`AppRuntime` owns the services, not the SwiftUI scene.** CarPlay can cold-launch the app with no phone window, so the player, downloads, playback state, launcher and companion library are created and wired in `AppRuntime.shared.start()` (idempotent, called from `App.init`). Windows, CarPlay and the Watch session all read the same instances.
- **The companion wire contract is versioned and guarded per request.** `CompanionWire.version` is 1 and a peer on another version is rejected. Transport actions carry `expectedDiscourseID`, the talk the Watch displayed, and the phone rejects a mismatch. That replaces a control lease: a tap made against stale state never lands on another talk, and no lease can be left held. Play and pause send `setPlaying(Bool)`, not a toggle, so a late or repeated delivery cannot flip playback back.
- **Watch offline listening uses `transferFile` and position reports.** The phone sends a clone of the download plus metadata; the Watch owns its copy, and deleting the phone download does not remove it. The Watch reports positions with `transferUserInfo`, which arrives once and possibly late. The phone applies a report only if it is newer than its own last listening to that discourse (`playbackSavedAt_<id>`, bumped only when the position moves), and moves a paused, loaded player to the reported position. A playing discourse ignores reports, except that a stretch resumed under 60 s ago from an older point catches up, since a report usually arrives because the listener just pressed play on the phone. The other direction: snapshots carry the phone's saved positions for talks on the Watch, and the Watch adopts newer ones unless the talk is loaded in its own player.
- **CarPlay signing is opt-in.** Apple must approve `com.apple.developer.carplay-audio`. Normal Debug/Release request no CarPlay entitlement so automatic signing works; the scene code ships in them but iOS will not list the app in CarPlay. `Debug-CarPlay`/`Release-CarPlay` (scheme `OshoDiscoursesCarPlay`) sign with `Signing/CarPlay.entitlements`.
- **Mac is Catalyst, not "Designed for iPad", under the same bundle ID.** Catalyst gives a real menu bar, window sizing and the Optimize for Mac idiom. Keeping `com.agraabhi.oshodiscourses` preserves universal purchase, iCloud key-value sync and the tip products. A Mac that has the iPad app from the Mac App Store would receive the Catalyst build in its place.
- **Local Catalyst runs use `com.agraabhi.oshodiscourses.catalyst-local`.** The App Store copy on this Mac owns the real sandbox container; an ad-hoc signer opening it triggers a data-access prompt and blocks launch. Tests use `...catalyst-local.tests` because some suites delete every download in the host's container.
- **Transcripts have no timestamps, so sync is an estimate the listener can correct** — oshoworld publishes plain paragraphs. The highlight assumes speech moves through the text at a constant rate and lets "Audio is here" pin a paragraph to the current time; the map is linear between pins. Measured against speech alignment on A Bird on the Wing #1, the raw estimate drifts up to ~45 s mid-talk (the opening question is read slowly), which one or two anchors remove.
- **Timing ships as data; the device recogniser is the fallback.** Paragraph starts stored as tenth-second deltas cost about 630 bytes per discourse in the full batch. Shipping them gives English and Hindi timing on iOS 18 without running recognition on the phone. The English sample averaged ~18 s per discourse across four workers; long Hindi recordings took several minutes each during the full run. On-device alignment remains available for recordings without matching shipped timing.
- **Hindi speech goes through `DictationTranscriber`, not `SpeechTranscriber`** — iOS 26's `SpeechTranscriber` covers 30 locales with no Hindi, but `DictationTranscriber` (the keyboard-dictation models, same framework) covers 54 including `hi_IN` and runs on device with word time ranges. On Maha Geeta #5 it recognised 9,754 of 10,386 words and aligned 176 of 218 paragraphs (the unmatched are the opening Sanskrit sutras and one-line paragraphs, interpolated). The estimate drifted up to 148 s on that talk, three times the English figure, so Hindi gains most. `SFSpeechRecognizer` `hi-IN` is still server-only, so below iOS 26 Hindi relies on the shipped catalog.
- **The aligner's tokeniser keeps combining marks outside the Latin block** — Devanagari matras, virama and nukta are combining marks that distinguish words (कि/की, क/क्); stripping to ASCII, as the first version did, reduced every Hindi token to nothing. Latin diacritics (U+0300–036F) are still dropped so "café" matches "cafe".
- **`AssetInventory.reserve(locale:)` before any asset call** — without a reservation `assetInstallationRequest` fails with "not subscribed to transcription.en". The simulator reports no supported speech locales at all; test alignment on a device or via the macOS harness.
- **Transcript matching is by mp3 path, never by folder alone** — every Hindi series shares one upload folder, so folder+index is only trusted when the folder holds a single series. All 5,481 discourses map to a page; 535 pages are blank and are left out of the catalog.
- **Static catalog, not fetched** — 5,481 discourses hardcoded. Updates via app releases. No server needed.
- **The pattern URLs are a fallback; the crawled paths are the truth** — 717 of the original 4,361 discourses had oshoworld URLs that 404 (the site renamed files in 57 folders); the archive mirror hid most of it, but 74 were undownloadable. Storing only the differing paths keeps the JSON at ~110 KB while the scripts stay the single place that knows the site.
- **Vendored native denoisers.** The app uses Apple frameworks plus RNNoise C sources and the DeepFilterNet Rust/tract bridge, linked statically without an app package manager. DeepFilterNet adds native inference cost and a bundled model to reduce tape hiss and overlapping noise; results vary by recording.
- **Both neural models need 48 kHz input.** Maha Geeta #5 is 22,050 Hz, 43 kbps, with a byte-identical archive.org mirror. The earlier resampling fix covered only DeepFilterNet. RNNoise still processed source-rate samples through `b627551` and delayed its dry mix by one hop instead of the model's two. The next-release `RNNoiseProcessor` and shared `DenoiserStream` fix the rate and 960-model-sample alignment; the Kaiser filter also preserves the upper speech band. See the dated evidence in [Noise Reduction Lab](docs/noise-reduction-lab.md).
- **The denoise gate is slow to close, never fast** — Osho's sentences decay in level, so the model's local SNR collapses on his final words. A conventional fast-closing gate (the first attempt used 10 ms) mutes the end of every sentence. The gate now opens in 8 ms, holds ~220 ms after speech, then closes over 400 ms; levelling tracks running speech level rather than per-frame level, which otherwise boosts quiet noise in the gaps harder than the voice.
- **Noise that overlaps speech is attacked in time, not frequency** — an aircraft at 40:20 of Maha Geeta #5 occupies the same 150-700 Hz as the voice, with only ~0.5% of energy above 3 kHz. So Voice Focus raises speech-to-pause contrast using the model's own local SNR instead of EQ. Downward compression was measured and rejected (it lifts pauses too); DSP without the model was worse than doing nothing.
- **A volume boost spends crest factor, it does not multiply loudness** — the archive averages -13.8 dBFS against 0 dBFS peaks, so plain gain only clips. The boost applies gain inside the tap followed by a peak limiter, which converts the ~14 dB of crest into real level: measured +1.9/+3.1/+4.1/+4.6 dB for 1.5x/2x/3x/4x on a 12.9 dB-crest signal, never exceeding -0.3 dBFS. Going louder than that needs compression, which would flatten Osho's dynamics.
- **The chain must never add level** — this archive is already mastered into full scale (Maha Geeta #5 peaks at 0 dBFS), so the emphasis bell's +3.5 dB and up to 9 dB of speech lift simply clipped: measured +3.3 dBFS with Focus and +10.1 dBFS with Lift. The bell is now normalised to unity peak (a cut elsewhere, not a boost), the lift is capped by the frame's own peak, and a safety limiter catches the rest. Fixing the causes mattered: a limiter alone engaged on 44% of samples, which is a compressor, not a safety net.
- **`reset()` must not re-init the model.** `dfb_reset` forwards to upstream's `DfTract::init()`, which never clears `rolling_spec_buf_x`. The old reset path added 5 hops each time: 103, 153, 203, 253, then 303 ms. After about eight resets the output FIFO overflowed and DeepFilterNet fell back to passthrough. Eight silent hops displace stale spectra without that growth. The earlier resampler measured about 53 ms; the Kaiser-filter probe measures about 58.6 ms at both zero and twelve resets.
- **Each tap owns its DSP generation.** `NoiseReductionTapContext` owns the stream, model and counters for one tap. Retirement prevents old callbacks or delayed loads from changing the replacement's state. A new DeepFilterNet tap loads its own model asynchronously, with a short raw bypass accepted during loading. Strength, Voice Focus and boost updates retain the tap and neural history. Source flags and asset-time continuity trigger deferred resets. Simulator AVPlayer tests cover seeks that omit discontinuity flags, including loss and recovery of valid timestamps.
- **Model readiness is separate from processed audio.** The player uses recent outcome counters from the current tap for status and boost availability. The stream applies gain only to processed buffers. Local OSLog records setup and status transitions, while fixed counters record callback outcomes; there are no per-callback logs or remote telemetry. Swift streaming buffers are preallocated, but native tract inference still allocates.
- **DeepFilterNet runs on a mono mix, not per channel** — the downloads are joint stereo whose channels differ by only -18.4 dB, so per-channel inference cost twice as much to reproduce nearly the same signal, and two independent gates made the stereo image wander.
- **Pre-rendering after download was built and removed** — it worked, but settings baked into each file (killing instant A/B), an ~85 minute discourse took ~20 minutes to render, and every copy doubled that discourse's storage. See `docs/noise-reduction-lab.md`.
- **DeepFilterNet strength is a native attenuation limit.** Light / Medium / Strong use 6 dB / 12 dB / unlimited suppression, independently of Voice Focus. The model caps suppression using aligned spectra internally; the app does not add an external dry/wet blend. Medium remains the default.
- **DeepFilterNet failures degrade to passthrough** — a panic-safe Rust bridge (`catch_unwind`) plus explicit UI status, so a bad model or frame never crashes playback and never silently substitutes another denoiser.
- **Optional tips use StoreKit consumables.** App Review rejected this app's earlier buymeacoffee link under 3.1.1. The chosen replacement is five repeatable, one-time purchases that unlock no features or content. The implementation is enabled in Release, and the products and review assets are configured in App Store Connect. A physical-device TestFlight walkthrough verifies a Small tip sandbox purchase; broader purchase-flow coverage remains release work. See [Tip jar release](#tip-jar-release).
- **No database** — catalog is static structs, downloads tracked by filesystem, settings in UserDefaults.
- **Services as @Observable** — injected via .environment(), shared app-wide.
- **Every scrolling page in a tab calls `.reservesMiniPlayerSpace()`.** The floating mini-player overlays the tabs, so each page adds a bottom inset sized from the measured player (it follows Dynamic Type). A safe-area inset on the tab itself does not reach pages pushed inside its NavigationStack, so the height travels as the `miniPlayerClearance` environment value instead. It is zero in the player sheet and where the iOS 26.1 tab accessory hosts the player. `MiniPlayerClearanceTests` checks the last row of Home, Series, Library, Settings and Listening Stats.
- **Apple Music dark UI** — true black, white text, .ultraThinMaterial for glass, SF Symbols.

## Previous React Native version

At `~/projects/OshoDiscourses/` — feature-complete but had stability issues (Metro bundler disconnects, native module crashes, ffmpeg-kit deprecated). This Swift rewrite resolves those by going fully native.

Features from the RN version — port status:
- [x] Bookmarks with time ranges and notes (share export still pending)
- [ ] Favourites with heart toggle
- [x] Voice boost (1.5x volume via audio mix)
- [ ] Skip silence (rate increase during pauses)
- [x] Sleep timer (presets + end-of-discourse)
- [x] Smart download/delete
- [x] Filter chips (All/Hindi/English/Downloaded/theme tags; Favourited still pending)
- [x] Recently played tracking (Continue Listening on Home)
- [ ] Download size estimates (~30MB English, ~20MB Hindi)

## Dev notes

- 1.16.0 (28) was approved and released on 2026-10-03 with CarPlay, Apple Watch and iPad; the Mac app is a later submission. See [the release record](docs/app-store/releases/1.16.0.md).
- 1.16.1 (29) was submitted on 2026-10-06 (`WAITING_FOR_REVIEW`, release after approval). It adds en-GB and Hindi store listings, new keywords, reordered screenshots, Health & Fitness as the secondary category, a Settings > About > Rate Osho Talks link and a broader review prompt. See [the release record](docs/app-store/releases/1.16.1.md).
- 1.15.0 (26) is released, and all five consumable tips are approved, verified on 2026-09-19. Build 26 includes the corrected feedback email. This follows build 25's rejection under 2.1(b) (tips could not be found) and 1.5 (Support URL). The attached 60.66-second TestFlight build 25 walkthrough starts on the iPhone Home Screen, demonstrates core screens and completes a US$3 Small tip sandbox purchase with the count increasing from two to three. `SUPPORT.md` is published in commit `9304509`, and the App Store Support URL points to it. Build 26 passed 413 functions / 512 runs, five iPhone SE UI scenarios and Release signing/content checks. See [the release record](docs/app-store/releases/1.15.0.md) for evidence, submission IDs, artifacts and the replacement signing setup.
- xcodegen required: `brew install xcodegen`
- Files auto-discovered — just drop .swift files in the right directory, run `xcodegen generate`
- Simulators: the `Osho …` dev simulators were deleted on 2026-10-02 to free disk space. Recreate as needed (iOS/watchOS 26.5): `xcrun simctl create "Osho iPhone 17 Pro" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro com.apple.CoreSimulator.SimRuntime.iOS-26-5`, likewise `Osho iPad Pro 13` (iPad-Pro-13-inch-M5-12GB), `Osho iPhone SE` (iPhone-SE-3rd-generation) and `Osho Watch 46mm` (Apple-Watch-Series-11-46mm, watchOS-26-5), then `xcrun simctl pair <watch> <phone>`. Unit tests delete simulator downloads, so seed again after running them.
- Audio Enhancement and DeNoise UI scenarios run through the `OshoDiscoursesUI` scheme on `Osho iPhone 17 Pro` and `Osho iPhone SE`, including large text, dark appearance and Settings with the mini-player visible. Earlier results are in `build/audio-enhancement-ui-verified.xcresult`, `build/denoise-player-controls.xcresult` and `build/denoise-settings-scroll.xcresult`.
- Paired Watch test: boot `Osho iPhone 17 Pro` and `Osho Watch 46mm`, seed A Bird on the Wing #1-#3 on the phone, and launch the phone app with `-debugTranscript english-A_Bird_on_the_Wing__-1 -debugPlayer`. Then run `OshoDiscoursesWatchUI` on the Watch with `TEST_RUNNER_OSHO_WATCH_INTEGRATION=1` to include `OshoWatchConnectivityUITests`. The simulator never delivers `transferFile` to the Watch app, although the phone reports it finished; file delivery, Bluetooth playback and position reports need a physical Watch. See [Apple Watch](docs/apple-watch.md).
- Mac: `Tools/MacCatalyst/run-local.sh launch [app arguments]` builds Debug with ad-hoc signing and opens it; `... test` runs the unit tests on My Mac. Local data lives in `~/Library/Containers/com.agraabhi.oshodiscourses.catalyst-local/Data`. See [iPad and Mac](docs/ipad-and-mac.md#local-runs-and-tests).
- CarPlay: unit tests run under `-only-testing:OshoDiscoursesTests/CarPlayTests`. This Xcode 27 install lacks the Simulator app, so there is no CarPlay external display. See [CarPlay](docs/carplay.md).
- Broader StoreKit purchase-flow coverage, listening preference and sustained phone battery/thermal behavior remain release checks. Offline DSP evidence and reproduction commands are in [Noise Reduction Lab](docs/noise-reduction-lab.md).
- Regenerate shipped timings: `Tools/AlignTranscripts/build.sh` then `build/AlignTranscripts/AlignTranscripts align --parallel 4` (resumable; per-discourse results in `build/alignments/`). Use `... align --parallel 2 --retry-downloads` for failed audio fetches, or `--retry-failed` to include recognition failures. `... merge` writes `AlignmentCatalog.json`; `... report` prints coverage. Needs macOS 26; the first run downloads the hi_IN and en_IN speech assets.
- Debug launch arguments (DEBUG builds only): `-debugTranscript <discourseID>` plays an already-downloaded discourse and opens its transcript; add `-debugPlayer` to open the full player instead, `-debugDownload <discourseID>` to run a real download and log the source/bytes, `-debugTranscriptSearch <query>` to open search, `-debugTranscriptSelect <n>` to show a paragraph's action bar, `-debugTranscriptFollow` to ignore a saved read position, `-debugTipJar` to open the tip sheet. `-settings.transcriptSpeechSync 1` pre-enables speech sync (UserDefaults argument domain). `-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityL` checks large text.
- `-debugPlayerDiscourse <discourseID>` opens a paused player with catalog metadata and no audio download. `OshoDiscoursesUI` uses it for DeNoise/Transcript and release-visibility checks. `-debugPlaySample <discourseID>` plays two minutes of generated silence under that discourse's metadata, `-debugMiniPlayer 1` leaves the player closed and `-debugTab <tab>` selects a tab.
- Small screens: verified on `Osho iPhone SE` (3rd gen). The transcript search and transport bars cap Dynamic Type at xxxLarge so they stay on one line at 375 pt; body text uses the in-reader size control instead.
- Transcript reader keeps the screen awake (`isIdleTimerDisabled`) only while its discourse is playing and the app is active.
- Seed a simulator download for testing: copy an mp3 to `Documents/Osho Discourses/<Series>/<Series> - #N.mp3` and write `{"<discourseID>": "<relative path>"}` to `Library/Application Support/.download_manifest.json`. Unit tests delete simulator downloads (`DownloadDeleteTests`), so seed again after running them.
- Dynamic Island / Live Activity was removed (was a Live Activity hosted by a now-deleted widget extension); standard lock-screen/Control-Center controls stay via MediaPlayer

### Tip jar release

`TipJarService` and `TipJarView` are enabled in Debug and Release, and Settings >
About > Support Development opens the sheet. Missing or partially available
products show an explanation and Try Again; available products remain selectable.
The service records verified tip transactions before finishing them, deduplicates
purchase/update/recovery delivery, and handles pending approvals through
`Transaction.updates`. Unverified transactions remain unfinished for recovery.

| Product ID | Name | US base price |
| --- | --- | ---: |
| `com.agraabhi.oshodiscourses.tip.small` | Small tip | US$3 |
| `com.agraabhi.oshodiscourses.tip.medium` | Generous tip | US$5 |
| `com.agraabhi.oshodiscourses.tip.large` | Big tip | US$10 |
| `com.agraabhi.oshodiscourses.tip.grand` | Grand tip | US$25 |
| `com.agraabhi.oshodiscourses.tip.patron` | Patron tip | US$50 |

Names, descriptions and localized display prices come from StoreKit products.
The prices above are configured US base prices, not hardcoded purchase-button labels.
`TipJarView` displays `Product.displayPrice`, including the currency and formatting
for the customer's App Store storefront. The phone's language or physical location
does not select the purchase currency. App Store Connect can generate regional
prices from a US base price, accounting for exchange rates and certain taxes;
individual country/region prices can also be customized. The local StoreKit file
uses the USA storefront and `en_US` locale, so its default preview shows dollars.

1. **App Store Connect:** all five **Consumable** products were created on
   2026-09-16 with these exact IDs, US base prices, automatic regional prices and
   availability in all 175 app storefronts. English names/descriptions, review
   notes and screenshots are uploaded; each product reached `READY_TO_SUBMIT`.
   [Product IDs and assets](docs/app-store/in-app-purchases/README.md) record the
   setup and verification.
2. **Local Xcode testing:** select `OshoDiscourses/TipJar.storekit` in the
   OshoDiscourses scheme's Run > Options > StoreKit Configuration, then launch
   from Xcode. `project.yml` supplies this Run configuration. Exercise purchases,
   cancellation, Ask to Buy/pending approval and failure/retry with Xcode's
   StoreKit transaction tools. The file simulates products locally; it does not
   create App Store Connect records.
3. **Real sandbox testing:** after product setup, install the release candidate
   through TestFlight. TestFlight uses the App Store Connect products in Apple's
   sandbox, independently of the local `.storekit` file. Check all five products
   and localized prices, a completed and repeated tip, cancellation, pending
   approval where available, and reopening the app without double-counting.
   The attached physical-device walkthrough includes Home Screen launch, core
   features, a successful Small tip sandbox purchase and the in-app count increment.
   Broader purchase-flow coverage remains a separate check.
4. **Submission:** all five consumables were resubmitted with **1.15.0 (26)** in
   submission `a04b9660-b31f-4ff8-9e83-4958e34417d6`. Readback on 2026-09-19 confirmed
   the app is `READY_FOR_DISTRIBUTION`, the submission is `COMPLETE`, and all five
   tip products are `APPROVED`. The full walkthrough is attached, the Support URL
   points to the published support page, and build 26 includes the corrected email.
   See the [release record](docs/app-store/releases/1.15.0.md).

`TipJarServiceTests` uses fake transactions and injected load/purchase operations.
Unit coverage includes missing-product retry, verified finish/dedup, pending
approval, cancellation, unverified/revoked purchases, concurrent delivery and
relaunch persistence. This does not validate real product discovery or sandbox
transactions. Earlier `simctl launch` and `SKTestSession` runs under
`xcodebuild test` returned no products in this environment. Launching through Xcode
with the local StoreKit configuration displayed all five tiers and matching US
prices for the review screenshot. The attached physical-device walkthrough covers
Home Screen launch and core screens, shows all five prices, and records Small tip
sandbox success with the app's count increment.
Local OSLog category `TipJar` records product
availability and purchase/transaction outcomes.
