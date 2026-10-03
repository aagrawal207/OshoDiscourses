# iPad and Mac

## Mac platform

Osho Talks runs on the Mac as a Mac Catalyst build of the iOS app target, using the
same bundle ID (`com.agraabhi.oshodiscourses`) for universal purchase, iCloud
key-value sync and the tip products. The Mac uses the "Optimize for Mac" idiom
(`TARGETED_DEVICE_FAMILY` 1,2,6) and requires macOS 15 (Mac Catalyst 18).

### Build settings

- `SUPPORTS_MACCATALYST`, `DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER: NO` and
  `MACOSX_DEPLOYMENT_TARGET: 15.0` on the app target. The unit-test target also sets
  `MACOSX_DEPLOYMENT_TARGET`, otherwise it targets the SDK's macOS and cannot load.
- CarPlay, WatchConnectivity and the embedded Watch app use `platformFilter: iOS`.
  XcodeGen only accepts the capitalised value; `ios` is silently ignored and the Mac
  build then fails while embedding the watchOS app.
- CarPlay and Watch sources compile out with
  `#if canImport(...) && !targetEnvironment(macCatalyst)`.
- `CFBundleName` is "Osho Talks" because the Mac menu bar, About and Quit items use
  it instead of the display name.
- `Signing/MacCatalyst.entitlements` (selected by `CODE_SIGN_ENTITLEMENTS[sdk=macosx*]`)
  enables App Sandbox, outgoing network connections, user-selected read-only files
  and the iCloud key-value store.

### DeepFilterNet bridge

`Vendor/DeepFilterBridge.xcframework` contains `ios-arm64`,
`ios-arm64_x86_64-simulator` and `ios-arm64_x86_64-maccatalyst`. The Catalyst
library is built by `native/deepfilter-bridge/build-xcframework.sh` from
`aarch64-apple-ios-macabi` and `x86_64-apple-ios-macabi`, with the same locked crates.
Its objects report `platform MACCATALYST, minos 18.0` (`vtool -show-build`). The
iOS libraries are byte-identical to the ones committed before the Catalyst slice
was added, so iOS behaviour is unchanged.

### Platform behaviour

- Downloads use the same background `URLSession`. On the Mac, `nsurlsessiond`
  continues a transfer after the app quits but does not relaunch the app. The
  finished file is delivered when the app next starts and is committed then.
  Only a listener's own cancel or delete in the same run discards an unclaimed file.
- Files live in the sandbox container:
  `~/Library/Containers/com.agraabhi.oshodiscourses/Data/Documents/Osho Discourses/`.
  The backup exclusion also keeps them out of Time Machine, which is acceptable for
  re-downloadable audio.
- `MPRemoteCommandCenter` and Now Playing work under Catalyst: the app registers as
  a Now Playing player, and system play/pause commands reach its handlers.
- DeepFilterNet loads its bundled model and processes audio in real time on Apple
  silicon.
- Without the key-value store entitlement, such as in an ad-hoc local build,
  `NSUbiquitousKeyValueStore` logs a client fault and sync does nothing. Playback
  and local state are unaffected.
- On-device speech alignment uses the iOS 26 availability checks, which match Mac
  Catalyst 26 (macOS 26). Earlier Macs use shipped timing only.
- `MacWindowConfigurator.install()`, called from `OshoDiscoursesApp.init`, sets a
  900 × 600 minimum window size on every app window scene. It is a no-op on iPhone
  and iPad.

### Local runs and tests

`Tools/MacCatalyst/run-local.sh` builds with ad-hoc signing and
`Tools/MacCatalyst/LocalRun.entitlements`, which omits the key-value store
entitlement. The script uses the bundle ID
`com.agraabhi.oshodiscourses.catalyst-local`, because an App Store copy on the same
Mac owns the real container. A new signer opening that container triggers a
data-access prompt and blocks launch inside sandbox setup.

```bash
Tools/MacCatalyst/run-local.sh launch [app arguments]   # Debug build, then open
Tools/MacCatalyst/run-local.sh test                     # unit tests on My Mac
```

Tests use `...catalyst-local.tests`: some suites create a real `DownloadService`
and delete every download in the host's container.

### App Store distribution

Remaining steps before a Mac build can ship:

1. In App Store Connect, add the macOS platform to the existing app record.
   Mac Catalyst builds with the same bundle ID join the iOS record.
