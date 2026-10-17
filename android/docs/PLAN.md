# Osho Talks for Android: plan and task ledger

A native Android port of the iOS app in this repository. The iOS code under
`OshoDiscourses/` is the source of truth for behaviour, copy, numbers and
layout. Read the root `CLAUDE.md` for the iOS architecture and key decisions.

## Scope

1. **Phone app (v1, this milestone).** Every iPhone feature except the ones
   listed under Later.
2. **Later milestones.** Tablet layouts, Android Auto, Wear OS, Chromecast,
   on-device speech alignment fallback.

## Parity rules

- Same features, flows, copy, numeric defaults and visual design as the
  iPhone app. Copy strings verbatim from the Swift views.
- Follow Android rules where the platform owns the behaviour: system back
  gesture, media notification and lock-screen controls, permissions, edge to
  edge, Material components styled to match the iOS look.
- iOS "Apple Music dark UI": true black background in dark mode, white text,
  translucent bars, eight accent colours. Map SF Symbols to Material Symbols.
- iCloud sync becomes Google Drive's hidden app-data folder with the same
  snapshot shape and the same convergent merge rules. No developer server,
  no analytics, no ads.
- StoreKit tips and yearly support become Google Play Billing products with
  the same names and prices.

## Decisions

- Shared visual reference: `android/docs/spec/ui-style.md`. Use it with the
  Swift views.
- Apple service names get Android wording: iCloud becomes Google Drive, App
  Store becomes Google Play, Apple Account becomes Google account.
- Settings > About > My Other Apps is hidden. Those apps have no Android
  versions.
- Keep the iOS hardcoded system blue where the iOS app uses it (playing-row
  titles, Add Bookmark), for parity.
- Glass blur uses the Haze library where the platform supports it, with the
  tinted fallback from the style guide.

## Stack

| Concern | Choice |
| --- | --- |
| Language/UI | Kotlin, Jetpack Compose, Material 3 |
| SDK levels | `minSdk 26`, `compileSdk 37` (current AndroidX needs it), `targetSdk 36` |
| Playback | Media3 ExoPlayer + `MediaSessionService` (later `MediaLibraryService` for Auto) |
| DSP | Media3 `AudioProcessor` calling JNI: RNNoise C sources (CMake) and the DeepFilterNet Rust bridge (`cargo-ndk`, prebuilt `.so` committed like the iOS xcframework) |
| Downloads | WorkManager (expedited/foreground) + OkHttp |
| Persistence | JSON files via kotlinx.serialization (same file names as iOS) + DataStore Preferences for settings |
| Images | Coil 3 |
| Sync | Google Drive REST v3 `appDataFolder`, Identity `AuthorizationClient` |
| Purchases | Play Billing Library; Play In-App Review |
| DI | Manual `AppContainer` in `:app` (mirrors iOS `AppRuntime`) |
| Async | Coroutines + `StateFlow` |
| Tests | JUnit + kotlin.test/Truth + Turbine; Robolectric + Roborazzi screenshot tests for UI; instrumented and Maestro tests on the emulator (coordinator only) |

## Module map

Package root: `com.agraabhi.oshodiscourses`. Application ID matches iOS:
`com.agraabhi.oshodiscourses`. App name: Osho Talks.

| Module | Path | Contents |
| --- | --- | --- |
| `:app` | `android/app` | `MainActivity`, `OshoApplication`, `AppContainer`, navigation graph, tab shell, wiring |
| `:core:model` | `android/core/model` | Pure Kotlin (JVM). Catalog models, catalog loading, URL builder, `PlaybackSpeed`, value types |
| `:core:domain` | `android/core/domain` | Pure Kotlin (JVM). Service contracts (interfaces + state types) shared by all modules |
| `:core:data` | `android/core/data` | Repositories: settings, playback state, bookmarks, listening stats, transcript state; merge rules |
| `:core:ui` | `android/core/ui` | Theme, accent colours, typography, shared components, mini-player clearance |
| `:core:testing` | `android/core/testing` | In-memory fakes of every `:core:domain` contract |
| `:playback` | `android/playback` | Media3 service, `PlayerController` impl, sleep timer, position auto-save |
| `:downloads` | `android/downloads` | Download engine, source policy, manifest, storage, smart download/delete |
| `:denoise` | `android/denoise` | JNI bridge, RNNoise, DeepFilterNet, Voice Focus, boost, limiter, resampler, `AudioProcessor` |
| `:transcript` | `android/transcript` | Fetcher, parser, sync model, aligner, cache (no UI) |
| `:sync` | `android/sync` | Drive app-data snapshot push/pull |
| `:billing` | `android/billing` | Tips, yearly support, review prompt, engagement prompts |
| `:feature:home` | `android/feature/home` | Home screen |
| `:feature:library` | `android/feature/library` | Library screen |
| `:feature:series` | `android/feature/series` | Series detail |
| `:feature:player` | `android/feature/player` | Full player, mini-player, speed, sleep timer, bookmark add, DeNoise screen |
| `:feature:transcript` | `android/feature/transcript` | Transcript reader |
| `:feature:downloads` | `android/feature/downloads` | Downloads, bookmarks list, listening stats |
| `:feature:settings` | `android/feature/settings` | Settings, appearance, about, support sheet |

