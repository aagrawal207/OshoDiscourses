# Store and GitHub artwork

The current [1.16.1 bundle](../../docs/app-store/screenshots/1.16.1/README.md) reorders the
[1.16.0 bundle](../../docs/app-store/screenshots/1.16.0/README.md), which contains nine
iPhone and nine iPad posters, five Apple Watch captures, their raw captures, and a
checksum manifest. The
GitHub README uses a separate hero and three gallery strips.

## Tools

| File | Purpose |
| --- | --- |
| `seed.py` | Prepares real downloaded recordings and demonstration listening history on a fresh screenshot simulator |
| `capture.py` | Inspects live accessibility elements, taps a verified location and captures the actual display |
| `scenes.py` | Runs the player, reader, DeNoise, sleep-timer and activity capture sequences |
| `story.json` | Defines the ordered captions, palette and source image for each poster |
| `render.swift` | Uses AppKit/CoreText/ImageIO to render opaque sRGB images, JPEG galleries and the checksum manifest |
| `prepare.py` | Validates and plans the 1.16.0 listing; `--apply` prepares it once 1.15.0 has released |

Capture scripts are restricted to simulators whose names start with `Osho Store `.
The seeder refuses to overwrite existing app data. Its sample bookmarks and daily
totals are demonstration data; the three audio files are genuine recordings from
the app's public sources and stay in ignored `build/` storage.

## Simulator automation

Captures were made with iOS 26.5, using **Osho Store iPhone** (iPhone 17 Pro Max)
and **Osho Store iPad** (iPad Pro 13-inch M4). Install the app's Debug simulator
build on each fresh, signed-out simulator. The capture recipes target the 1.15.0
UI used in build 26; rerendering only needs the committed raw images.

The iPad set was recaptured from 1.16.0 (28), mostly in landscape so the sidebar and
the player's transcript pane appear. `simctl` cannot rotate a simulator and this Xcode
has no Simulator app, so a throwaway UI test that only sets
`XCUIDevice.shared.orientation` was built with `build-for-testing`, removed, and run
with `test-without-building -only-testing:` on the store iPad. The orientation
persists after the test, and accessibility frames are reported in the rotated
coordinate space. After rotating back to portrait, AXe's accessibility tree was empty
until the next relaunch, so the Hindi capture paused through a coordinate tap.

The renderer accepts 2752 × 2064 iPad captures and centres the shorter frame together
with its text. Mac capture is not scripted yet.

Watch captures are raw simulator images, not posters. `seed.py` and `scenes.py` do
not cover the Watch; the 1.16.0 set was taken with AXe taps on a paired store Watch.
The phone simulator held A Bird on the Wing #1-#3 as downloads. Because the simulator
never delivers `transferFile`, saved talks were placed directly in the Watch app's
`Application Support/Offline/` with an `index.json` matching `OfflineEntry`. The
watchOS simulator does not support `status_bar` overrides. WatchConnectivity
replies sometimes stopped arriving; rebooting the Watch simulator restored them.

The scripts invoke [Cameron Cooke's AXe](https://github.com/cameroncooke/AXe)
explicitly at `build/store-capture-tools/axe`. A different program named `axe` may
exist on the host PATH. The captured run used **v1.8.0**, universal macOS archive
SHA-256 `7b76340b72e90d0f211bc7c4636f15009076eff07acef2f2b632b175debd8834`.
Its bundled frameworks must remain beside the executable.

Set `PHONE` and `IPAD` to the dedicated simulators' UDIDs. The source recordings
required by `seed.py` are listed in its `RECORDINGS` array. Then:

```bash
python3 Tools/StoreAssets/seed.py --udid "$PHONE" --udid "$IPAD"
xcrun simctl status_bar "$PHONE" override --time '9:41' --dataNetwork wifi \
  --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 \
  --batteryState discharging --batteryLevel 100
xcrun simctl status_bar "$IPAD" override --time '9:41' \
  --wifiMode active --wifiBars 3 --batteryState discharging --batteryLevel 100
```

For each device, open the app on Home and capture `home`, then tap the Library tab
and capture `library`. Set `OUT` to `docs/app-store/screenshots/1.16.0/raw/iphone`
or `docs/app-store/screenshots/1.16.0/raw/ipad`, and `DEVICE` to its UDID:

```bash
xcrun simctl launch "$DEVICE" com.agraabhi.oshodiscourses
python3 Tools/StoreAssets/capture.py --udid "$DEVICE" --output "$OUT" --name home
python3 Tools/StoreAssets/capture.py --udid "$DEVICE" --output "$OUT" \
  --tap-label Library --type RadioButton --name library
for scene in activity player hindi denoise sleep; do
  python3 Tools/StoreAssets/scenes.py --scene "$scene" --udid "$DEVICE" --output "$OUT"
done
```

Playback scenes briefly play the genuine recording, pause through the real
transport control, and open the requested sheet. They use existing Debug launch
shortcuts. `--replace` explicitly retakes an existing capture. The English reader
uses the passage about meditation near 8:23 in A Bird on the Wing #1; its position
was checked against the shipped alignment data.

## Render and validate

```bash
swift Tools/StoreAssets/render.swift 1.16.1 --allow-mixed-builds
asc screenshots validate --path docs/app-store/screenshots/1.16.0/iphone --device-type IPHONE_69
asc screenshots validate --path docs/app-store/screenshots/1.16.0/ipad --device-type IPAD_PRO_3GEN_129
asc screenshots validate --path docs/app-store/screenshots/1.16.0/watch --device-type APP_WATCH_SERIES_10
python3 Tools/StoreAssets/prepare.py
```

The renderer keeps the raw app image intact inside a rounded frame. Headlines use
the system serif design and captions use the system sans-serif font, obtained
through AppKit's font APIs. Review both overview images and the README hero after
changing the story or source captures. The upload directories contain only the
nine ordered PNGs for iPhone and iPad, and the Watch PNGs in file-name order.

`prepare.py` checks that 1.15.0 has released before any remote write. It resolves
the new localization and an editable app-info record, previews changes, and
protects the previous version's image and set IDs. It verifies delivery before
clearing superseded optional iPhone images and their empty set containers on
1.16.0. The first pre-upload backup is preserved across repeated runs.

The live upload path completed on 2026-09-19. `--app-info` selects an explicit
editable record if several exist. The script prepares the listing; app submission
is a separate step.
