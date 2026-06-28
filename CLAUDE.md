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
- No external dependencies — all Apple frameworks
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
│   ├── DownloadService.swift           # URLSession download task with progress (filesystem-tracked); excludes downloads from iCloud backup
│   ├── PlaybackStateService.swift      # Auto-saves position per discourse every 10s; owns cloud merge logic
│   ├── CloudSyncService.swift          # Silent NSUbiquitousKeyValueStore sync of progress + bookmarks + daily stats
│   ├── SleepTimerService.swift         # Countdown + end-of-discourse sleep modes
│   ├── BookmarkService.swift           # Bookmarks persisted to bookmarks.json; union-by-id cloud merge
│   ├── ListeningStatsService.swift     # Daily listening totals + streak (listening_stats.json); max-per-day cloud merge
│   ├── NoiseReductionProcessor.swift   # RNNoise wrapper (MTAudioProcessingTap, wet/dry mix)
│   └── UserSettings.swift              # @Observable singleton over UserDefaults
├── RNNoise/                            # Vendored RNNoise C sources + bridging header
├── Resources/
│   ├── Catalog.swift                   # 261 series, 4,361 discourses — static data + URL builder
│   └── Assets.xcassets/                # App icon placeholder
OshoDiscoursesTests/
├── OshoDiscoursesTests.swift           # Catalog + URL builder tests
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
- [x] Download with progress tracking (URLSession async bytes)
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
- **No third-party deps** — everything from Apple frameworks. Simpler, faster, no CocoaPods/SPM issues.
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
- Build succeeds as of 2026-06-27 (65 tests passing)
- Dynamic Island / Live Activity was removed (was a Live Activity hosted by a now-deleted widget extension); standard lock-screen/Control-Center controls stay via MediaPlayer
