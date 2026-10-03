# 1.16.0 screenshot refresh

The iPhone set was uploaded to the 1.16.0 App Store Connect draft on 2026-09-19
and is unchanged: all nine images reached `COMPLETE`, with order and MD5 checksums
matching the local manifest. [Upload identifiers](upload-receipt.json) record that
upload. The version remains `PREPARE_FOR_SUBMISSION` with no build attached.

On 2026-10-02 the iPad set was recaptured from **1.16.0 (28)** and a new Apple Watch
set was added. Neither has been uploaded yet. A Mac set is still needed once the macOS
platform is added to the app record. CarPlay needs no App Store screenshots. See the
[release record](../../releases/1.16.0.md).

## Gallery

| Set | Images | Dimensions | CLI display type | Source build |
| --- | ---: | --- | --- | --- |
| [iPhone](iphone/) | 9 | 1320 × 2868 | `IPHONE_69` | 1.15.0 (26) |
| [iPad](ipad/) | 9 | 2064 × 2752 | `IPAD_PRO_3GEN_129` | 1.16.0 (28) |
| [Apple Watch](watch/) | 5 | 416 × 496 | `APP_WATCH_SERIES_10` | 1.16.0 (28) |

![iPhone gallery](iphone-overview.jpg)

<details>
<summary>iPad gallery</summary>

![iPad gallery](ipad-overview.jpg)

</details>

The iPhone and iPad order is: listening, English read-along, DeNoise, catalog
browsing, offline downloads, Hindi read-along, bookmarks, sleep timer and listening
stats. The first iPad image shows Home; the first iPhone image shows the full player.

The iPad posters show the 1.16 layout. Eight captures are landscape, with the
sidebar and the player's transcript beside the controls; the renderer centres the
shorter frame with its text. The Hindi read-along is portrait, with the transcript
below the controls.

| Watch image | Shows | Data |
| --- | --- | --- |
| `01-now-playing.png` | Remote control of the iPhone player | Real pairing |
| `02-home.png` | Home: iPhone now-playing row and iPhone section | Real pairing |
| `03-save-to-watch.png` | iPhone Downloads, A Bird on the Wing, Save to Watch action | Real pairing |
| `04-on-watch.png` | Saved talks with progress and storage | Real offline store |
| `05-watch-player.png` | Playing a saved talk on the Watch | Real offline store |

No Watch image uses `--watch-fixture`. The simulator does not deliver
`transferFile`, so three genuine recordings were copied into the Watch app's
`Application Support/Offline/` with an `index.json`, as a delivered transfer
would leave them. The watchOS simulator rejects `status_bar` overrides, so the Watch
clock shows the host time (8:22 to 8:30 PM) instead of 9:41.

## Source and validation

- iPhone: captured from **1.15.0 (26)** on iPhone 17 Pro Max, iOS 26.5.
- iPad: captured from **1.16.0 (28)**, Debug simulator build of `e31cba9`, on a
  fresh iPad Pro 13-inch (M4) simulator running iOS 26.5.
- Apple Watch: **1.16.0 (28)** on an Apple Watch Series 11 (46mm), watchOS 26.5,
  paired with an iPhone 17 Pro on iOS 26.5, both fresh simulators.
- Raw app captures and capture metadata, including model, OS, build and git
  commit, are retained in [raw/](raw/).
- Dedicated, signed-out simulators contain real downloaded recordings and
  demonstration bookmarks, completion history and daily totals. These are not a
  real listener's history. Audio files are excluded from the repository.
- Posters are opaque sRGB. Watch images are the raw captures re-encoded without the
  fully opaque alpha channel and with the sRGB profile; pixels are unchanged. The
  renderer records file sizes, SHA-256 and MD5 for all three sets in
  [manifest.json](manifest.json).
- `asc screenshots validate` passed all **23 images**, with zero errors or warnings.
- GitHub uses a hero and three JPEG gallery strips generated from the iPhone captures.

[Apple's screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
allow the largest iPhone and iPad sets to supply smaller sizes. The installed CLI
maps `IPHONE_69` to the API's `APP_IPHONE_67` set identifier. The older optional
6.1-inch and 6.5-inch images were cleared from 1.16.0 after the new largest set
completed. Their empty set containers were also removed to clear validation errors.

## Recheck or update the App Store draft

From the repository root:

```bash
python3 Tools/StoreAssets/prepare.py
```

This validates local metadata and image checksums, reads the live version state,
and prints a plan. To apply changes to the existing draft:

```bash
python3 Tools/StoreAssets/prepare.py --apply --app-info 59482fd4-cdf1-4ecf-a4ac-ec035e9c41e8
```

The apply path creates or updates the editable 1.16.0 listing, applies its prepared
metadata, uploads every image set in the manifest and checks delivery state, order and checksums.
It refuses to proceed while 1.15.0 is queued, or if source and target unexpectedly
share screenshot resources. The live path has completed for 1.16.0. App binary
preparation and submission remain separate release steps.

See [capture/render tools](../../../../Tools/StoreAssets/README.md) and the
[1.16.0 release draft](../../releases/1.16.0.md).
