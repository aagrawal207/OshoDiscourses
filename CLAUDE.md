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
│   ├── Home/HomeView.swift             # Home — Continue Listening (series name links to series), curated sections
│   ├── Library/LibraryView.swift       # Full series list with dynamic filter chips + sort
│   ├── Series/SeriesDetailView.swift   # Hero header, discourse list, download/play actions
│   ├── Player/PlayerView.swift         # Full-screen player — artwork, slider, controls, speed, sleep timer, transcript button
│   ├── Player/TranscriptView.swift     # Lyrics-style transcript sheet — highlight, auto-follow, anchors, search, font size
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
│   ├── TranscriptService.swift         # Fetch + disk cache of transcripts; prefetch behind downloads, backfill, delete-with-audio
│   ├── TranscriptFetcher.swift         # oshoworld JSON API with __NEXT_DATA__ page-scrape fallback
│   ├── TranscriptParser.swift          # Transcript model + oshoworld HTML -> paragraphs (emphasis blocks = question/sutra)
│   ├── TranscriptSyncModel.swift       # Time <-> paragraph map: text-fraction estimate bent by anchors/aligned knots
│   ├── TranscriptStateService.swift    # Per-discourse anchors, read position, alignment; transcript_state.json; cloud merge
│   ├── SpeechAlignmentService.swift    # Experimental: on-device SpeechTranscriber (iOS 26, English) -> paragraph timings
│   ├── SpeechWordRecognizer.swift      # SpeechAnalyzer wrapper: asset reservation, words with time ranges
│   ├── TranscriptAligner.swift         # Unique-trigram landmarks + LIS chain -> paragraph start times
│   └── UserSettings.swift              # @Observable singleton over UserDefaults
├── RNNoise/                            # Vendored RNNoise C sources + bridging header
├── Bridging/                           # Single Obj-C bridging header (RNNoise + DeepFilter)
├── Resources/
│   ├── Catalog.swift                   # 351 series, 5,481 discourses — static data + URL builder
│   ├── OshoworldCatalog.swift/.json    # crawled oshoworld mp3 paths for the 923 discourses the URL patterns get wrong
│   ├── TranscriptCatalog.swift/.json   # discourse id -> oshoworld audio id/slug for the 4,946 discourses with a transcript
│   ├── DeepFilterNet3_onnx.tar.gz      # Bundled DFN3 model (48 kHz, 480-sample hop)
│   └── Assets.xcassets/                # App icon placeholder
scripts/build-transcript-catalog.py     # Regenerates TranscriptCatalog.json (+ --audio-out OshoworldCatalog.json, --list-missing) from the oshoworld API
scripts/extend-archive-catalog.py       # Adds ArchiveCatalog.json entries for app series the archive mirrors but the JSON lacks
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
  (4,876 across 325 series) to the archive item
  `osho-audio-discourses-collection` — ~12x faster downloads. Downloads try
  archive first, fall back to oshoworld (see `DownloadService.downloadSources`).
  Mirror also provides per-series cover art (first track's extracted PNG),
  shown in thumbnails via `ArchiveCatalog.coverURL`. The original mapping was
  generated offline; `scripts/extend-archive-catalog.py` adds entries for
  series the JSON lacks (folder matched by title; files paired by sorted order
  when the counts agree, or by volume number).
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
- Sync: the highlight is an estimate (paragraph share of characters = share
  of duration, with a 50-character floor per paragraph) bent by the user's
  "Audio is here" anchors, or by on-device speech alignment when enabled.
  Anchors + last-read paragraph live in `transcript_state.json` and sync via
  iCloud; alignments stay device-local.

### URL patterns
- English underscore: `https://www.oshoworld.com/wp-content/uploads/newAudios/{Folder}_(count)/{Prefix}_{num}.mp3`
- English slug: `https://www.oshoworld.com/wp-content/uploads/newAudios/{slug}/{Title} {num}.mp3`
- Hindi/English OSHO: `https://www.oshoworld.com/wp-content/uploads/2020/11/{Language} Audio/OSHO-{Prefix}_{num}.mp3`
- Spaces become %20 at request time. Numbers zero-padded to 2 digits (3 if series >= 100).

### Persistence (no SwiftData)
- **Playback positions / recently-played / completed** — `PlaybackStateService` over UserDefaults.
- **Settings** — `UserSettings` over UserDefaults.
- **Transcripts** — `Application Support/transcripts/<discourseID>.json` (cached text, backup-excluded) and `transcript_state.json` (anchors, read position, alignment) via `TranscriptStateService`.
- **Downloads** — files on disk, tracked by a JSON manifest in `DownloadService`. The audio folder (`Documents/Osho Discourses/`) is flagged `isExcludedFromBackup` since it's re-downloadable (avoids iCloud-backup bloat + App Store 5.1 rejection).
- **Bookmarks** — `bookmarks.json`; **listening stats** — `listening_stats.json`.

### iCloud sync (live, cross-device) vs device backup
- **Live sync** — `CloudSyncService` mirrors one `CloudSnapshot` through `NSUbiquitousKeyValueStore` (the user's own iCloud, no account/server/toggle). Synced: recent playback positions+durations, completed set, recently-played/completed lists, **bookmarks** (union by id), **daily listening stats** (max seconds per day), and **transcript anchors + read positions** (anchor union replayed oldest-first through the contradiction filter; newest read position wins, with "following again" stored as a timestamped tombstone so it beats a stale position). Merge rules are convergent + idempotent so devices agree regardless of write order; no merge UI, no "last synced" timestamp. Push fires on each progress auto-save and on bookmark add/remove; pull/merge on external change.
- **NOT live-synced** — `UserSettings` (accent, language, speed, toggles) stays per-device. Bookmark *deletions* don't propagate (union-by-id, no tombstones — deletes can resurrect from another device).
- **Device backup** — everything in the app container (settings, full position history, the JSON files) rides the normal iCloud device backup; only the downloads folder is excluded.

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
- [x] Noise reduction — RNNoise neural denoise with Light/Medium/Strong wet-dry mix
- [x] Noise reduction — DeepFilterNet 3 (native Rust/tract, 48 kHz, strength = attenuation limit). Default mode when noise reduction is switched on; noise reduction itself still defaults off.
- [x] Voice Focus — Focus/Lift/Strong presets that make Osho's voice sit forward over overlapping noise
- [x] Resampling so the 48 kHz models actually run on the 22.05 kHz catalog
- [x] Recently Played / Continue Listening + Recently Completed on Home
- [x] iCloud sync of progress + bookmarks + daily stats (silent, NSUbiquitousKeyValueStore)
- [x] Downloads excluded from iCloud backup (re-downloadable content)
- [x] Feedback (mailto) + on-device-data privacy note in Settings > About
- [x] Transcripts — lyrics-style reader (highlight + auto-follow + "Now playing" pill), per-discourse read position, tap-a-paragraph action bar (Play from here / Audio is here / Copy / Share), search, font size, series-row indicator, fetched with downloads
- [x] Transcript speech sync (experimental) — English + iOS 26 only, on-device SpeechTranscriber; Hindi stays on estimate + anchors
- [x] Home > Continue Listening: series name is a link to the series page (Downloads-header style)

## What's remaining (post-MVP)

- [ ] Favourites — heart toggle on discourses
- [ ] Skip silence / condense pauses
- [ ] Share bookmarks (readable-text export via ShareLink)
- [ ] Osho portrait refinements as player artwork
- [ ] Download size preview before downloading (HEAD request or static estimate)
- [ ] Widget (home screen widget showing current/last played)
- [ ] App Store submission (icon, screenshots, description)

## Key decisions

- **Transcripts have no timestamps, so sync is an estimate the listener can correct** — oshoworld publishes plain paragraphs. The highlight assumes speech moves through the text at a constant rate and lets "Audio is here" pin a paragraph to the current time; the map is linear between pins. Measured against speech alignment on A Bird on the Wing #1, the raw estimate drifts up to ~45 s mid-talk (the opening question is read slowly), which one or two anchors remove.
- **Hindi cannot be speech-aligned on device** — `SpeechTranscriber` (iOS 26) ships no Hindi model and `SFSpeechRecognizer` `hi-IN` is server-only in one-minute requests. English alignment runs on device (a 98-min talk recognised in ~40 s on an M-series Mac, 89 of 93 paragraphs matched) and is gated behind an experimental toggle; the alternative for Hindi would be vendoring whisper.cpp or shipping pre-aligned timestamps as data.
- **`AssetInventory.reserve(locale:)` before any asset call** — without a reservation `assetInstallationRequest` fails with "not subscribed to transcription.en". The simulator reports no supported speech locales at all; test alignment on a device or via the macOS harness.
- **Transcript matching is by mp3 path, never by folder alone** — every Hindi series shares one upload folder, so folder+index is only trusted when the folder holds a single series. All 5,481 discourses map to a page; 535 pages are blank and are left out of the catalog.
- **Static catalog, not fetched** — 5,481 discourses hardcoded. Updates via app releases. No server needed.
- **The pattern URLs are a fallback; the crawled paths are the truth** — 717 of the original 4,361 discourses had oshoworld URLs that 404 (the site renamed files in 57 folders); the archive mirror hid most of it, but 74 were undownloadable. Storing only the differing paths keeps the JSON at ~110 KB while the scripts stay the single place that knows the site.
- **Almost no third-party deps** — everything from Apple frameworks except the vendored RNNoise C sources and the DeepFilterNet Rust/tract bridge, both linked statically with no package manager. Adding DeepFilterNet was a deliberate trade: it is the only option that removes steady tape hiss and noise overlapping speech.
- **The catalog is 22.05 kHz, not 48 kHz** — the Hindi talks are 22,050 Hz 43 kbps MP3s (the archive.org mirror is byte-identical). Both neural denoisers are 48 kHz models, so without `PolyphaseResampler` DeepFilterNet was bypassed entirely and RNNoise ran on mis-mapped bands. This was the real reason noise reduction "did nothing".
- **The denoise gate is slow to close, never fast** — Osho's sentences decay in level, so the model's local SNR collapses on his final words. A conventional fast-closing gate (the first attempt used 10 ms) mutes the end of every sentence. The gate now opens in 8 ms, holds ~220 ms after speech, then closes over 400 ms; levelling tracks running speech level rather than per-frame level, which otherwise boosts quiet noise in the gaps harder than the voice.
- **Noise that overlaps speech is attacked in time, not frequency** — an aircraft at 40:20 of Maha Geeta #5 occupies the same 150-700 Hz as the voice, with only ~0.5% of energy above 3 kHz. So Voice Focus raises speech-to-pause contrast using the model's own local SNR instead of EQ. Downward compression was measured and rejected (it lifts pauses too); DSP without the model was worse than doing nothing.
- **A volume boost spends crest factor, it does not multiply loudness** — the archive averages -13.8 dBFS against 0 dBFS peaks, so plain gain only clips. The boost applies gain inside the tap followed by a peak limiter, which converts the ~14 dB of crest into real level: measured +1.9/+3.1/+4.1/+4.6 dB for 1.5x/2x/3x/4x on a 12.9 dB-crest signal, never exceeding -0.3 dBFS. Going louder than that needs compression, which would flatten Osho's dynamics.
- **The chain must never add level** — this archive is already mastered into full scale (Maha Geeta #5 peaks at 0 dBFS), so the emphasis bell's +3.5 dB and up to 9 dB of speech lift simply clipped: measured +3.3 dBFS with Focus and +10.1 dBFS with Lift. The bell is now normalised to unity peak (a cut elsewhere, not a boost), the lift is capped by the frame's own peak, and a safety limiter catches the rest. Fixing the causes mattered: a limiter alone engaged on 44% of samples, which is a compressor, not a safety net.
- **`reset()` must not re-init the model** — `dfb_reset` forwards to upstream's `DfTract::init()`, which never clears `rolling_spec_buf_x`, so every track change, seek or settings toggle added 5 hops of latency. It grew 103 → 153 → 203 → 253 → 303 ms and after ~8 resets the output FIFO overflowed and DeepFilterNet fell back to passthrough for the rest of the session. Stale spectra are now displaced with silence instead; latency is constant at 53 ms.
- **DeepFilterNet runs on a mono mix, not per channel** — the downloads are joint stereo whose channels differ by only -18.4 dB, so per-channel inference cost twice as much to reproduce nearly the same signal, and two independent gates made the stereo image wander.
- **Pre-rendering after download was built and removed** — it worked, but settings baked into each file (killing instant A/B), an ~85 minute discourse took ~20 minutes to render, and every copy doubled that discourse's storage. See `docs/noise-reduction-lab.md`.
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
- Build succeeds as of 2026-09-06 (227 tests passing; Release verified for device arm64 and simulator)
- Debug launch arguments (DEBUG builds only): `-debugTranscript <discourseID>` plays an already-downloaded discourse and opens its transcript; add `-debugPlayer` to open the full player instead, `-debugDownload <discourseID>` to run a real download and log the source/bytes, `-debugTranscriptSearch <query>` to open search, `-debugTranscriptSelect <n>` to show a paragraph's action bar. `-settings.transcriptSpeechSync 1` pre-enables speech sync (UserDefaults argument domain). `-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityL` checks large text.
- Small screens: verified on an iPhone SE (3rd gen) simulator (create one with `xcrun simctl create`; none ships by default). The transcript search and transport bars cap Dynamic Type at xxxLarge so they stay on one line at 375 pt; body text uses the in-reader size control instead.
- Transcript reader keeps the screen awake (`isIdleTimerDisabled`) only while its discourse is playing and the app is active.
- Seed a simulator download for testing: copy an mp3 to `Documents/Osho Discourses/<Series>/<Series> - #N.mp3` and write `{"<discourseID>": "<relative path>"}` to `Library/Application Support/.download_manifest.json`.
- Dynamic Island / Live Activity was removed (was a Live Activity hosted by a now-deleted widget extension); standard lock-screen/Control-Center controls stay via MediaPlayer
