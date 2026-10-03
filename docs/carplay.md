# CarPlay

Osho Talks has a native CarPlay audio interface for discourses already downloaded on
the iPhone. It uses CarPlay's list templates and the system's shared Now Playing
screen. Nothing streams, and nothing downloads from the car.

**Status:** implemented and covered by unit tests on the iOS 26.5 simulator. Both the
`OshoDiscourses` and `OshoDiscoursesCarPlay` schemes build. Apple has not yet approved
the CarPlay audio entitlement for this App ID, and no head unit or CarPlay simulator
display has been tested. See [Device acceptance](#device-acceptance).

## Behavior

| Surface | Contents | Selecting a row |
| --- | --- | --- |
| Continue Listening tab | `CompanionLibrary.continueListening`: downloaded, started or loaded discourses | `PlaybackLauncher.playDiscourse`, then Now Playing |
| Downloads tab | Series that have downloads, with a discourse count | Opens that series' downloaded discourses |
| Series list | `CompanionLibrary.downloadedDiscourses(seriesID:)` in catalog order | `playDiscourse`; the queue is the series' downloads |
| Bookmarks tab | `CompanionLibrary.playableBookmarks`, newest first | `PlaybackLauncher.playBookmark`, then Now Playing |
| Up Next | `AudioPlayerService.queue`, current entry marked; a long queue shows a window starting just before the current entry | `playQueueItem(at:)`, then back to Now Playing |

- **Rows** show the title and subtitle from `CompanionRow`, listened progress
  (`CPListItem.playbackProgress`) and a trailing now-playing indicator on the loaded
  discourse (`isPlaying`). Series rows include a disclosure indicator. Icons are
  SF Symbols, so selection handlers never wait for an image.
- **Limits:** the tab bar requires `CPTabBarTemplate.maximumTabCount` of at least 3.
  With fewer tabs, the root is a single list containing the three sections. Lists use
  one section and at most `CPListTemplate.maximumItemCount` rows. A cut list shows a
  `First N · More on iPhone` header. Vehicles reporting no sections get an empty list.
- **Empty states** explain the next step: "No downloads yet / Download discourses on
  your iPhone to listen in the car.", "Nothing to continue", "No bookmarks yet" and
  "No downloads in this series".
- **Failures:** a `PlaybackLauncher.Failure` opens a `CPAlertTemplate` with the
  failure's `message`, such as "Download this discourse on your iPhone first." The
  interface stays on the list, which reloads. A later alert replaces an open alert.
- **Now Playing:** `CPNowPlayingTemplate.shared` provides two extra buttons. The speed
  button steps through 0.5, 0.75, 1, 1.25, 1.5, 1.75 and 2× and wraps from 2× to 0.5×.
  The bookmark button adds a bookmark at the current position through
  `BookmarkService.add`. It shows a filled glyph for two seconds and ignores repeated
  taps on the same discourse within three seconds. Up Next appears only when the queue
  has more than one discourse. The album/artist button is disabled.
- **Transport** (play/pause, skip 15/30 s, next/previous discourse and seeking) uses the
  phone's existing `MPRemoteCommandCenter` registration in `AudioPlayerService`. That
  registration includes `changePlaybackRateCommand` with the same rates, for Siri and
  the system. Next is enabled only when the queue has another discourse. Previous is
  enabled while a discourse is loaded because it restarts the current talk at the start
  of the queue. Now Playing info includes `PlaybackQueueIndex`/`Count`.

## Files

| File | Responsibility |
| --- | --- |
| `OshoDiscourses/CarPlay/CarPlaySceneDelegate.swift` | Scene connect/disconnect and interface-controller identity |
| `OshoDiscourses/CarPlay/CarPlaySessionController.swift` | Root, list loading and refresh, selection, failures and lifecycle |
| `OshoDiscourses/CarPlay/CarPlayListTemplates.swift` | Limits, list contexts, row mapping, empty states and single-completion handlers |
| `OshoDiscourses/CarPlay/CarPlayNowPlayingControls.swift` | Shared Now Playing buttons and the Up Next observer |
| `OshoDiscourses/CarPlay/CarPlayTemplateNavigator.swift` | Serialized navigation that follows the latest intent |
| `OshoDiscourses/CarPlay/CarPlayInterfaceTransport.swift` | Injectable `CPInterfaceController` boundary |
| `OshoDiscourses/CarPlay/CarPlayContentSource.swift` | Data/action protocol and its `AppRuntime` adapter, including change observation |

All CarPlay source and tests are compiled only with
`#if canImport(CarPlay) && !targetEnvironment(macCatalyst)`, so the Mac Catalyst build
omits them. The scene manifest in `project.yml` names
`$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate`, which resolves to
`OshoDiscourses.CarPlaySceneDelegate`.

## Lifecycle rules

- **Services are shared, never constructed.** The delegate calls the idempotent
  `AppRuntime.shared.start()` and reads `AppRuntime.shared`. This supports a cold
  launch from CarPlay without a phone window.
- **Connect** configures Now Playing buttons and Up Next before submitting the root,
  so they are ready if the system opens Now Playing directly. Root lists load
  synchronously from local state before root installation.
- **Connection IDs** live in each list's `userInfo` context. Handlers, interface
  completions, observations and timers from an earlier connection do nothing.
- **List handlers** call `completion()` exactly once in a `defer` on CarPlay's main-queue
  callback stack, including for stale, failed and disconnected selections.
- **Stale selections:** a handler sends only its row id. The session resolves that id
  against the page currently shown. A removed row reloads the list without playing.
  A row that still exists plays, even if the vehicle retained an older row object.
- **Navigation** submits one native operation at a time. A newer selection replaces a
  pending destination, and native tab changes cancel it. Now Playing is never pushed
  twice: if it is on top, nothing happens; if it is lower in the stack, CarPlay pops to
  it. At five templates, navigation pops to the root before pushing.
- **Refresh:** `withObservationTracking` monitors downloads, recent playback, bookmarks,
  the current track, playing state, queue and rate. Changes coalesce into one refresh
  of the root lists and the visible pushed list. `currentTime` is not observed. While
  audio plays, a 10 s timer refreshes the visible list for progress. When row ids match,
  rows update in place, so the list does not flicker and handlers remain valid.
- **Disconnect** cancels the timer, refresh task and observation. It removes this
  session's Now Playing observer and clears only delegates that still point to it.
  It never pauses playback, clears `MPNowPlayingInfoCenter`, or removes remote commands.
  A physical disconnect can still trigger the player's existing route-change pause
  policy, which is separate from the scene callback.
- **Logging:** local `Logger` (subsystem `com.agraabhi.oshodiscourses`, category
  `CarPlay`) records `connect` with the tab count, `disconnect`, `root_template_failed`,
  `navigation_failed` and `alert_failed`. It also records `selection` with
  `kind=discourse|bookmark|series|queue|row`, `outcome=played|opened|stale|failed`
  and the failure case name. Logs include no IDs or titles.

## Entitlement and signing

CarPlay apps need Apple's managed **CarPlay audio** entitlement
(`com.apple.developer.carplay-audio`).

1. Request the audio entitlement through Apple's CarPlay entitlement request form
   ([Requesting CarPlay entitlements](https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements)),
   while signed in as the account holder for team `W2NS9DM63G`. Requested and approved on
   2026-10-02; see [the request record](app-store/carplay/entitlement-request.md).
2. After approval, enable the CarPlay audio capability for App ID
   `com.agraabhi.oshodiscourses`. Then regenerate or refresh the development and
   distribution profiles.
3. Use the **`OshoDiscoursesCarPlay`** scheme. It uses `Debug-CarPlay` for Run/Test and
   `Release-CarPlay` for Archive, which sign with `Signing/CarPlay.entitlements` for
   CarPlay audio and iCloud key-value storage.

Use `OshoDiscourses` for ordinary development and current releases. Its Debug and
Release configurations request no CarPlay entitlement, so automatic signing works without
approval. The CarPlay code and scene manifest are present in those builds too. Without
the entitlement, iOS does not show the app in CarPlay. A Debug-CarPlay simulator build
contains `com.apple.developer.carplay-audio` in its processed entitlements. Device
signing with that scheme fails until the profile includes the capability.

## Test coverage

Swift Testing suites live under the serialized `CarPlayTests` parent because
`CPNowPlayingTemplate.shared` is process-global:

```sh
xcodebuild -project OshoDiscourses.xcodeproj -scheme OshoDiscourses \
  -destination 'id=<simulator>' -derivedDataPath build/DerivedData-carplay \
  test-without-building -only-testing:OshoDiscoursesTests/CarPlayTests
```

| Suite (file) | Coverage |
| --- | --- |
| `Templates` (`CarPlayTemplateTests.swift`) | Three-tab root with titles/symbols, empty-state copy, menu fallback when fewer than three tabs are allowed, item and section limits, truncation header, progress/current-indicator/disclosure mapping, Now Playing buttons before root installation, Up Next enablement and rate cycling |
| `SceneDelegate` (`CarPlayTemplateTests.swift`) | Objective-C exposure of both scene callback selectors and the module-qualified class name |
| `Session` (`CarPlaySessionTests.swift`) | Discourse and bookmark selection, Now Playing presentation without duplicate push, pop-to from Up Next, overlapping selections with delayed completion, series push, failure alert and replacement, stale rows after refresh, in-place progress updates, coalesced change refresh, playing-only progress timer, disconnect cleanup with Now Playing info preserved, late completions after disconnect, reconnect, rate button and bookmark button (repeat window and confirmation) |
| `RuntimeSource` (`CarPlayRuntimeSourceTests.swift`) | The `AppRuntime` adapter over real `CompanionLibrary`/`PlaybackLauncher`, with a silent `AudioPlayerService(settings: nil, connectsToSystem: false)` and isolated `PlaybackStateService` defaults. Covers each `Failure` case, page bounds, and observation that fires for list state but not position ticks, then cancels |

`CarPlaySupportTests.swift` provides `CarPlayTestInterface`, which stores separate stacks
for each tab and can delay completions, and `FakeCarPlaySource`. Session tests use the
fake source, so they never write to the real bookmarks file. The adapter's
`addBookmarkAtCurrentTime` is tested only for its no-track guard.

## Device acceptance

These checks require an approved profile and a head unit or the CarPlay simulator
display. This Xcode installation lacks the Simulator app's External Displays menu, so
CarPlay has not been rendered here.

- Cold launch from CarPlay with the phone locked: tabs appear populated, and Now
  Playing opens directly when the system chooses it.
- Discourse, series and bookmark selection; Now Playing appears once; Up Next marks the
  current entry; returning from Now Playing preserves each tab's stack.
- Speed button changes and Now Playing reflects the new rate. Bookmark button adds one
  bookmark visible on the phone, and the filled glyph is legible.
- Steering-wheel and knob input, skip 15/30 s, and next/previous at queue boundaries.
- Disconnect (cable and wireless) while playing: confirm what the route-change policy
  does, then reconnect to a fresh root while audio state is preserved.
- Empty library, Downloads after deleting a series on the phone, and a bookmark whose
  download was deleted (alert copy).
- Vehicle-specific item limits and long Hindi titles.
