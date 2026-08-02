# OshoDiscourses — Native iOS App

iOS app for browsing, downloading, and playing Osho audio discourses from oshoworld.com. Pure Swift/SwiftUI — no third-party dependencies.

## Quick start

```bash
cd ~/projects/OshoDiscourses-Swift
xcodegen generate
xcodebuild -project OshoDiscourses.xcodeproj -scheme OshoDiscourses \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Regenerate `.xcodeproj` after adding/removing files:
```bash
xcodegen generate
```

## Stack

- Swift 6.0, SwiftUI, iOS 18+
- AVFoundation + MediaPlayer (audio playback + lock screen controls)
- Apple frameworks only, with one vendored native exception: DeepFilterNet
  (Rust/tract, built into `Vendor/DeepFilterBridge.xcframework`)
- No SwiftData — catalog is static structs, settings use UserDefaults, downloads tracked by filesystem

## Architecture

```
OshoDiscourses/
├── App/OshoDiscoursesApp.swift         # @main entry, environment injection
├── Views/
│   ├── ContentView.swift               # TabView: Home, Library, My Activity, Settings
│   ├── Home/HomeView.swift             # Browse screen — search, curated sections, all series list
│   ├── Library/LibraryView.swift       # Full series list with dynamic filter chips + sort
│   ├── Series/SeriesDetailView.swift   # Hero header, discourse list, download/play actions
│   ├── Player/PlayerView.swift         # Full-screen player — artwork, slider, controls, speed, sleep timer
│   ├── Player/MiniPlayerView.swift     # Floating mini-player bar (ultraThinMaterial)
│   ├── Downloads/DownloadsView.swift   # "My Activity" tab — downloads + stats/bookmarks links + storage meter
│   ├── BookmarksView.swift             # Bookmark list (built) — filter chips, swipe-delete, play/redownload
│   ├── Settings/SettingsView.swift     # Preferences: language, player/downloads, noise reduction, appearance, about
│   └── Settings/ListeningStatsView.swift # Listening stats dashboard
├── Services/
│   ├── AudioPlayerService.swift        # AVPlayer + lock screen controls + audio-session interruption/route recovery
│   ├── DownloadService.swift           # Background URLSession downloads (survive app switch/lock/process death); excludes downloads from iCloud backup
│   ├── PlaybackStateService.swift      # Auto-saves position per discourse every 10s; owns cloud merge logic
│   ├── CloudSyncService.swift          # Silent NSUbiquitousKeyValueStore sync of progress + bookmarks + daily stats
│   ├── SleepTimerService.swift         # Countdown + end-of-discourse sleep modes
│   ├── BookmarkService.swift           # Bookmarks persisted to bookmarks.json; union-by-id cloud merge
│   ├── ListeningStatsService.swift     # Daily listening totals + streak (listening_stats.json); max-per-day cloud merge
│   ├── NoiseReductionProcessor.swift   # Tap host: RNNoise + Cadence DSP, delegates DeepFilterNet
│   ├── DeepFilterProcessor.swift       # DeepFilterNet 3 via native Rust/tract bridge (resample, async load, status)
│   ├── PolyphaseResampler.swift        # 22.05kHz catalog <-> 48kHz model rate (streaming, allocation-free)
│   ├── VoiceFocusChain.swift           # Voice-forward presets: SNR ducking + quiet-speech lift + emphasis
│   └── UserSettings.swift              # @Observable singleton over UserDefaults
├── RNNoise/                            # Vendored RNNoise C sources + bridging header
├── Bridging/                           # Single Obj-C bridging header (RNNoise + DeepFilter)
├── Resources/
│   ├── Catalog.swift                   # 261 series, 4,361 discourses — static data + URL builder
│   ├── DeepFilterNet3_onnx.tar.gz      # Bundled DFN3 model (48 kHz, 480-sample hop)
│   └── Assets.xcassets/                # App icon placeholder
native/deepfilter-bridge/               # Rust crate + build-xcframework.sh (pinned upstream commit)
Vendor/DeepFilterBridge.xcframework     # Committed static lib: ios-arm64 + arm64/x86_64 simulator
OshoDiscoursesTests/
├── OshoDiscoursesTests.swift           # Catalog + URL builder tests
├── DeepFilterNetTests.swift            # Real model load, bridge contract, denoising, resampled 22.05kHz path, Voice Focus contrast
├── PolyphaseResamplerTests.swift       # Ratio reduction, DC/tone fidelity, anti-aliasing, round trip
├── PlaybackStateTests.swift            # Position/recent/completed + cloud-merge tests
├── ListeningStatsTests.swift           # Daily totals + streak tests
├── SeriesMetadataTests.swift           # Theme/metadata tests
├── UserSettingsTests.swift             # Defaults + persisted-rate/cellular tests
├── SleepTimerTests.swift               # Countdown + end-of-discourse mode tests
├── CloudSyncTests.swift                # Convergent merge rules + snapshot round-trip
├── AudioSessionInterruptionTests.swift # Resume-after-interruption decision
└── SyncMergeTests.swift                # Bookmark union + daily-stats max merge
```

## Data

### Catalog (static, not in database)
- 261 series (155 English, 106 Hindi)
- 4,361 total discourses
- Source: oshoworld.com (3 URL patterns: underscore, slug, OSHO-prefix)
- Archive.org mirror: `Resources/ArchiveCatalog.json` maps ~90% of discourses
  (3,946 across 238 series) to the archive item
  `osho-audio-discourses-collection` — ~12x faster downloads. Downloads try
  archive first, fall back to oshoworld (see `DownloadService.downloadSources`).
  Mirror also provides per-series cover art (first track's extracted PNG),
  shown in thumbnails via `ArchiveCatalog.coverURL`. Mapping generated offline
  from the archive metadata API; regenerate by re-running the matcher against
  a fresh `archive.org/metadata/osho-audio-discourses-collection` dump.
- Curated lists: Popular English/Hindi, Beginner English/Hindi
- All in `Resources/Catalog.swift` — `Catalog.allSeries`, `Catalog.allDiscourses()`

### URL patterns
- English underscore: `https://www.oshoworld.com/wp-content/uploads/newAudios/{Folder}_(count)/{Prefix}_{num}.mp3`
- English slug: `https://www.oshoworld.com/wp-content/uploads/newAudios/{slug}/{Title} {num}.mp3`
- Hindi/English OSHO: `https://www.oshoworld.com/wp-content/uploads/2020/11/{Language} Audio/OSHO-{Prefix}_{num}.mp3`
- Spaces become %20 at request time. Numbers zero-padded to 2 digits (3 if series >= 100).

