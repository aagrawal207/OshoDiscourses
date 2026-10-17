# Osho Talks for Android

A native Android port of the iOS app in this repository. The Swift sources in
`../OshoDiscourses/` are the source of truth for behaviour, copy and layout.
The plan and task ledger are in [`docs/PLAN.md`](docs/PLAN.md); the visual spec
is [`docs/spec/ui-style.md`](docs/spec/ui-style.md).

## Requirements

- JDK 21 (Gradle runs on it; every module compiles for Java 21).
- Android SDK with `platforms;android-37.0` and build-tools 36+. Current AndroidX,
  Compose 1.12 and Haze 2 need compileSdk 37; `targetSdk` stays 36, `minSdk` 26.
- `local.properties` with `sdk.dir=...` (gitignored), or `ANDROID_HOME` set.

## Build and test

Run everything from this directory.

```sh
./gradlew assembleDebug            # debug APK in app/build/outputs/apk/debug
./gradlew testDebugUnitTest        # every unit test: JVM, Robolectric and screenshot tests
./gradlew :feature:home:testDebugUnitTest   # one Android module
./gradlew :core:model:test         # one JVM module (testDebugUnitTest also works)
```

### Screenshot tests (Roborazzi)

Screenshot tests run on the JVM with Robolectric native graphics. Reference images
live in each module's `src/test/screenshots/` and are committed.

```sh
./gradlew :feature:home:recordRoborazziDebug   # record or update references
./gradlew :feature:home:verifyRoborazziDebug   # fail on a pixel difference
./gradlew :feature:home:compareRoborazziDebug  # write *_compare.png diffs
```

Record on macOS. CI runs the tests without comparing pixels, because rendering
differs slightly between operating systems.

Write a test with `@RunWith(AndroidJUnit4::class)`, `@GraphicsMode(NATIVE)` and
`@Config(sdk = [36], qualifiers = "w393dp-h852dp-xxhdpi")` (iPhone 17 Pro size).
Wrap content in `OshoTheme` and provide `LocalAppServices` with
`FakeAppServices.preview()`. See `feature/home/src/test` for an example.

## Modules

| Module | Kind | Contents |
| --- | --- | --- |
| `:app` | application | `OshoApplication`, `AppContainer`, `MainActivity`, tab shell and navigation |
| `:core:model` | JVM | Catalog types, `CatalogRepository`, settings value types, `PlaybackSpeed`. Reads the shipped iOS catalogs from `../OshoDiscourses/Resources/*.json` on the classpath |
| `:core:domain` | JVM | Service contracts (`StateFlow` state, `suspend` actions) and `AppServices` |
| `:core:data` | Android library | Settings, progress, bookmarks, stats and transcript-state repositories |
| `:core:ui` | Android + Compose | Theme, accents, typography, glass, tab bar, thumbnails, chips, clearances |
| `:core:testing` | JVM | In-memory fakes for every contract, plus a sample catalog |
| `:playback`, `:downloads`, `:denoise`, `:transcript`, `:sync`, `:billing` | Android library | Implementations of the contracts |
| `:feature:*` | Android + Compose | Screens; each exposes entry composables and `NavKey` routes |

Packages follow the Gradle path: `:feature:home` is
`com.agraabhi.oshodiscourses.feature.home`.

## Module rules

- Feature modules depend only on `:core:*`. Only `:app` depends on the
  implementation modules, and `AppContainer` wires them behind the contracts.
- Implementation modules depend on `:core:domain`, never on each other or on features.
- Do not copy the iOS catalogs. `:core:model` reads them through its source set.
- Screens read services from `LocalAppServices` and reserve
  `bottomClearance` (tab bar + mini-player) at the end of every scrolling page,
  via `tabContentPadding()` or `BottomClearanceSpacer()`. Sheets provide zero.
- Sheets and popovers wrap their content in `ProvideElevatedSurfaces`.
- Convention plugins in `build-logic` own SDK levels, Compose, Robolectric and
  Roborazzi setup: `osho.android.application`, `osho.android.library`,
  `osho.android.library.compose`, `osho.android.screenshot`,
  `osho.android.feature`, `osho.jvm.library`. Versions live only in
  `gradle/libs.versions.toml`.
