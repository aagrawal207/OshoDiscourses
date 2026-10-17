# Testing the Android app

Four layers, fastest first. Run every command from `android/`. The emulator in these
notes is `emulator-5554` (Pixel 9, Android 16, Google Play image).

```sh
export ANDROID_HOME=$HOME/Library/Android/sdk
export PATH=$ANDROID_HOME/platform-tools:$PATH
```

| Layer | Runs on | What it covers | Command |
| --- | --- | --- | --- |
| Unit | JVM, Robolectric | Contracts, repositories, merge rules, engines with fakes, view models | `./gradlew testDebugUnitTest` |
| Screenshot | JVM, Robolectric native graphics | Compose screens against committed PNGs | `./gradlew verifyRoborazziDebug` |
| Instrumented | Emulator or phone | Media3 service, native DeepFilterNet and RNNoise | `./gradlew :playback:connectedDebugAndroidTest :denoise:connectedDebugAndroidTest` |
| Maestro | Emulator or phone | The installed debug app, end to end, with real downloads | `e2e/run.sh --install` |

The pre-merge gate is:

```sh
./gradlew assembleDebug testDebugUnitTest verifyRoborazziDebug --max-workers=6
```

CI runs `assembleDebug testDebugUnitTest` only; screenshots are compared on macOS,
because rendering differs a little between operating systems.

## Unit tests

```sh
./gradlew testDebugUnitTest                    # every module
./gradlew :feature:series:testDebugUnitTest    # one Android module
./gradlew :core:model:test                     # one JVM module
./gradlew :core:ui:testDebugUnitTest --tests '*SwipeToDeleteTest*'
```

Fakes for every `:core:domain` contract live in `:core:testing`
(`FakeAppServices.preview()`). Compose behaviour tests use `createComposeRule()` under
Robolectric with `@Config(sdk = [36], qualifiers = "w393dp-h852dp-xxhdpi")`.

## Screenshot tests (Roborazzi)

```sh
./gradlew :feature:home:recordRoborazziDebug    # record or update references
./gradlew verifyRoborazziDebug                  # fail on any pixel difference
./gradlew :feature:home:compareRoborazziDebug   # write *_compare.png diffs
```

References live in each module's `src/test/screenshots/`. Record on macOS and commit the
PNGs with the change that moved them.

## Instrumented tests

```sh
./gradlew :playback:connectedDebugAndroidTest
./gradlew :denoise:connectedDebugAndroidTest
adb logcat -d -s DenoiseBenchmark     # Best Quality real-time factor on 60 s of 44.1 kHz stereo
```

Only one Gradle invocation may drive a device at a time. With several devices attached,
set `ANDROID_SERIAL`.

## Maestro flows

Maestro 2.x drives the installed debug build through the accessibility tree. Flows are in
`e2e/flows/`, shared steps in `e2e/subflows/` and small JavaScript helpers in
`e2e/scripts/`.

```sh
e2e/run.sh                                  # all flows on emulator-5554, app already installed
e2e/run.sh --install                        # build and install the debug app first
e2e/run.sh --device <serial> --out <dir>    # another device or report folder
e2e/run.sh --flow e2e/flows/07_transcript.yaml
maestro --device emulator-5554 test e2e/flows/04_player_transport.yaml   # one flow, console only
```

`run.sh` sets font scale 1.0, light system theme and airplane mode off, then writes
`build/e2e/report.xml` (JUnit) and `build/e2e/artifacts/` (screenshots, hierarchy and
logs for each flow). It exits non-zero if any flow fails. A full run takes about 6 minutes.

| Flow | Checks |
| --- | --- |
| `01_first_launch` | `clearState` launch shows Home and the four catalog shelves |
| `02_library_search_filter` | Hindi and English chips filter the list; search narrows it; a row opens the series |
| `03_download` | A row tap downloads New Alchemy To Turn You On #19 (13 min, 4.6 MB) over the real network; the row shows Play and Downloads lists it |
| `04_player_transport` | Row play shows the mini-player and full player; pause and resume; +30 and −15 move the clock by 30 s and 15 s; 1.25× survives a relaunch |
| `05_sleep_timer` | 15 min sets the timer, the menu then offers Cancel, and Cancel clears it |
| `06_bookmark` | Add Bookmark with a category and note, find it in Bookmarks, play it, swipe-delete it |
| `07_transcript` | Reader search finds "camp" (1/2); Play from here seeks into the paragraph's time range |
| `08_denoise` | Enable DeNoise, pick Best Quality, status reaches "Enhancement is on", then off again |
| `09_settings_appearance` | Dark appearance and the Teal accent persist across a relaunch; restores Light and Purple |
| `10_support_sheet` | The sheet opens and shows either the tips or "Couldn't load tips from Google Play" |
| `11_stats_history` | Listening Stats totals, periods and Listening History with the played talk |
| `13_restore_after_close` | Force-stopping the app while it plays, then launching it, shows the talk in the mini-player, paused, at most one auto-save tick (10 s) before where it stopped; Play resumes from there |
| `12_downloads_delete` | Swipe-deleting the playing talk empties Downloads, moves it to Previously Downloaded and removes the mini-player |

Rules the flows follow:

- `flows/config.yaml` fixes the order. `03` downloads the talk, `04`–`11` and `13` reuse it
  (the shared `ensure_downloaded` step fetches it again when a flow runs alone) and `12`
  deletes it, so a run leaves no audio behind.
- Selectors are visible text and content descriptions. The tab bar items carry test tags
  (`tab.home`, `tab.library`, `tab.downloads`, `tab.settings`); `AppShell` sets
  `testTagsAsResourceId`, so Maestro selects them with `id:`. Page titles repeat the tab
  names, which makes text selectors for tabs ambiguous.
