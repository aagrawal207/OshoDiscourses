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
- ActivityKit (Dynamic Island + Live Activities)
- No external dependencies — all Apple frameworks
- No SwiftData — catalog is static structs, settings use UserDefaults, downloads tracked by filesystem

## Architecture

```
OshoDiscourses/
├── App/OshoDiscoursesApp.swift         # @main entry, environment injection
├── Views/
│   ├── ContentView.swift               # TabView: Browse, Downloads, Bookmarks, Settings
│   ├── Home/HomeView.swift             # Browse screen — search, curated sections, all series list
│   ├── Series/SeriesDetailView.swift   # Hero header, discourse list, download/play actions
│   ├── Player/PlayerView.swift         # Full-screen player — artwork, slider, controls, speed
│   ├── Player/MiniPlayerView.swift     # Floating mini-player bar (ultraThinMaterial)
│   ├── Downloads/DownloadsView.swift   # Grouped by series, smart download/delete toggles
│   ├── BookmarksView.swift             # Placeholder (post-MVP)
│   └── Settings/SettingsView.swift     # All preferences (appearance, language, sections, downloads)
├── Services/
│   ├── AudioPlayerService.swift        # AVPlayer + Live Activity + lock screen controls
│   ├── DownloadService.swift           # URLSession download task with progress (filesystem-tracked)
│   ├── PlaybackStateService.swift      # Auto-saves position per discourse every 10s
│   └── UserSettings.swift              # @Observable singleton over UserDefaults
├── Resources/
│   ├── Catalog.swift                   # 261 series, 4,361 discourses — static data + URL builder
│   └── Assets.xcassets/                # App icon placeholder
Shared/
├── PlaybackAttributes.swift            # ActivityAttributes for Live Activity (shared with widget)
└── PlaybackIntents.swift               # LiveActivityIntent for Dynamic Island buttons
OshoDiscoursesWidgets/
├── WidgetBundle.swift                  # @main widget bundle entry
└── PlaybackLiveActivityWidget.swift    # Dynamic Island + lock screen Live Activity UI
OshoDiscoursesTests/
└── OshoDiscoursesTests.swift           # Catalog + URL builder tests
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

### SwiftData models
- **Series** / **Discourse** — track download state, local paths, playback position
- **AppSettings** — persisted preferences

## What's built (MVP)

- [x] Browse 261 series with search + language filters
- [x] Curated sections (Popular/Beginner for English and Hindi)
- [x] Series detail with hero header and discourse list
- [x] Download with progress tracking (URLSession async bytes)
- [x] Audio playback (AVPlayer with queue management)
- [x] Background audio + lock screen controls (MPRemoteCommandCenter)
- [x] Seek slider, playback speed (0.5x–2x), volume boost
- [x] Mini-player bar (ultraThinMaterial glass)
- [x] Full player screen (Apple Music style)
- [x] Downloads screen grouped by series
- [x] Smart Download (auto-download next 10 min before end)
- [x] Smart Delete (remove after finishing)
- [x] Settings (appearance, language hiding, section visibility, download prefs)
- [x] Playback position persistence (auto-save every 10s)
- [x] Series thumbnails (gradient hash + initials)
- [x] Dynamic Island + Live Activity (track info, play/pause/skip controls)
- [x] Light/Dark/System appearance switching

## What's remaining (post-MVP)

- [ ] Bookmarks — time range bookmarks with notes (model exists, UI is placeholder)
- [ ] Favourites — heart toggle on discourses
- [ ] Recently Played section on Browse
- [ ] Sleep timer
- [ ] Skip silence / condense pauses
- [ ] Share bookmarks (text + audio clip export)
- [ ] CloudKit sync (SwiftData supports it, just needs entitlement)
- [ ] Osho portrait bundled as player artwork
- [x] Light mode (all views use semantic colors, adapts to color scheme)
- [ ] Download size preview (HEAD request or static estimate)
- [ ] Noise reduction (vDSP spectral subtraction — code exists in the RN version's iOS native module)
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

Features that existed in RN version and should be ported:
- Bookmarks with time ranges, notes, search, share
- Favourites with heart toggle
- Voice boost (1.5x volume via audio mix)
- Skip silence (rate increase during pauses)
- Sleep timer (15/30/45/60/90 min)
- Smart download/delete (both implemented here)
- Filter chips (All/Hindi/English/Downloaded/Favourited)
- Recently played tracking
- Download size estimates (~30MB English, ~20MB Hindi)

## Dev notes

- xcodegen required: `brew install xcodegen`
- Files auto-discovered — just drop .swift files in the right directory, run `xcodegen generate`
- Simulator: iPhone 17 Pro (iOS 26.5) — UUID 8FAAABA5-25F8-4678-A8F1-B1D6B1104FB0
- Build succeeds as of 2026-05-28