2. Create a Mac Catalyst App Store provisioning profile (and a development profile
   with this Mac registered for signed local runs) for `com.agraabhi.oshodiscourses`
   with iCloud key-value storage. Archive needs a Mac App Distribution or Apple
   Distribution certificate and a Mac Installer Distribution certificate for the
   `.pkg` upload.
3. Archive with `-destination 'generic/platform=macOS,variant=Mac Catalyst'`,
   export for App Store Connect, upload, and attach the build to a macOS version.
4. Provide Mac screenshots, review notes describing the sandbox entitlements, and
   complete App Privacy for macOS if anything differs.
5. Exercise a TestFlight sandbox tip purchase on the Mac.

## Interface

Regular width means a horizontally regular size class on iPad or Mac
(`AppLayout.isRegular`). Large iPhones in landscape also report regular width but keep
the phone layout.

### Navigation

- `ContentView` uses the iOS 18 `Tab` API with `.tabViewStyle(.sidebarAdaptable)`.
  iPhone keeps its bottom tab bar with Home, Library, Downloads and Settings. A window
  that opens wider than it is tall starts with the sidebar. A portrait window starts
  with the top tab bar, so the sidebar does not cover the page on launch.
- The sidebar adds a "Your Listening" section with Bookmarks. The tab is included
  only in regular width, because `defaultVisibility(.hidden, for: .tabBar)` still
  showed it in the phone tab bar.
- `AppNavigation` (`Views/AppNavigation.swift`) is per window. It holds the selected
  tab, player presentation, transcript and bookmark requests and the series to open.
  Each scene's `ContentView` owns one in `@State`, so two iPad or Mac windows browse
  independently. Playback stays process wide in `AppRuntime`. Opening the series from
  the player goes through the window's `AppNavigation` instead of the old global
  `navigateToSeries` notification, so other windows do not navigate.

### Mini player

- iOS 26.1 and later: regular width hosts the mini player in
  `tabViewBottomAccessory(isEnabled:)`. The system insets content for it and keeps it
  beside the sidebar. `MiniPlayerView(style: .accessory)` shows the cover, titles,
  play/pause and skip 30 seconds, with a hairline of progress.
- iOS 18 to 26.0 (not verified, no runtime installed): regular width floats the
  capsule at the bottom, centred in a 560-point column.
- iPhone keeps the floating capsule. Its bottom offset is measured from the tab
  content's bottom inset minus the root inset, so it sits above the iOS 26 tab bar.
  The earlier fixed 56-point offset overlapped the tab bar on iPhone SE.
- The mini player reports `Playing`/`Paused` as its accessibility value.

### Player

- iPhone keeps the swipe-down sheet. Regular width presents `PlayerView` with
  `fullScreenCover` and adds a close (chevron) button in the top row.
- `PlayerView.arrangement(for:isRegular:showsTranscript:largeText:)` picks the layout:
  - side by side: width of at least 900 points in landscape. The controls column is
    40% of the width, clamped to 380 to 500 points. The transcript fills the rest.
  - stacked: a portrait window at least 900 points tall. Controls take 540 to
    620 points with a 260-point cover, and the transcript is below. Accessibility text
    sizes skip this layout, because the fixed band would need its own scrolling.
  - single column: everything else, capped at 560 points in regular width.
- The transcript pane is `TranscriptView(discourseID:presentation: .embedded)`. It
  has no navigation bar, close button or transport, and has its own header with search
  and options. Sheet presentation is unchanged. Reader text is capped at a 720-point
  measure in both presentations.
- The Transcript control and the cover hide and show the pane in the wide layouts.
  The choice persists as `player.transcriptPaneVisible`. Where the pane does not fit,
  they open the transcript sheet.
- DeNoise opens with `.presentationSizing(.page)`, because the default iPad form sheet
  cut the page off at the boost row.

### Content density

- Home and Library use `SeriesTileView` in `LazyVGrid(.adaptive(minimum:))` with a
  260-point minimum (`@ScaledMetric`, so large text gets fewer, wider tiles), in a
  column capped at 1100 points. Home shelves become grids because a pointer has no
  natural horizontal scroll. Continue Listening and Recently Completed sit side by
  side.
- The series page puts a 176-point cover beside the details and caps the header and
  list at 820 points.
- Downloads, Settings and Bookmarks centre their inset-grouped lists in a readable
  column (720, 680 and 720 points) with `safeAreaPadding`. Content margins resolved
  against the sidebar inset unpredictably.