Feature modules depend only on `:core:*`. Only `:app` depends on
implementation modules, with one exception: `:playback` depends on `:denoise`
for its Media3 `AudioProcessor`. Billing, review and Drive authorization take
an activity provider (`() -> Activity?`) that `:app` supplies. Shared catalog JSON is read from
`OshoDiscourses/Resources/` through Gradle source sets, never copied.

## Working rules for workers

- Work only in the git worktree and files your brief names. Never commit,
  push, or switch branches. The coordinator integrates.
- Do not edit `settings.gradle.kts`, `gradle/libs.versions.toml`, root build
  files or another module. Ask for a change in your handoff instead.
- Do not start emulators or run instrumented tests. Run JVM unit tests and
  Robolectric/Roborazzi tests for your module:
  `cd android && ./gradlew :<module>:testDebugUnitTest` (or `:test` for JVM modules).
- Port the matching iOS unit tests in `OshoDiscoursesTests/` for your area.
- Comments explain why, at most two lines, no change narration.
- Handoff: changed files, contract changes, checks run with results,
  blockers, and anything the coordinator must wire.

## Git and GitHub

- Integration branch: `android`. Coordinator worktree:
  `~/projects/OshoDiscourses-Android`.
- Task branches `android-<task>` in worktrees under
  `~/projects/OshoDiscourses-Android-wt/<task>`, merged by pull request into
  `android`. Every task has a GitHub issue with label `android` in milestone
  "Android phone v1".

## Task ledger

| ID | Task | Depends on | Status | Branch | Worker session |
| --- | --- | --- | --- | --- | --- |
| A1 | Foundation: Gradle project, all modules, contracts, fakes, theme, tab shell, CI | - | done | `android` | `ses_eb7f71242ffeKuRXnTQtm3h4nJ` |
| A2 | Catalog data, URL builder, download source policy | A1 | done | `android-catalog` | `ses_eb7862a5bffecxK6KSQCCk9B6f` |
| A3 | Persistence repositories and merge rules | A1 | done | `android-data` | `ses_eb785fd26ffeydj7GqHHKLIL79` |
| A4 | Playback engine and sleep timer | A1 | done | `android-playback` | `ses_eb785c4e6ffeZqgYfIOYrjiXtH` |
| A5 | Downloads engine | A1 | done | `android-downloads` | `ses_eb785916cffegG7kYnblM2BUZk` |
| A6 | DeNoise DSP and native bridges | A1 | done | `android-denoise` | `ses_eb78558e3ffe8eQZjlQ7T4kSYL` |
| A7 | Transcript data | A1 | done | `android-transcript-data` | `ses_eb7852ee0ffeRPENK2ORSS8csv` |
| A8 | Home, Library, Series screens | A1 | done | `android-browse-ui` | `ses_eb784fc41ffeA2D3ODBMeaKWCn` |
| A9 | Player, mini-player, DeNoise screen | A1 | in progress | `android-player-ui` | `ses_eb784cd1cffeePupQHBsMqbTho` |
| A10 | Transcript reader UI | A1 | done | `android-transcript-ui` | `ses_eb784a019ffetrjlyth3xd08Ws` |
| A11 | Downloads, Bookmarks, Stats, Settings screens | A1 | in progress | `android-library-settings-ui` | `ses_eb78470b3ffeWiO51Bhx0s6orz` |
| A12 | Billing, review and engagement | A1 | done | `android-billing` | `ses_eb7844d1affeoINsLcrNaq7ah6` |
| A13 | Google Drive sync | A1, A3 | done | `android-sync` | `ses_eb7841d5fffePuPbTFWkzbT7Cm` |
| A14 | Integration, emulator E2E, screenshot parity, polish | all | in progress | `android-integration` | `ses_eb75e9441ffem9kpidg5uoEjsX` |