- Series rows merge into one node whose description is
  `Discourse <n>[, completed][, transcript available]`.
- The status-bar clock matches any `m:ss` pattern. Scope time selectors with `below:` and
  `leftOf:` (see `04` and `07`).
- A full swipe left (from the row's trailing button) deletes a row; there is no Delete
  button to tap.

## Debug command receiver

Debug builds register `DebugCommandReceiver` (`app/src/debug`). It accepts broadcasts from
the shell only (`android.permission.DUMP`) and logs the result under the tag `DebugCmd`.

```sh
dbg() { adb shell am broadcast -a com.agraabhi.oshodiscourses.DEBUG -p com.agraabhi.oshodiscourses --es cmd "$@"; }
dbg state                                        # player, DeNoise, sleep timer and download states
dbg play --es id english-New_Alchemy_To_Turn_You_On-19 --es from 0
dbg pause
dbg resume
dbg download --es id english-New_Alchemy_To_Turn_You_On-19
dbg delete --es id english-New_Alchemy_To_Turn_You_On-19
dbg sleep --ei minutes 5
dbg sleep_end
dbg sleep_cancel
dbg denoise --ez on true --es mode deepFilterNet  # or rnnoise; --ez on false turns it off
dbg cellular --ez on true
adb logcat -d -s DebugCmd | tail -6
```

`state` prints `player track=… playing=… buffering=… t=… processing=…`,
`denoise enabled=… status=… label="…" inStep=…`, the sleep timer and
`downloads states={…} downloaded=[…] network=…`. Passing `--es id` also prints the saved
position and duration for that talk.

The launcher intent extra `debugDownloadNetwork` fakes the network for download UI checks:

```sh
adb shell am start -n com.agraabhi.oshodiscourses/.MainActivity --es debugDownloadNetwork cellularOnly   # or offline
```

## Emulator checks

Commands used for the device-only checks. Restore every setting afterwards.

| Check | Commands | Evidence |
| --- | --- | --- |
| Transcript keeps the screen on | Open the reader while playing; `adb shell dumpsys power \| grep SCREEN_BRIGHT`; `adb shell dumpsys window windows \| grep KEEP_SCREEN_ON` | `SCREEN_BRIGHT_WAKE_LOCK` for the app only while the reader is open and playing |
| Best Quality steadiness | `dbg denoise --ez on true --es mode deepFilterNet`, then poll `dbg state` every 2 s for 5 min | Every `label="Enhancement is on"`; `dumpsys media.audio_flinger` shows `Underruns 0` on the app's track |
| Phone call | `adb emu gsm call 5551234`, then `adb emu gsm cancel 5551234` | Pauses on ring; resumes after the call only if it was playing |
| Headset unplug | Not possible on the emulator: `AUDIO_BECOMING_NOISY` is a protected broadcast | `PlaybackEngineTest` covers it under Robolectric |
| Doze | `adb shell dumpsys battery unplug; adb shell dumpsys deviceidle force-idle`; undo with `deviceidle unforce` and `battery reset` | Playback continues; a running transfer continues |
| Airplane mode | `adb shell cmd connectivity airplane-mode enable` / `disable` | Downloads shows "Waiting for a connection"; the job restarts when back online |
| Save on background | Play, press Home, wait 1 s for the process `ON_STOP`, `adb shell am force-stop`, then launch | The restored position is within about 1 s of where playback was at the force-stop |
| Launch restore | Play, then `adb shell am force-stop` (or `run-as com.agraabhi.oshodiscourses kill -9 <pid>` while paused in the background) and launch. `adb shell dumpsys audio`, `dumpsys notification --noredact` and `dumpsys activity services com.agraabhi.oshodiscourses` | The mini-player shows the talk paused at its last saved position; no focus entry, notification or service from the app until Play |
| Swipe from recents | `adb shell input keyevent KEYCODE_APP_SWITCH`, then swipe the card up | The user-initiated transfer job keeps the process and commits the file. A playing talk keeps playing (Media3's default), and the position is saved |
| Font scale | `adb shell settings put system font_scale 2.0` (restore `1.0`) | Screens grow; the tab bar stays at its fixed size |
| Dark mode | `adb shell cmd uimode night yes` (restore `no`) | Only Appearance = System follows it; Light and Dark are explicit |
| Rotation | `adb shell settings put system accelerometer_rotation 0; adb shell settings put system user_rotation 1` (restore `1` and `0`) | Not locked, as the iOS app allows landscape on iPhone; the player scrolls |
| Slow network | `adb emu network speed edge` (restore `full`) | |

## What only a real phone can verify

- Bluetooth and wired headsets: media buttons, `AUDIO_BECOMING_NOISY` on unplug, Bluetooth
  route changes and car head units.
- Real phone calls and VoIP apps taking audio focus, beyond the emulator's GSM ring.
- Sustained Best Quality battery drain and thermal throttling over a full talk, and the
  real-time factor on a mid-range or older arm64 CPU (the emulator is x86_64 on a Mac).
- True Doze and App Standby buckets after hours unplugged; OEM battery managers that kill
  foreground services (Samsung, Xiaomi, OnePlus).
- Download behaviour on a real cellular network: metered detection, Wi-Fi to cellular
  hand-off and captive portals.
- Google Play Billing purchases, subscriptions and the In-App Review prompt (need a Play
  listing and a licence-tester account), and Google Drive sync (needs the OAuth clients).
- Lock-screen, Wear OS and Android Auto media controls, haptics and the feel of the glass
  blur at 120 Hz.