- Cards and rows have `.hoverEffect(.highlight)`. Discourse rows on the series page
  and in Downloads have context menus for Play or Pause, Download or Remove Download,
  and Add Bookmark for the playing discourse.
- Plain-style row buttons have a rectangular content shape. On wide iPad rows, the
  space between label and checkmark otherwise ignored taps, as in DeNoise's Listening
  Mode list.

### Keyboard and menus

`App/AppCommands.swift` builds the menu bar on Mac and the iPad keyboard menu. Commands
cannot read a view's environment. They act on the key window through
`@FocusedValue(\.appNavigation)` and on playback through `AppRuntime.shared.audioPlayer`.
Enablement and labels come from a `CommandState` value published by `ContentView`
with `focusedSceneValue`, because command bodies do not observe `@Observable` models.

| Menu | Item | Shortcut |
| --- | --- | --- |
| App | Settings… (replaces `.appSettings`) | ⌘, |
| View | Home, Library, Downloads, Settings, Bookmarks | ⌘1 to ⌘5 |
| Playback | Play/Pause | Space |
| Playback | Skip Forward 30 Seconds / Skip Back 15 Seconds | ⌘→ / ⌘← |
| Playback | Next Discourse / Previous Discourse | ⌘⇧→ / ⌘⇧← |
| Playback | Speed and Sleep Timer submenus | |
| Playback | Add Bookmark… | ⌘B |
| Playback | Show Transcript | ⌘T |
| Playback | Show Player | ⌘⇧P |
| Playback | Close Player | Escape or ⌘. (handled by the player) |

- Space is a plain key, as in Music and Podcasts. UIKit offers it to a focused text
  field first. The UI test types "tao te" into Library search during playback, and
  playback is unaffected.
- The text-formatting group is removed, so ⌘B and ⌘T are not claimed by Bold and
  Show Fonts. The File menu's document items (Duplicate, Rename, Move, Export) are
  removed, and Help opens the support page instead of an empty help book.
- The full-window player never holds first responder, so neither a button shortcut nor
  a menu key equivalent for Escape reaches it. `EscapeKeyHandler` is a zero-size
  first-responder view in the player that handles Escape and ⌘.. The simulator does
  not deliver a synthesised Escape to the app, so the UI test drives ⌘..
- View items sit in one inline `Section`. Loose items inserted before `.sidebar`
  appeared in reverse order on Mac.

### Verification

`OshoDiscoursesUITests/AdaptiveLayoutTests.swift` covers:

- sidebar navigation, and the mini player clear of the sidebar, in iPad landscape;
- the side-by-side transcript pane and its toggle;
- the stacked portrait player;
- Space, ⌘⇧P, ⌘., ⌘2 and ⌘, shortcuts, including Space typed into search;
- accessibility XL in dark mode;
- the phone tab bar with no Bookmarks tab, the mini player above it and the sheet
  player.

`testPopulatedHomeDownloadsAndSeriesInLandscape` records populated Home and Downloads
and a Downloads context menu. It skips unless downloads are seeded into the simulator
(see "Seed a simulator download" in CLAUDE.md). `-debugPlaySample <discourseID>`
(DEBUG) plays two minutes of generated silence under that discourse's metadata. UI
tests pass `-settings.smartDownload 0 -settings.smartDelete 0`, so the sample ending
neither fetches nor deletes real files. `-debugMiniPlayer 1` with
`-debugPlayerDiscourse` leaves the player closed, and `-debugTab <tab>` selects a tab.
`openDestination(_:)` in `UITestNavigation.swift` opens a destination from the phone
tab bar, the iPad top tab bar or the sidebar.

Checked on the Mac on 2026-10-02 with the app in front (local Debug build, generated
sample playing):

- Space typed into Library search inserts spaces and leaves playback running.
  Outside a text field Space pauses and resumes.
- The Playback menu reads Pause while playing and Play while paused. It follows the
  key window's `CommandState`, so it can lag a toggle by about 2 s, and an inactive
  app reads as nothing loaded.
- A resize to 500 × 400 stops at 900 × 600.
- Closing the last window keeps audio playing (the "CoreMedia Playback" assertion
  stays held); opening the app again shows a new window with playback still on.
- The process also owns a fully transparent, offscreen 500 × 500 window. It is not
  visible and did not affect these checks; its source is not yet identified.

Not yet checked: Escape with a real keyboard, the window tab bar items Catalyst adds
to View, a second window, and hover highlights.