### Persistence (no SwiftData)
- **Playback positions / recently-played / completed** — `PlaybackStateService` over UserDefaults.
- **Settings** — `UserSettings` over UserDefaults.
- **Downloads** — files on disk, tracked by a JSON manifest in `DownloadService`. The audio folder (`Documents/Osho Discourses/`) is flagged `isExcludedFromBackup` since it's re-downloadable (avoids iCloud-backup bloat + App Store 5.1 rejection).
- **Bookmarks** — `bookmarks.json`; **listening stats** — `listening_stats.json`.

### iCloud sync (live, cross-device) vs device backup
- **Live sync** — `CloudSyncService` mirrors one `CloudSnapshot` through `NSUbiquitousKeyValueStore` (the user's own iCloud, no account/server/toggle). Synced: recent playback positions+durations, completed set, recently-played/completed lists, **bookmarks** (union by id), and **daily listening stats** (max seconds per day). Merge rules are convergent + idempotent so devices agree regardless of write order; no merge UI, no "last synced" timestamp. Push fires on each progress auto-save and on bookmark add/remove; pull/merge on external change.
- **NOT live-synced** — `UserSettings` (accent, language, speed, toggles) stays per-device. Bookmark *deletions* don't propagate (union-by-id, no tombstones — deletes can resurrect from another device).
- **Device backup** — everything in the app container (settings, full position history, the JSON files) rides the normal iCloud device backup; only the downloads folder is excluded.

## What's built (MVP)

- [x] Browse 261 series with search + language filters
- [x] Curated sections (Popular/Beginner for English and Hindi)
- [x] Series detail with hero header and discourse list
- [x] Download with progress tracking (background URLSession — continues when app is backgrounded/locked/killed)
- [x] Audio playback (AVPlayer with queue management)
- [x] Background audio + lock screen / Control Center / AirPods controls (MPRemoteCommandCenter, with interruption + route-change recovery)
- [x] Seek slider, playback speed (0.5x–2x, persisted across launches), volume boost
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
- [x] Noise reduction — RNNoise neural denoise with Light/Medium/Strong wet-dry mix
- [x] Noise reduction — DeepFilterNet 3 (native Rust/tract, 48 kHz, strength = attenuation limit)
- [x] Voice Focus — Focus/Lift/Strong presets that make Osho's voice sit forward over overlapping noise
- [x] Resampling so the 48 kHz models actually run on the 22.05 kHz catalog
- [x] Recently Played / Continue Listening + Recently Completed on Home
- [x] iCloud sync of progress + bookmarks + daily stats (silent, NSUbiquitousKeyValueStore)
- [x] Downloads excluded from iCloud backup (re-downloadable content)
- [x] Feedback (mailto) + on-device-data privacy note in Settings > About

## What's remaining (post-MVP)

- [ ] Favourites — heart toggle on discourses
- [ ] Skip silence / condense pauses
- [ ] Share bookmarks (readable-text export via ShareLink)
- [ ] Osho portrait refinements as player artwork
- [ ] Download size preview before downloading (HEAD request or static estimate)
- [ ] Widget (home screen widget showing current/last played)
- [ ] App Store submission (icon, screenshots, description)

## Key decisions

- **Static catalog, not fetched** — 4,361 discourses hardcoded. Updates via app releases. No server needed.
- **Almost no third-party deps** — everything from Apple frameworks except the vendored RNNoise C sources and the DeepFilterNet Rust/tract bridge, both linked statically with no package manager. Adding DeepFilterNet was a deliberate trade: it is the only option that removes steady tape hiss and noise overlapping speech.
- **The catalog is 22.05 kHz, not 48 kHz** — the Hindi talks are 22,050 Hz 43 kbps MP3s (the archive.org mirror is byte-identical). Both neural denoisers are 48 kHz models, so without `PolyphaseResampler` DeepFilterNet was bypassed entirely and RNNoise ran on mis-mapped bands. This was the real reason noise reduction "did nothing".
- **The denoise gate is slow to close, never fast** — Osho's sentences decay in level, so the model's local SNR collapses on his final words. A conventional fast-closing gate (the first attempt used 10 ms) mutes the end of every sentence. The gate now opens in 8 ms, holds ~220 ms after speech, then closes over 400 ms; levelling tracks running speech level rather than per-frame level, which otherwise boosts quiet noise in the gaps harder than the voice.
- **Noise that overlaps speech is attacked in time, not frequency** — an aircraft at 40:20 of Maha Geeta #5 occupies the same 150-700 Hz as the voice, with only ~0.5% of energy above 3 kHz. So Voice Focus raises speech-to-pause contrast using the model's own local SNR instead of EQ. Downward compression was measured and rejected (it lifts pauses too); DSP without the model was worse than doing nothing.
- **DeepFilterNet strength = attenuation limit, not dry/wet** — blending the untouched signal back in would reintroduce the very noise the model removed, and would need sample-alignment against the model's lookahead. Output is always fully wet.
- **DeepFilterNet failures degrade to passthrough** — a panic-safe Rust bridge (`catch_unwind`) plus explicit UI status, so a bad model or frame never crashes playback and never silently substitutes another denoiser.
- **No database** — catalog is static structs, downloads tracked by filesystem, settings in UserDefaults.
- **Services as @Observable** — injected via .environment(), shared app-wide.
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

- xcodegen required: `brew install xcodegen`
- Files auto-discovered — just drop .swift files in the right directory, run `xcodegen generate`
- Simulator: iPhone 17 Pro (iOS 26.5) — UUID 8FAAABA5-25F8-4678-A8F1-B1D6B1104FB0
- Build succeeds as of 2026-07-09 (125 tests passing)
- Dynamic Island / Live Activity was removed (was a Live Activity hosted by a now-deleted widget extension); standard lock-screen/Control-Center controls stay via MediaPlayer
