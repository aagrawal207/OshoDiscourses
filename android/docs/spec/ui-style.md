# Osho Talks Android: UI style reference

The shared visual spec for every Android screen worker. The iOS sources are the
source of truth. Every value below comes from the file named in the row. Paths are
relative to `OshoDiscourses/`. Where a screenshot in `docs/screenshots/` and the code
disagree, the code wins. The screenshots were taken on iOS 26 (Liquid Glass) and some
show older layouts, for example the old Continue Listening rows.

Scope: phone (compact width) only. iPad/Mac branches (`isRegular`, `SeriesTileView`,
`regularHeader`, sidebar, embedded transcript pane, `EscapeKeyHandler`, tab accessory
mini-player) and the Apple Watch screen (`Views/Watch/AppleWatchView.swift`) are out of
scope for v1.

## 0. Units and conventions

| iOS | Android | Rule |
| --- | --- | --- |
| pt (layout) | dp | 1 pt = 1 dp. iOS pt is 1/163 in, Android dp is 1/160 in. |
| pt (font) | sp | 1 pt = 1 sp at default Dynamic Type (Large) and `fontScale = 1.0`. |
| `.padding()` / `.padding(.horizontal)` with no value | 16 dp | SwiftUI default system padding on iPhone. |
| `@ScaledMetric` sizes | `dp * fontScale` | Artwork 280, play glyph 64 scale with text size. |
| `.dynamicTypeSize(...xxxLarge)` | cap `fontScale` at 1.35 | xxxLarge body is 23 pt (23/17 ≈ 1.35). Used on the player bottom controls and the transcript search, transport and selection bars. |
| `dynamicTypeSize.isAccessibilitySize` | `fontScale >= 1.6` | AX1 body is 28 pt (≈ 1.65×). Changes the speed popover, DeNoise pickers and tip rows to stacked layouts. |
| 44 pt minimum hit area | 44 dp | Set `LocalMinimumInteractiveComponentSize` to 44.dp in the theme so Material controls do not grow to 48 dp and shift the layout. |
| SwiftUI `withAnimation {}` (default) | `spring(dampingRatio = 1f, stiffness = Spring.StiffnessMediumLow)` | ≈ 0.35–0.5 s with no bounce. |
| `.easeInOut(duration: d)` | `tween(d*1000, easing = FastOutSlowInEasing)` | |

## 1. Colours

### 1.1 Semantic surfaces and text (UIKit dynamic colours)

The app uses only system semantic colours, plus the accent and a few hardcoded system
hues. Dark mode is true black. **Elevated** is the dark variant iOS uses inside sheets
and popovers (Player, DeNoise, Transcript, Queue, Add Bookmark, Tip jar). Light mode has
no elevated variant. Compare the dark gray player sheet in
`docs/screenshots/listen-and-read.jpg` with the black Home tab.

| Token (iOS) | Light | Dark (base) | Dark (elevated: sheets) | Used for |
| --- | --- | --- | --- | --- |
| `systemBackground` | `#FFFFFF` | `#000000` | `#1C1C1E` | Library, Series, Bookmarks, Stats, History page; Player, Transcript |
| `secondarySystemBackground` | `#F2F2F7` | `#1C1C1E` | `#2C2C2E` | Series waiting-notice card; transcript search field |
| `tertiarySystemBackground` | `#FFFFFF` | `#2C2C2E` | `#3A3A3C` | (not used directly) |
| `systemGroupedBackground` | `#F2F2F7` | `#000000` | `#1C1C1E` | Home page, Settings/DeNoise Form page, Tip jar page, Downloads list |
| `secondarySystemGroupedBackground` | `#FFFFFF` | `#1C1C1E` | `#2C2C2E` | Home cards, list/form rows (all `listRowBackground`) |
| `tertiarySystemGroupedBackground` | `#F2F2F7` | `#2C2C2E` | `#3A3A3C` | (not used directly) |
| `label` = SwiftUI `.primary` | `#000000` | `#FFFFFF` | same | Primary text |
| `secondaryLabel` = `.secondary` | `#3C3C43` @ 60 % (`#993C3C43`) | `#EBEBF5` @ 60 % (`#99EBEBF5`) | same | Subtitles, counts, times |
| `tertiaryLabel` = `.tertiary` | `#3C3C43` @ 30 % | `#EBEBF5` @ 30 % | same | Location/year, transcript icon in rows |
| `quaternaryLabel` = `.quaternary` | `#3C3C43` @ 18 % | `#EBEBF5` @ 18 % | same | Row chevrons, `·` separators |
| `placeholderText` | `#3C3C43` @ 30 % | `#EBEBF5` @ 30 % | same | Search and text field placeholders |

Notes:
- Library, Bookmarks, Listening Stats and Listening History use `systemBackground`
  behind inset-grouped rows coloured `secondarySystemGroupedBackground`. In light mode
  both are white, so the cards are invisible and the list looks flat. This is
  intentional parity (`Views/Settings/ListeningStatsView.swift:15-16`, `BookmarksView.swift:40,94`).
- Home uses `systemGroupedBackground` so its white cards stand out (`Views/Home/HomeView.swift:86`).
- Settings and Downloads use the native grouped Form/List background (`Views/Settings/SettingsView.swift:42-46`).

### 1.2 Fills and separators

| Token | Light | Dark | Used for |
| --- | --- | --- | --- |
| `systemFill` | `#787880` @ 20 % | `#787880` @ 36 % | Slider inactive track, switch off track |
| `secondarySystemFill` | `#787880` @ 16 % | `#787880` @ 32 % | — |
| `tertiarySystemFill` | `#767680` @ 12 % | `#767680` @ 24 % | Inactive filter chips (Library, Bookmarks), sort chip, speed presets, bookmark category buttons, segmented-control track, search field |
| `quaternarySystemFill` | `#747480` @ 8 % | `#767680` @ 18 % | — |
| `separator` (SwiftUI `Divider`) | `#3C3C43` @ 29 % | `#545458` @ 60 % | All `Divider()`s, hairline 1 px (`Dp.Hairline`) |
| `opaqueSeparator` | `#C6C6C8` | `#38383A` | Use when a divider draws over translucent material |

### 1.3 Accent colours (eight)

Source: `Services/UserSettings.swift:5-23`. Each case maps to the SwiftUI system colour
of the same name. These values change with the OS. Ship the **iOS 26** values, which
match the screenshots (purple shows as magenta `#CB30E0`). iOS 18 values are listed for
reference only. The values come from Apple HIG, "Color", updated 9 June 2025.

| Order | `rawValue` | Display name (`rawValue.capitalized`) | Light (iOS 26) | Dark (iOS 26) | Light (iOS 18) | Dark (iOS 18) |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | `blue` | Blue | `#0088FF` (0,136,255) | `#0091FF` (0,145,255) | `#007AFF` | `#0A84FF` |
| 1 | `teal` | Teal | `#00C3D0` (0,195,208) | `#00D2E0` (0,210,224) | `#30B0C7` | `#40C8E0` |
| 2 | `purple` | Purple | `#CB30E0` (203,48,224) | `#DB34F2` (219,52,242) | `#AF52DE` | `#BF5AF2` |
| 3 | `pink` | Pink | `#FF2D55` (255,45,85) | `#FF375F` (255,55,95) | `#FF2D55` | `#FF375F` |
| 4 | `orange` | Orange | `#FF8D28` (255,141,40) | `#FF9230` (255,146,48) | `#FF9500` | `#FF9F0A` |
| 5 | `green` | Green | `#34C759` (52,199,89) | `#30D158` (48,209,88) | `#34C759` | `#30D158` |
| 6 | `indigo` | Indigo | `#6155F5` (97,85,245) | `#6D7CFF` (109,124,255) | `#5856D6` | `#5E5CE6` |
| 7 | `mint` | Mint | `#00C8B3` (0,200,179) | `#00DAC3` (0,218,195) | `#00C7BE` | `#63E6E2` |

Rules (`UserSettings.swift`):
- Default accent: **purple** (`:265`). Default appearance: **light** on first launch (`:264`). Appearance options: `system`, `dark`, `light`.
- Daily shuffle (`dailyAccentShuffle`, default false): `effectiveAccent = allCases[((day % 8) + 8) % 8]`. `day` is the number of whole days from the local start of day of `Date(timeIntervalSince1970: 0)` to the local start of today (`:196-213`). Kotlin: `ChronoUnit.DAYS.between(Instant.EPOCH.atZone(zone).toLocalDate(), LocalDate.now(zone))`. Recompute at launch and when the app returns to the foreground (`App/OshoDiscoursesApp.swift:54-58`).
- Tapping a swatch sets `dailyAccentShuffle = false` and pins that accent (`SettingsView.swift:156-161`).
- The accent is the app-wide tint (`ContentView.swift:51`). It colours toggles, sliders, progress views, default-style buttons, links, menus and the AirPlay icon. Sheets set it again (`ContentView.swift:204`).
- On accent fills (active chips, Now-playing pill) the text is white.

### 1.4 Other fixed system colours

Use the iOS 26 values. The iOS 18 values are in brackets.

| Colour | Light | Dark | Used for |
| --- | --- | --- | --- |
| Red (destructive) | `#FF383C` [`#FF3B30`] | `#FF4245` [`#FF453A`] | Destructive menu/dialog items, sleep "Cancel", download failure text and retry icon, Downloads "Delete", swipe delete |
| Green | `#34C759` | `#30D158` | Completed checkmarks, "N/M completed", "Discourses Done" icon |
| Orange | `#FF8D28` [`#FF9500`] | `#FF9230` [`#FF9F0A`] | Bookmarks row icon in Downloads, Streak flame, DeNoise issue text |
| Yellow @ 45 % | `#FFCC00` | `#FFD600` | Transcript search-match background |
| Blue (hardcoded, **not** accent) | `#0088FF` | `#0091FF` | Series row title while playing (`SeriesDetailView.swift:344`), Bookmark row title while playing (`BookmarksView.swift:137`), Add Bookmark icons and selected category (`AddBookmarkSheet.swift:42,52,74,77`). Probably a bug, but kept for parity. |
| Purple (hardcoded) | `#CB30E0` | `#DB34F2` | "Series Done" stat icon (`ListeningStatsView.swift:66`) |
| White | `#FFFFFF` | | Swatch checkmark, active chip text, Now-playing pill text, launch title |
| Launch background | `#1E0F44` (sRGB 0.118, 0.059, 0.267) | same | Splash (`Resources/Assets.xcassets/LaunchBackground.colorset`) |

### 1.5 Opacity tokens used on top of colours

| Expression | Where |
| --- | --- |
| accent @ 0.10 | Theme chips (Series header), current transcript row background |
| accent @ 0.12 | Bookmark category tag |
| accent @ 0.14 | Transcript action chips; picked transcript row |
| accent @ 0.15 | "Download All" button, GET pill, "Back to m:ss" pill, tip price capsule |
| accent @ 0.18 | Selected speed preset |
| blue @ 0.20 | Selected Add Bookmark category |
| primary @ 0.05 | Selected (tapped) transcript row |
| primary @ 0.08 | Small dismiss-× circle background; mini-player progress track |
| primary @ 0.10 | Continue Listening progress track; thumbnail shadow (Series header, radius 20) |
| primary @ 0.15 | Download ring track |
| primary @ 0.45 / 0.55 / 0.60 | Transcript past rows / non-current sentence in current row / future rows |
| secondary @ 0.50 | Player drag-handle capsule |
| white @ 0.08 | Player artwork glow shadow (radius 30) |
| black @ 0.30 | Mini-player shadow (radius 8, y 2) |
| black @ 0.20 | Now-playing pill shadow (radius 8, y 2) |
| opacity 0.35 | Disabled Up Next button and disabled Transcript button in player |
| opacity 0.80 | "(N · ~X MB)" part of Download All |

### 1.6 Hierarchical style inside tinted buttons (important trap)

In SwiftUI, `.foregroundStyle(.secondary)` inside the label of a default-style `Button`,
`Link` or `Menu` resolves against the tint. It renders as **accent at secondary
opacity** (≈ 60 %), not gray. The screenshots confirm this for:
- Home "Clear All" (light purple, `HomeView.swift:188-190,282-284`).
- Downloads series-header "•••" (`DownloadsView.swift:404-406`).

The same rule makes these accent-tinted: Library sort chip text (`LibraryView.swift:250-261`)
and the trailing arrows on Settings > About rows (`SettingsView.swift:309-311`).
Buttons with `.buttonStyle(.plain)` and explicit `Color.primary`/`Color.secondary` stay
gray. Examples: the dismiss × buttons, Library filter chips (a ternary forces
`Color.secondary`) and the My Other Apps rows. On Android, use `accent.copy(alpha = 0.6f)`
for the tinted cases.

### 1.7 Materials (translucency)

| iOS material | Where | Android recipe |
| --- | --- | --- |
| `.ultraThinMaterial` | Mini-player (`MiniPlayerView.swift:56`), "Bookmarked at" toast (`PlayerView.swift:171`), transcript toast (`TranscriptView.swift:251`), Downloads multi-select bar (`DownloadsView.swift:162`) | API 31+: backdrop blur 30 dp + tint light `#FFFFFF` @ 55 %, dark `#1C1C1E` @ 55 %. Fallback (API < 31 or no blur library): opaque-ish light `#F9F9F9` @ 94 %, dark `#1C1C1E` @ 94 %. |
| `.regularMaterial` | Tip jar "Purchase pending" bar (`TipJarView.swift:154`) | Tint light `#FFFFFF` @ 75 %, dark `#1C1C1E` @ 75 % + blur; fallback same at 96 %. |
| `.bar` (chrome) | Transcript search bar, transport bar, selection bar, alignment row; Select Text hint | Light `#F9F9F9` @ 94 %, dark `#161616` @ 94 % (elevated: `#252525` @ 94 %). |
| iOS 26 tab bar / toolbar buttons (Liquid Glass) | Tab bar, back button, toolbar buttons (screenshots) | Same as `.ultraThinMaterial`, plus a 0.5 dp hairline border white @ 30 % (light) / white @ 10 % (dark), and shadow black @ 12 % blur 12 dp. |

Compose has no backdrop blur in the framework. `Modifier.blur` blurs the composable
itself, not what is behind it. Real glass needs the Haze library
(`dev.chrisbanes.haze`), which the coordinator must add to `libs.versions.toml`. Until
then, use the fallback tints. They keep the look of the shapes.

### 1.8 Gradient thumbnails (exact algorithm)

Source: `Views/Home/HomeView.swift:442-531` (`SeriesThumbnailView`).

1. Hash: 64-bit **FNV-1a** over the UTF-8 bytes of the series **name** (not id). Offset `0xcbf29ce484222325`. Prime `0x100000001b3`. For each byte: `hash ^= byte; hash = hash &* prime` (wrapping).
2. `hue1 = (hash % 360) / 360`. `hue2 = ((hash / 360) % 360) / 360`. These use **unsigned** 64-bit division.
3. Colours: `HSB(hue1, s 0.6, b 0.5)` → `HSB(hue2, s 0.7, b 0.3)`. HSB = HSV.
4. Linear gradient from top-leading to bottom-trailing (corner to corner).
5. Shape: rounded rectangle with **corner radius 12 at every size**, even 32 and 36. The square is `size × size`.
6. Overlay:
   - If a cover exists (`CoverArtLoader` / `ArchiveCatalog.coverURL`, a waveform PNG with a transparent background): draw it `scaledToFill`, clipped to the same rounded rectangle, over the gradient. No initials. It must not take taps.
   - Else draw the initials: `String(name.prefix(2)).uppercased()`, which is the first **two grapheme clusters**. "A Sudden Clash…" gives "A " (shows as "A"). Font: system bold, `size * 0.3`. Colour: `label` (black in light mode, white in dark mode).
7. Decorative only. Hide it from accessibility.
8. Sizes in use: 32 (Downloads and Continue Listening headers), 36 (Home shelf card), 48 (Library row, Recently Completed), 120 (Series header).

```kotlin
fun stableHash(s: String): ULong {
    var h = 0xcbf29ce484222325uL
    for (b in s.encodeToByteArray()) { h = h xor b.toUByte().toULong(); h *= 0x100000001b3uL }
    return h
}
fun thumbnailColors(name: String): List<Color> {
    val h = stableHash(name)
    return listOf(
        Color.hsv((h % 360uL).toFloat(), 0.6f, 0.5f),
        Color.hsv(((h / 360uL) % 360uL).toFloat(), 0.7f, 0.3f),
    )
}
// Brush.linearGradient(colors) with default start/end = top-left → bottom-right.
// Initials: BreakIterator.getCharacterInstance() to take 2 grapheme clusters, then uppercase(Locale.ROOT).
```

The iOS tests in `OshoDiscoursesTests/` do not cover this. Add a JVM test that pins
the hash for a few series names, and a screenshot test that compares against an iOS
capture.

### 1.9 Proposed Compose theme mapping (`:core:ui`)

| Material 3 role | Light | Dark |
| --- | --- | --- |
| `primary` | accent light | accent dark |
| `onPrimary` | `#FFFFFF` | `#FFFFFF` |
| `background` | `#FFFFFF` | `#000000` |
| `surface` | `#FFFFFF` | `#000000` |
| `surfaceContainer` (cards/rows) | `#FFFFFF` | `#1C1C1E` |
| `surfaceContainerHigh` (sheets) | `#FFFFFF` | `#1C1C1E` |
| `surfaceContainerHighest` (rows in sheets) | `#FFFFFF` | `#2C2C2E` |
| `onSurface` | `#000000` | `#FFFFFF` |
| `onSurfaceVariant` | secondaryLabel | secondaryLabel |
| `outlineVariant` | separator | separator |
| `error` | red | red |

Also expose an `OshoColors` CompositionLocal with every token in §1.1–1.4 by its iOS
name (`secondaryLabel`, `tertiarySystemFill`, …) and an `elevated: Boolean` flag. Sheets
provide `elevated = true`, so `systemBackground` and the grouped tokens switch to the
elevated column. Do not use dynamic colour (Material You).

## 2. Typography

### 2.1 Text styles (iOS Dynamic Type "Large" defaults → Compose)

Font family: `FontFamily.Default` (Roboto). Do not copy SF tracking, because Roboto
already sets wider. Use `letterSpacing = 0.sp`. Weights: regular 400, medium 500,
semibold 600, bold 700. Below API 31, Roboto may draw 600 as 700. That is acceptable.
Monospaced digits (`.monospacedDigit()`) → `fontFeatureSettings = "tnum"`. Serif
(transcript emphasis) → `FontFamily.Serif`.

| SwiftUI | Size (sp) | Line height (sp) | Default weight | Proposed token |
| --- | --- | --- | --- | --- |
| `.largeTitle` (nav large title is bold) | 34 | 41 | 400 (700 in nav) | `OshoType.largeTitle` |
| `.title` | 28 | 34 | 400 | `title` |
| `.title2` | 22 | 28 | 400 | `title2` |
| `.title3` | 20 | 25 | 400 | `title3` |
| `.headline` | 17 | 22 | **600** | `headline` |
| `.body` | 17 | 22 | 400 | `body` |
| `.callout` | 16 | 21 | 400 | `callout` |
| `.subheadline` | 15 | 20 | 400 | `subheadline` |
| `.footnote` | 13 | 18 | 400 | `footnote` |
| `.caption` | 12 | 16 | 400 | `caption` |
| `.caption2` | 11 | 13 | 400 | `caption2` |
| Inline nav title | 17 | 22 | 600 | `navInline` |
| Tab bar label (iOS 26) | 10 | 12 | 600 | `tabLabel` |
| Segmented control | 13 | 16 | 500 (selected 600) | `segment` |
| Grouped list section header (iOS 26, observed) | 17 | 22 | 600, secondaryLabel, **no uppercase** | `listHeader` |
| Grouped list section footer | 13 | 18 | 400, secondaryLabel | `listFooter` |
| Alert/dialog title | 17 | 22 | 600 | |
| Action-sheet title / message | 13 | 18 | 600 / 400, secondaryLabel | |

Icons sized with `.font(...)` take the style's point size as their glyph height. For
example `.title2` → 22 sp glyph, which draws ≈ 26–28 dp tall for circle symbols. Use
the icon sizes in §4.

### 2.2 Fixed-size fonts (do not scale with Dynamic Type on iOS)

| Size / weight | Where |
| --- | --- |
| 22 semibold, white | Launch "Osho Talks" (`LaunchView.swift:29`) |
| `size*0.3` bold | Thumbnail initials |
| 18 | Player bottom-control icons, in a 22-high frame |
| `max(44, min(64*scale, width*0.18))` | Player play/pause glyph |
| 11 medium | Row chevrons (Library, Continue Listening header); swatch checkmark (11 **bold**) |
| 10 | Series theme chips; completed badge on discourse row; dismiss × glyph (10 medium) |
| 9 | Library sort chevron; bookmark tag icon |
| 8 | Stop square inside download ring |
| 40 | Tip jar cup icon |
| `transcriptFontSize` | Transcript rows: 15, 17, 19 (default), 21, 24, 28 (`UserSettings.swift:179-180`) |

### 2.3 Usage index

| Text | Style | Colour | File |
| --- | --- | --- | --- |
| Home section titles "Continue Listening", "Recently Completed" | title3 bold | primary | `HomeView.swift:179,273` |
| Home shelf titles "Popular in English" … | subheadline 600 | primary | `HomeView.swift:332` |
| Shelf card name / count | caption 500 / caption2 | primary / secondary | `HomeView.swift:421-429` |
| Continue header name / meta | subheadline 600 / caption2 | primary / secondary | `HomeView.swift:547-554` |
| Continue row "Discourse N" | subheadline | accent if current track, else primary | `HomeView.swift:602-605` |
| Recently Completed row title / series | subheadline 600 / caption (2 lines) | primary / secondary | `HomeView.swift:209-217` |
| "Clear All" | caption | accent @ 60 % (see §1.6) | `HomeView.swift:188` |
| Support card text / buttons | subheadline / subheadline (Support = 600) | primary / accent | `HomeSupportCard.swift:45-92` |
| Library chip | caption 500 | white on accent / secondary | `LibraryView.swift:223` |
| Library row name / meta | subheadline / caption2 | primary / secondary, `·` quaternary | `LibraryView.swift:283-299` |
| Series title | title2 bold, centred | primary | `SeriesDetailView.swift:82` |
| Series meta | subheadline | secondary; language accent | `:86-95` |
| "N/M completed" | caption | green | `:100-102` |
| Transcripts label | caption | secondary | `:107-114` |
| Description / "Place, Year" | caption (4 lines) / caption2 | secondary / tertiary | `:119-128` |
| Theme chip | 10 sp | accent | `:135` |
| Download All | subheadline; "Download All" 600; count regular | accent | `:241-251` |
| Discourse row number / title / status | subheadline / body / caption2 | secondary / primary (blue if playing) / red, secondary | `:322-366` |
| GET pill | caption bold | accent | `:503-504` |
| Player series title / subtitle | title3 bold (2 lines) / subheadline (1 line, min scale 0.85) | primary / secondary | `PlayerView.swift:417-459` |
| Player times | caption2, tnum | secondary | `:496-509` |
| Player control labels | caption2 500 (min scale 0.5) | accent if active, else secondary | `:674-682` |
| Back-to pill | caption 500 (icon caption) | accent | `:229-232` |
| Mini-player line 1 / 2 | subheadline 600 / caption | primary / secondary | `MiniPlayerView.swift:123-131` |
| Speed title / value / preset | headline / title2 600 tnum / subheadline (600 selected) tnum | primary; value accent unless 1× | `PlaybackSpeedControl.swift:21,61-65,112-114` |
| Sleep items | body; checkmark caption | primary; Cancel red | `PlayerView.swift:696-743` |
| Toast "Bookmarked at …" | subheadline 500 | primary | `PlayerView.swift:167-168` |
| DeNoise toggle / description | headline / subheadline | primary / secondary | `AudioEnhancementView.swift:33-38` |
| DeNoise status | caption 500 | orange if issue, else secondary | `:49,55` |
| Mode label name / detail / battery | headline / subheadline / caption 500 | primary / secondary / accent (Best Quality) or secondary | `:283-296` |
| Transcript row | `fontSize`, 600 if current; serif italic if emphasis | see §6.12 | `TranscriptView.swift:374-377` |
| Transcript nav title / subtitle | headline / caption | primary / secondary | `:789-795` |
| Transcript chip | footnote 500 | accent | `:592` |
| Now-playing pill | subheadline 600 | white on accent | `:630` |
| Search counter | footnote tnum | secondary | `:921` |
| Transport times | caption tnum | secondary | `:964` |
| Queue title / series / index | subheadline (600 current) / caption / subheadline tnum | accent if current / secondary / secondary | `QueueView.swift:49-64` |
| Downloads series header | subheadline 600 / caption2 | primary / secondary | `DownloadsView.swift:385-390` |
| Downloads row number / title / size | caption / body / caption2 tnum | secondary / accent if current / secondary | `:437-455` |
| Activity rows | body; subtitle caption | primary / secondary | `:184-207` |
| Bookmark chip | subheadline 500; icon caption2 | white / primary | `BookmarksView.swift:108-111` |
| Bookmark row title / tag / time / note | subheadline / caption2 / caption tnum / caption (2 lines) | primary (blue if playing) / accent / secondary / secondary | `BookmarksView.swift:134-164` |
| Stat value / label | title bold / caption; icon title2 | primary / secondary | `ListeningStatsView.swift:132-141` |
| Stat rows | body; value tnum secondary | | `:170-176` |
| Settings About link rows | subheadline; trailing caption2 | primary (Support = accent) | `SettingsView.swift:305-311` |
| More Apps name / subtitle | subheadline / caption | primary / secondary | `:242-247` |
| Tip product name / kind / price | body / caption / subheadline 600 tnum | primary / secondary / accent | `TipJarView.swift:219-238` |
| Waiting notice title / body | subheadline 600 / footnote | primary / secondary | `DownloadWaitingNotice.swift:14-19` |

## 3. Spacing, radii and sizes

### 3.1 Corner radii

| Element | Radius | Style |
| --- | --- | --- |
| Thumbnails (all sizes) | 12 | |
| Home Continue/Completed cards | 12 | |
| Home support card | 16 | continuous |
| Home shelf card | 8 | |
| Player artwork | 16 | |
| Mini-player | 14 | |
| Mini-player artwork | 6 | continuous |
| Download All button | 10 | |
| Speed preset | 10 | continuous |
| Transcript search field | 10 | |
| Transcript row background | 14 | |
| Transcript current-row bar | 2 (3 wide) | |
| Series waiting-notice card | 12 | continuous |
| Add Bookmark category button | 8 | |
| More Apps icon | 9 (40 dp icon) | |
| Chips, pills, toasts, GET, prices, Now-playing | capsule (50 %) | |
| Inset-grouped list section (iOS 26, observed) | ≈ 22 | Use 22 dp. iOS 18 used 10. |
| Sheets top corners (iOS 26, observed) | ≈ 28 | |
| Popover / menu (observed) | ≈ 20 | |

Continuous corners (squircle) are drawn as ordinary `RoundedCornerShape`. The
difference is not visible at these sizes.

### 3.2 Layout numbers per component

| Component | Numbers | File |
| --- | --- | --- |
| Screen side margin | 16 | default `.padding()` |
| Home stack | spacing 18; top 12; bottom 16 | `HomeView.swift:38,78-79` |
| Home section | header-to-card 10; card inner padding horizontal 16, outer horizontal 16; max width 672 (640+32) | `:176,255-264` |
| Continue header | thumb 32, gap 10, text gap 2, top 12 / bottom 4 | `:543-564` |
| Continue row | gap 12, title-to-bar 6, bar 3 high (capsule), vertical padding 8 | `:597-648` |
| Dismiss × | glyph 10 + padding 6 → ≈ 22 circle; hit area 44 × 44 | `:231-239` |
| Recently Completed row | thumb 48, gap 12, text gap 4, vertical padding 8; divider inset 68 | `:201-251` |
| Shelf | section title-to-row 8; card gap 8; card padding horizontal 10 / vertical 8; thumb 36, gap 8, text gap 1 | `:330-435` |
| Support card | padding 16; text-to-buttons 8; button gap 12; max width 640 | `HomeSupportCard.swift:44-58` |
| Library chips bar | chip gap 6; chip padding 12 × 6; sort chip padding 10 × 6, icon-text 3; bar top 8, bottom 8 | `LibraryView.swift:215-267,167` |
| Library row | padding horizontal 16 / vertical 9; thumb 48; gap 12; text gap 3; meta gap 6; divider inset 72. Height ≈ 66 | `:278-310,176` |
| Series header | vertical padding 24; thumb 120 (shadow primary 10 %, r 20); stack gap 16; text gap 6; description block top 8, side 16, gap 8; theme chips flow gap 4, chip padding 8 × 3, max 5 chips | `SeriesDetailView.swift:76-151` |
| Download All | icon-text 8; vertical 12; full width; outer horizontal 16, bottom 20 | `:231-256` |
| Discourse row | padding horizontal 16 / vertical 10; number column 28 wide; badge offset (+10, −8); gap 12; title gap 2; divider inset 52 | `:320-376,284` |
| Download ring | 28 × 28; line 2.5, round cap; starts at top (−90°) | `:551-577` |
| GET pill | padding 10 × 6 | `:506-507` |
| Player column | side padding 16 if width < 380 else 24; tight = height < 700 | `PlayerView.swift:196-197` |
| Player vertical | handle 36 × 5 at top 8; top bar top 8; Spacer; artwork; Spacer; track info (gap 4); back pill top 12; seek top 12 (tight) or 24; transport top 12 or 24; bottom controls top 16 or 32; status top 8; Spacer | `:199-264` |
| Player artwork | `max(150, min(280*scale, width − 48, height × 0.34))` | `:306-314` |
| Player top bar | AirPlay 44 × 44; queue 44 × 44; gap 8 | `:346-386` |
| Player seek | slider-to-times 6 | `:467` |
| Player transport | 5 equal groups with flexible gaps (min 8); side glyphs title2 | `:536-597` |
| Player control button | icon 18 in a 22-high frame; gap 4; label padding horizontal 4; vertical 8; 5 equal columns | `:668-685` |
| Back pill | padding 12 × 6, icon-text 6 | `:228-238` |
| Toast | padding 16 × 10; top 60 (player) or 8 (+48 when searching) in the transcript | `PlayerView.swift:169-173`, `TranscriptView.swift:249-252` |
| Mini-player | progress 2.5 high at top edge; row padding 12 × 8; artwork 44; gap 12; play 44 × 44; outer horizontal 8; max width 640. Total height ≈ 62.5 (64 assumed before it is measured) | `MiniPlayerView.swift:43-60`, `ContentView.swift:25` |
| Mini-player position | bottom offset = (tab bar height) + 6 (fallback 56 + 6) | `ContentView.swift:119-122` |
| Scroll clearance | every scrolling tab page adds bottom inset `miniHeight + 6 + 12` while a track exists | `ContentView.swift:114-117,283-291` |
| Speed popover | padding 16; width 300 (320 stacked); row gap 16; −/slider/+ gap 8; preset gap 6; step buttons 44 × 44; presets min height 44 | `PlaybackSpeedControl.swift:18-51` |
| Sleep popover | width 160; vertical padding 8; item gap 4; item padding 16 × 10 | `PlayerView.swift:689-753` |
| Queue row | lead column 24; gap 12; text gap 2; vertical 4 | `QueueView.swift:40-70` |
| Add Bookmark grid | adaptive min 100; spacing 10; button vertical padding 8; icon-text 6; grid vertical padding 4 | `AddBookmarkSheet.swift:59-83` |
| Transcript column | horizontal 16; top 8; max width 720; row gap 4; trailing spacer 240; follow anchor 35 % from top | `TranscriptView.swift:321-336` |
| Transcript row | top 10 (paragraph start) or 3; bottom 10 (paragraph end) or 3; horizontal 12; text-to-chips 10; checkbox-text 10; line spacing `fontSize × 0.28` | `:364-402` |
| Transcript chips | gap 8; chip padding 12 × 8 | `:453-597` |
| Now-playing pill | padding 16 × 10; bottom 12 | `:221,631-632` |
| Search bar | padding 16 × 8; gap 10; field padding 10 × 8; icon-field gap 6 | `:899-939` |
| Transport bar | padding horizontal 20, top 8, bottom 6; progress-to-row 8; button gap 28; play 44 × 44; time min width 64 | `:958-996` |
| Selection bar | padding 16 × 4; gap 4; icon buttons 44 min | `:553-579` |
| Alignment row | padding 16 × 10; gap 12; progress max width 140 | `:1003-1028` |
| Downloads multi-select bar | padding 20 × 12 | `DownloadsView.swift:160-161` |
| Downloads header | thumb 32, gap 10, text gap 2, vertical 4; ellipsis leading 8, vertical 4 | `:378-414` |
| Downloads row | number column 24; gap 12 | `:436-440` |
| Redownload / in-progress row | text gap 2 / 4; ring 26 × 26 | `:550-577,620` |
| Bookmarks chips | gap 8; chip padding 12 × 7; icon-text 5; bar padding 16 × 10 | `BookmarksView.swift:48-117` |
| Bookmark row | gap 12; text gap 4; tag padding 6 × 2, icon-text 3; tag-time gap 6; vertical 4; trailing spinner 28 | `:132-197` |
| Stats overview | grid rows gap 20; vertical 8; card gap 8 | `ListeningStatsView.swift:40-70,131` |
| Settings swatches | circle 27 + padding 3 = 33; ring 2 (accent, selected); gap 10; horizontal scroll | `SettingsView.swift:152-185` |
| Settings link row | vertical padding 2 | `:313` |
| More Apps row | icon 40; gap 12; text gap 2; vertical 2 | `:230-254` |
| Tip jar header | gap 10; vertical 6 | `TipJarView.swift:26-35` |
| Tip row | min height 44; text gap 2; price padding 12 × 6 | `:218-241` |
| Waiting notice | gap 8. In Series it is a card: padding 16, horizontal 16, bottom 8 | `DownloadWaitingNotice.swift:9`, `SeriesDetailView.swift:33-38` |
| Launch | lotus 132 × 132; gap 22; stack centred | `LaunchView.swift:20-31` |

### 3.3 System chrome (iOS 26, measured from screenshots; build these in `:core:ui`)

| Element | Value |
| --- | --- |
| Large-title nav bar | Title 34 bold, left-aligned at 16 (screenshots ≈ 20). Collapses to an inline 17/600 centred title on scroll. Bar 44 + title 52. |
| Inline nav bar | Height 44. Centred title 17/600. Toolbar buttons are 44 dp glass circles (icons) or glass capsules (text, e.g. "Done", 17 regular). |
| Back button | 44 dp glass circle, chevron-left ≈ 20 dp, primary colour. |
| Search field | Under the large title. Capsule, height ≈ 48. Fill `tertiarySystemFill`. Leading magnifier 17 secondary. Placeholder 17 `placeholderText`. Gap 8. |
| Tab bar | Floating glass capsule ≈ 62 high, side inset ≈ 20, bottom over the gesture area. 4 equal items: icon ≈ 24 + label 10/600, vertical gap 2. Selected item: accent icon and label on a pill highlight (light `#000000` @ 6 %, dark `#FFFFFF` @ 12 %). Unselected: primary. Icons are always **filled**. |
| Inset-grouped list | Side inset 16 (≈ 20 observed). Row min height 44 (≈ 52 on iOS 26). Row text padding 16. Section gap ≈ 24. Header 17/600 secondary, about 6 above the card. Footer 13 secondary, 6–8 below. Divider inset at the text start. |
| Switch | ≈ 64 × 28 (iOS 26), white thumb, accent track when on, `systemFill` track when off, no icon, no outline. |
| Segmented control | Height ≈ 36, capsule track `tertiarySystemFill`. Selected thumb is a capsule: light `#FFFFFF` with shadow, dark `#636366`. Labels 13/500. |
| Slider | Track 4–6 high, active accent, inactive `systemFill`. Thumb is a white capsule ≈ 38 × 24 with shadow (iOS 26; iOS 18 used a 28 circle). |
| Progress bar (linear) | 4 high, accent on `systemFill`. The transcript transport scales it to 0.6 high (≈ 2.4). |
| Spinner | `CircularProgressIndicator`, 20 (`controlSize(.small)` ≈ 16), gray `secondaryLabel`. |

## 4. Iconography (SF Symbols → Material Symbols)

Use **Material Symbols Rounded**: weight 400, optical size 24, `FILL = 1` for SF
`.fill` names and `FILL = 0` otherwise. Default size: the SwiftUI font size in §2. Where
nothing is given, use 20 dp in rows and 24 dp in bars.

| SF Symbol | Material Symbol | Fill | Where |
| --- | --- | --- | --- |
| `house.fill` | `home` | 1 | Tab Home |
| `books.vertical` (shown filled in tab bar), `books.vertical.fill` | `library_books` (alt `shelves`) | 1 | Tab Library; "Series Done" stat |
| `arrow.down.circle` (tab shows `.fill`) | `arrow_circle_down` | 1 in tab, 0 elsewhere | Tab Downloads; Download (context menu); bookmark row "Download"; empty Downloads |
| `arrow.down.circle.fill` | `arrow_circle_down` | 1 | Download All |
| `gearshape` (tab shows `.fill`) | `settings` | 1 | Tab Settings |
| `bookmark` / `bookmark.fill` | `bookmark` | 0 / 1 | Player control, context menu, empty Bookmarks / Bookmarks row icon, "All" chip |
| `bookmark.slash` | `bookmark_remove` | 0 | Empty filtered bookmarks |
| `play.fill` / `pause.fill` | `play_arrow` / `pause` | 1 | Mini-player, transcript transport, "Play from here", queue (paused current) |
| `play.circle.fill` / `pause.circle.fill` | `play_circle` / `pause_circle` | 1 | Player main button, row play buttons |
| `play.circle` | `play_circle` | 0 | DeNoise status "Ready for playback" |
| `play` / `pause` | `play_arrow` / `pause` | 0 | Context-menu Play/Pause |
| `backward.fill` / `forward.fill` | `fast_rewind` / `fast_forward` | 1 | Player Previous / Next |
| `gobackward.15` | custom: `replay` + "15" (no `replay_15` exists) | 0 | Player, transcript transport |
| `goforward.30` | `forward_30` | 0 | Player, transcript transport, (accessory mini-player) |
| `speedometer` | `speed` | 0 | Player Speed control |
| `waveform` | `graphic_eq` | 0 | Player DeNoise control; Settings DeNoise row; queue current (animated) |
| `exclamationmark.triangle` | `warning` | 0 | Player DeNoise control when there is an issue |
| `exclamationmark.circle` | `error` | 0 | DeNoise status (issue) |
| `checkmark.circle.fill` | `check_circle` | 1 | Completed, DeNoise active, selected option, picked row, Mark All Complete, Discourses Done, history row |
| `checkmark.circle` | `check_circle` | 0 | Mark as Complete, Select, Select Passages, chip "Select" |
| `circle` | `radio_button_unchecked` | 0 | Unselected option / row |
| `checkmark` | `check` | 0 | Sleep and menu checks, swatch |
| `xmark` | `close` | 0 | Dismiss ×, transcript Close |
| `xmark.circle` | `cancel` | 0 | Mark (All) Incomplete |
| `xmark.circle.fill` | `cancel` | 1 | Cancel download (in-progress row), clear search |
| `stop.fill` | `stop` | 1 | Centre of download ring |
| `exclamationmark.arrow.circlepath` | `sync_problem` | 0 | Retry download |
| `trash` | `delete` | 0 | Remove Download, Delete All, Delete All in Series |
| `ellipsis.circle` | `more_horiz` inside a 44 dp glass circle (alt `pending`) | 0 | Series and Downloads toolbar "More options" |
| `ellipsis` | `more_horiz` | 0 | Downloads series header menu |
| `chevron.right` | `chevron_right` | 0 | Row disclosure, player series link |
| `chevron.up` / `chevron.down` | `keyboard_arrow_up` / `keyboard_arrow_down` | 0 | Sort direction, search prev/next |
| `chevron.down` (close) | `keyboard_arrow_down` | 0 | Full-window player close (iPad only) |
| `list.bullet` | `format_list_bulleted` | 0 | Player Up Next |
| AirPlay route picker (`AVRoutePickerView`, glyph `airplayaudio`) | `speaker_group` (alt `cast`), accent | 0 | Player top-left; opens the Android output switcher |
| `doc.plaintext` | `description` | 0 | Transcript control, transcript-available marks, empty states |
| `doc.on.doc` | `content_copy` | 0 | Copy |
| `character.cursor.ibeam` | `text_fields` (alt `select_all`) | 0 | Select Text |
| `square.and.arrow.up` | `share` (Android convention; `ios_share` if strict parity is wanted) | 0 | Share |
| `scope` | `my_location` | 0 | "Audio is here", Clear sync anchors |
| `magnifyingglass` | `search` | 0 | Transcript search, search fields, no results |
| `textformat.size` | `format_size` | 0 | Transcript options menu |
| `textformat.size.smaller` / `.larger` | `text_decrease` / `text_increase` | 0 | Text size |
| `text.justify.leading` | `format_align_justify` | 0 | One sentence per line |
| `text.alignleft` | `format_align_left` | 0 | Select Whole Paragraph |
| `arrow.up.and.down.text.horizontal` | `expand` | 0 | Select Up to Here |
| `waveform.badge.magnifyingglass` | `graphic_eq` | 0 | Speech sync toggle (hidden on Android v1) |
| `arrow.clockwise` | `refresh` | 0 | Redo speech sync |
| `safari` | `explore` | 0 | Open on oshoworld.com |
| `arrow.down` / `arrow.up` | `arrow_downward` / `arrow_upward` | 0 | Now-playing pill |
| `arrow.uturn.backward` | `undo` | 0 | "Back to m:ss" pill |
| `moon` / `moon.fill` | `bedtime` | 0 / 1 | Sleep control (off / active) |
| `clock` | `schedule` | 0 | Add Bookmark timestamp; purchase pending |
| `music.note` | `music_note` | 0 | Add Bookmark title row |
| `minus` / `plus` | `remove` / `add` | 0 | Speed step |
| `hourglass` | `hourglass_empty` | 0 | DeNoise "Getting ready…" |
| `battery.50percent` | `battery_horiz_050` | 0 | DeNoise battery note |
| `chart.bar.fill` | `bar_chart` | 1 | Listening Stats row |
| `infinity` | `all_inclusive` | 0 | All Time stat |
| `flame.fill` | `local_fire_department` | 1 | Streak stat |
| `cup.and.saucer.fill` | `coffee` | 1 | Support Development, tip jar header |
| `star` / `star.fill` | `star` | 0 / 1 | Rate Osho Talks / Awesome category |
| `chevron.left.forwardslash.chevron.right` | `code` | 0 | Source Code |
| `envelope` | `mail` | 0 | Send Feedback |
| `arrow.up.right` | `arrow_outward` | 0 | External link rows |
| `heart` | `favorite` | 0 | Yearly support thank-you |
| `wifi` / `wifi.slash` | `wifi` / `wifi_off` | 0 | Waiting notice |
| `arrow.counterclockwise` | `replay` | 0 | Category Re-listen |
| `face.smiling` | `sentiment_satisfied` | 0 | Category Funny |
| `brain.head.profile` | `psychology` | 0 | Category Profound |
| `figure.mind.and.body` | `self_improvement` | 0 | Category Meditation |
| `tag` | `sell` | 0 | Category Custom |
| `applewatch` | — (Watch is out of scope) | | |
| Nav back chevron (system) | `arrow_back_ios_new` in a 44 dp glass circle | 0 | All pushed screens |

Custom `gobackward.15`: draw `replay` (24 dp) with "15" centred. Use 8 sp at weight 700,
offset 1 dp down. Use one shared `ReplayFifteenIcon` composable for both the player and
the transcript.

## 5. Navigation structure

### 5.1 Tabs (`Views/AppNavigation.swift:5-32`, `ContentView.swift:126-162`)

| Order | Title | Icon | Root | Default |
| --- | --- | --- | --- | --- |
| 1 | Home | `house.fill` | `HomeView` | ✓ selected at launch |
| 2 | Library | `books.vertical` | `LibraryView` | |
| 3 | Downloads | `arrow.down.circle` | `DownloadsView` | |
| 4 | Settings | `gearshape` | `SettingsView` | |

Bookmarks is a tab only in the iPad sidebar. On phones it is a row inside Downloads,
and `select(.bookmarks)` maps to Downloads (`AppNavigation.swift:68-72`). Each tab has
its own back stack, which is kept when you switch tabs.

### 5.2 Destinations

| From | Action | Destination | Kind |
| --- | --- | --- | --- |
| Home | Series card, Continue header, Recently Completed row | Series detail | push |
| Library | Row | Series detail | push |
| Downloads | Series section header | Series detail | push |
| Downloads | "Listening Stats" row | Listening Stats → "Full Listening History" → Listening History | push, push |
| Downloads | "Bookmarks" row | Bookmarks (large title) | push |
| Settings | "DeNoise" row | DeNoise → "Listening Mode" / "Fine-tune the voice" (Quiet Speech) | push, push |
| Settings | "Support Development" | Tip jar | sheet (full height) |
| Home | Support card "Support" | Tip jar | sheet |
| Any tab | Mini-player tap | Player | sheet (large, swipe down to close) |
| Player | Series title | Closes the player, selects Home, resets the Home stack, pushes Series (`AppNavigation.swift:102-106`, `HomeView.swift:93-98`) | tab switch + push |
| Player | Up Next | Queue | sheet, detents medium + large |
| Player | DeNoise | DeNoise inside its own stack with "Done" | sheet, large, drag indicator |
| Player | Transcript button / artwork tap | Transcript | sheet, large, drag indicator |
| Player | Bookmark | Add Bookmark | sheet, medium |
| Player | Speed | Speed control | popover (stays a popover on iPhone) |
| Player | Sleep | Sleep timer | popover (stays a popover on iPhone) |
| Series row context menu | Read Transcript | Transcript | sheet, large |
| Series / Downloads row context menu | Add Bookmark… (current track only) | Add Bookmark (stacks over the player if it is open) | sheet, medium |
| Transcript | Select Text | Select Text | sheet (full) |
| Tip jar | Manage Subscriptions | System manage-subscriptions sheet | system |

### 5.3 Toolbars

| Screen | Title (mode) | Leading | Trailing |
| --- | --- | --- | --- |
| Home | "Home" (large) | — | — |
| Library | "Library" (large) + search "Search by name or topic" | — | — |
| Series detail | series name (inline) | back | Menu `ellipsis.circle` (a11y "More options"): "Mark All Complete" (`checkmark.circle.fill`), "Mark All Incomplete" (`xmark.circle`, destructive) |
| Downloads | "Downloads" (large) + search "Search downloads" | — | Only when the filtered list is not empty. Normal: Menu `ellipsis.circle` "More options": "Select" (`checkmark.circle`), "Delete All" (`trash`, destructive). Edit mode: "Done". |
| Bookmarks | "Bookmarks" (large) | back | — |
| Listening Stats | "Listening Stats" (inline) | back | — |
| Listening History | "Listening History" (inline) | back | — |
| Settings | "Settings" (large) | — | — |
| DeNoise | "DeNoise" (inline) | back (from Settings) | "Done" (player sheet only, confirmation placement) |
| Listening Mode | "Listening Mode" (inline) | back | — |
| Quiet Speech | "Quiet Speech" (inline) | back | — |
| Player | none (custom top bar) | AirPlay | Up Next |
| Queue | "Up Next" (inline) | — | "Done" |
| Add Bookmark | "Add Bookmark" (inline) | "Cancel" | "Save" |
| Transcript | Principal, 2 lines: series name (headline, 1 line) / "Discourse N" (caption, secondary). Falls back to "Transcript". | `xmark` (a11y "Close") | `magnifyingglass` (a11y "Search transcript", disabled with no transcript), `textformat.size` menu (a11y "Transcript options") |
| Select Text | "Select Text" (inline) | "Copy All" → "Copied" for 2 s | Share icon, "Done" |
| Tip jar | "Support Development" (inline) | "Done" | — |

## 6. Per-screen inventory

String conventions: `<N>` = number, `<series>` = series name, `“…”` = verbatim curly
quotes in source. Time format everywhere is `m:ss`, or `h:mm:ss` when ≥ 1 h. Invalid or
negative time shows `0:00`. A discourse title (`displayTitle`) is `"<series> - #<N>"`
(`Resources/Catalog.swift:61-63`).

### 6.1 Home (`Views/Home/HomeView.swift`, `HomeSupportCard.swift`)

Background `systemGroupedBackground`. Large title "Home". Vertical scroll, top to bottom:

1. **Continue Listening** section. Shown when there are items. Items come from recently played discourses that are downloaded and have position > 0 or are the current track. Up to 8 are counted for Clear All, and only the first 4 are shown, grouped by series in first-appearance order.
   - Header row: "Continue Listening" + "Clear All" button (accent @ 60 %, 44 hit area). Clear All dismisses every item, animated.
   - Card (`secondarySystemGroupedBackground`, r 12). For each group: header (thumb 32, series name, `"<count> discourses · <k> in progress"`, chevron). Tapping the header opens the series (a11y hint "Opens the series"). Then the rows: "Discourse <N>" plus a 3 dp progress capsule (live for the current track). Then a play/pause circle (a11y "Play"/"Pause"). Then the dismiss × (a11y "Remove from Continue Listening"). Tapping the row or the button plays the series' downloaded discourses as a queue starting here, or toggles play/pause if it is the current track. A full-width divider separates groups.
2. **Recently Completed**. Up to 6, from the listened-completed list.
   - Header "Recently Completed" + "Clear All".
   - Card rows: thumb 48 / "Discourse <N>" (600) / series name (2 lines) / green `checkmark.circle.fill` / dismiss × (a11y "Remove from Recently Completed"). Tapping the row pushes the series. Dividers are inset 68 between rows.
3. **Support card** (`HomeSupportCard`). Visibility comes from `EngagementService` rules, not style. Text "Optional support helps me keep improving Osho Talks." Buttons: "Support" (600), "Not Now", "Don't Ask Again". They sit in one row, or a column when they do not fit. Support opens the Tip jar sheet.
4. Shelves, filtered by the content-language setting: "Popular in English", "Beginner Friendly (English)", "Popular in Hindi", "Beginner Friendly (Hindi)". The title is a header for accessibility. Each shelf is a horizontal scroll with no indicator. Card: thumb 36, name (caption 500, 1 line), `"<count> discourses"`. Tapping pushes the series.

Empty state: none. A new user sees only the shelves. Animations: removals use default `withAnimation`. The rows have no haptics.

### 6.2 Library (`Views/Library/LibraryView.swift`)

Background `systemBackground`. Large title "Library". Search prompt "Search by name or topic". The search matches name, description and themes, lowercase, as a substring.

1. Chips row (horizontal scroll, no indicator): "All", then "English" and "Hindi" (only when both languages are visible), then "Downloaded" (when any visible series has a download), then theme chips. A theme chip appears when ≥ 3 visible series share the theme. Themes are lowercased and sorted, the "hindi" and "english" themes are skipped, and the label is `capitalized`. Tapping the active chip returns to All (easeInOut 0.2 s). When the active filter disappears, it falls back to All.
   - Then the sort Menu chip: a chevron (up = ascending) + field name. Menu items: "Name", "Episodes". The current field shows a chevron. Tapping the current field flips the direction. A new field starts ascending. A11y label "Sort", value `"<Name|Episodes>, <ascending|descending>"`.
2. Rows: thumb 48 / name (1 line) / `"<count> discourses"` · `"Hindi"|"English"` / chevron. Dividers are inset 72 after **every** row, including the last.
3. No results (only while searching): system `ContentUnavailableView.search(text:)`. Shows magnifier, title `No Results for “<query>”`, description `Check the spelling or try a new search.`, 40 top padding.

Default sort: Name ascending. Filter and sort are not persisted.

### 6.3 Series detail (`Views/Series/SeriesDetailView.swift`)

Background `systemBackground`. Inline title = series name. Toolbar menu as in §5.3.

1. Header, centred: thumbnail 120 with a soft shadow. Name (title2 bold). `"<count> discourses"` · `"Hindi"|"English"` (language in accent). `"<done>/<count> completed"` (green, when > 0). `doc.plaintext` label `"Transcripts for every discourse"` or `"Transcripts for <k> of <count>"` (when > 0). Description (4 lines). `"<location>, <year>"`. Up to 5 theme chips in a wrapping flow.
2. **Download All** button: `arrow.down.circle.fill` + "Download All" + `"(<remaining> · <size>)"` when remaining > 0. Size uses 20 MB per Hindi discourse and 30 MB per English one. ≥ 1000 MB shows `"~%.1f GB"` (÷1000), otherwise `"~<n> MB"`. Tapping opens a confirmation dialog:
   - Title `"Download <remaining> discourses?"` (title is visible).
   - Message `"This will download <remaining> discourses using approximately <size> of storage."`
   - Buttons: `"Download <remaining> (<size>)"` and "Cancel" (cancel role).
3. Waiting notice card when this series has an active download that is waiting on the network (§6.18).
4. Discourse rows (dividers inset 52, none after the last):
   - Left: the number (subheadline, secondary) in a 28 column, with a green 10 sp completed badge at (+10, −8) (a11y "Completed").
   - Title "Discourse <N>" (body; system blue while playing). `doc.plaintext` caption2 tertiary when a transcript exists (a11y "Transcript available").
   - Status line (caption2), in priority order: failure message (red, wraps) › waiting label "Waiting for Wi-Fi" / "Waiting for a connection" › `"Downloading..."` for 2 s after tapping a row that is not downloaded (opacity transition).
   - Trailing action:
     - Downloading or queued: ring with stop square, or a small spinner when queued. Tap cancels (a11y "Cancel download", value "Queued" or `"<p> percent"`).
     - Failed: `exclamationmark.arrow.circlepath` red (a11y "Retry download").
     - Downloaded: play/pause circle accent (a11y "Pause"/"Play").
     - Else: pill `"GET ~20 MB"` (Hindi) / `"GET ~30 MB"` (English).
   - Row tap: plays the series' downloaded discourses as a queue starting here. If not downloaded, it starts the download and shows the hint.
   - A11y: the row is a button, label `"Discourse <N>[, completed][, transcript available]"`, hint "Plays this discourse" or "Downloads this discourse".
   - Context menu (long press), in order:
     - "Play"/"Pause" (`play`/`pause`) when downloaded, or "Download" (`arrow.down.circle`) when not downloaded and not downloading.
     - "Add Bookmark…" (`bookmark`), only for the current track.
     - "Read Transcript" (`doc.plaintext`) when a transcript exists.
     - "Mark as Incomplete" (`xmark.circle`) or "Mark as Complete" (`checkmark.circle`).
     - Divider + "Remove Download" (`trash`, destructive) when downloaded.

Download failure messages (`Services/DownloadService.swift:46-57`), shown verbatim:
`Wi-Fi only. Turn on "Download over Cellular" in Settings.` · `Not available on the server (404).` · `Server error (HTTP <code>).` · `Server returned a web page, not audio.` · `No internet connection.` · `Not enough storage on your device.` · `Downloaded, but couldn't be saved. Try again.` · `The download stopped responding. Check your connection and try again.`

### 6.4 Player (`Views/Player/PlayerView.swift`)

Presentation: sheet, large, swipe down to close. The system drag indicator is hidden.
Background `systemBackground` (elevated). Single column, vertically scrollable when the
text is large, with min height = screen. Top to bottom:

1. Drag handle: a 36 × 5 capsule, secondary @ 50 %, top 8. Accessibility-hidden.
2. Top bar: AirPlay route button (accent, 44, a11y "AirPlay and output device") … Up Next `list.bullet` (title3, 44, a11y "Up Next", hint "Shows the playback queue"). Up Next is disabled and drawn at opacity 0.35 when the queue has ≤ 1 item.
3. Flexible space.
4. Artwork: the bundled `OshoPortrait` image, square, size per §3.2, r 16, glow shadow. Tapping it opens the transcript when one exists.
5. Flexible space.
6. Track info, centred:
   - Series name (title3 bold, 2 lines) + `chevron.right` (caption 600, secondary). It is a button that opens the series (a11y label = name, hint "Opens the series"). Fallback text "Not Playing", or the current title when the series name is empty.
   - Subtitle `"Discourse <N>"` or `"Discourse <N> · <location>, <year>"` (`Resources/SeriesMetadata.swift:30-38`).
7. Back pill, shown only after a jump with history: `arrow.uturn.backward` + `"Back to <m:ss>"`, accent on accent @ 15 %.
8. Seek slider, accent (a11y "Playback position", value `"<t> of <duration>"`). Below it: elapsed time left; right `"-<remaining>"`, or the total when toggled. Tapping the right label toggles it (a11y "Time remaining"/"Total time", hint "Switches between time remaining and total time"). Releasing a scrub calls `seekWithHistory`, which enables the Back pill.
9. Transport row:
   - `backward.fill` "Previous". Disabled when there is no previous item and elapsed ≤ 3 s.
   - `gobackward.15` "Skip back 15 seconds".
   - Play/pause circle fill, large, primary colour, "Pause"/"Play". Pausing triggers the review-prompt hook.
   - `goforward.30` "Skip forward 30 seconds".
   - `forward.fill` "Next". Disabled when there is no next item.
   - All primary colour (not accent).
10. Bottom controls, 5 equal columns, icon over label. The label is accent when active, else secondary:

| # | Icon | Label | Active when | A11y label / value / hint |
| --- | --- | --- | --- | --- |
| 1 | `speedometer` | speed label, e.g. "1×", "1.25×" | rate ≠ 1 | "Playback speed" / `"<x> times"` |
| 2 | `waveform`, or `exclamationmark.triangle` on issue | "DeNoise" | processing status is active | "DeNoise" / e.g. `"On, Best Quality, Medium noise reduction, quiet speech Gentle Lift. Enhancement is on"` or "Off" / "Adjusts noise reduction, quiet speech and volume boost" |
| 3 | `doc.plaintext` | "Transcript" | (iPad pane only) | "Transcript" / hint "Reads along with the playing audio" or "No transcript for this discourse". Disabled at 0.35 when there is no transcript. |
| 4 | `moon` / `moon.fill` | "Sleep", countdown `"m:ss"`, or "End" | timer on | "Sleep timer" / status label or "Off" |
| 5 | `bookmark` | "Bookmark" | never | "Add bookmark" / hint "Saves the current position". Captures the time immediately. |

11. DeNoise issue text (caption, orange, centred) when DeNoise is on and the status is an issue. It shows the status label (§6.9).

Overlay: toast `"Bookmarked at <m:ss>"` after a bookmark is saved. It sits at the top + 60, slides in from the top with a fade, and auto-hides after 2 s (easeInOut).

### 6.5 Mini-player (`Views/Player/MiniPlayerView.swift`)

Shown on every tab while `currentTrackId != nil`. It floats above the tab bar (§3.2).
Glass rounded rectangle r 14 with a shadow:
- Top edge: 2.5 dp progress. Fill accent, track primary @ 8 %. Clipped by the corners.
- Row: artwork 44 (r 6) · titles · spacer · play/pause (`play.fill`/`pause.fill`, title3, accent, 44 × 44, a11y "Play"/"Pause").
- Titles: line 1 is `"Discourse <N>"`. N is parsed from the text after the last `#` in the current title, and it must be all digits. Line 2 is the series. If N cannot be parsed: a single line with the series name, or the title when the series is empty.
- Tapping anywhere opens the Player. A11y: a combined element, value "Playing"/"Paused", button trait, hint "Opens the full player".
- No animation of its own. It appears and disappears with the track.

### 6.6 Speed control (`Views/Player/PlaybackSpeedControl.swift`, `Services/PlaybackSpeed.swift`)

A popover anchored to the Speed button. Range 0.5–2.0, step 0.05. Presets 0.75, 1, 1.25, 1.5, 2.
- Label: the number with 0–2 fraction digits (locale formatted) + "×". Examples: "0.75×", "1×", "1.1×", "2×". A11y form: `"<n> times"`.
- Normal layout: Row "Speed" (headline) … value (title2 600 tnum; primary at 1×, else accent; numeric content transition). Row: − button · slider · + button. Row: 5 presets.
- Stacked layout (accessibility sizes, width 320): "Speed" + value stacked; slider; −/+ row; presets in a 2-column grid.
- − and + are 44 × 44, auto-repeat while held. A11y "Slower"/"Faster". Disabled at the bounds.
- Preset: selected uses accent @ 18 % with accent text at 600, else `tertiarySystemFill` with primary text. A11y label `"<n> times"`, selected trait.
- Haptic: a selection tick on every change of the displayed rate (`.sensoryFeedback(.selection)`).

### 6.7 Sleep timer (`PlayerView.swift:689-754`, `Services/SleepTimerService.swift`)

A popover anchored to the Sleep button, width 160. Items, each body text with a trailing
caption checkmark when active:
- "End of discourse". Checked in end-of-discourse mode.
- Divider.
- "5 min", "10 min", "15 min", "30 min", "45 min", "60 min". In countdown mode the item with `ceil(remaining/60) == minutes` is checked.
- When a timer is active: Divider + "Cancel" (red).

Tapping any item applies it and closes the popover. Control label: "Sleep" when off,
`"m:ss"` while counting down, "End" in end-of-discourse mode.

### 6.8 Add Bookmark (`Views/Player/AddBookmarkSheet.swift`)

There is no edit UI on iOS. Bookmarks can only be added or deleted. Sheet, medium detent.
Inline title "Add Bookmark". "Cancel" / "Save". It is a Form:
1. Section: `clock` (blue) "Timestamp" … time (secondary, tnum). Then `music.note` (blue) + title (1 line). The time is captured when the sheet was requested.
2. Section "Category": adaptive grid (min 100). Buttons "Re-listen", "Funny", "Awesome", "Profound", "Meditation", "Custom", each with its icon (§4). Default Re-listen. Selected: blue @ 20 % with blue text; else `tertiarySystemFill` with primary text. When Custom is selected, a TextField "Custom category name" appears.
3. Section "Note (optional)": a multi-line TextField "What caught your attention?", 3–6 lines.

Save adds the bookmark, dismisses, and the player shows its toast.

### 6.9 DeNoise (`Views/Player/AudioEnhancementView.swift`, `Services/UserSettings.swift:31-93`, `Services/AudioPlayerService.swift:40-139`)

A Form. Inline title "DeNoise". The accent tints the toggle and the pickers.

1. Section: Toggle "Enable DeNoise" (headline) + "Reduce recording noise and make quiet audio easier to hear." (subheadline, secondary).
   - Footer: status icon + label (caption 500), then the detail line only on an issue. Colour orange on issue, else secondary.
   - Icons: issue `exclamationmark.circle`; active `checkmark.circle.fill`; waiting `play.circle`; preparing/loading/ready `hourglass`; else `waveform`.
2. Section "Listening Mode": a disclosure row showing the current mode: name (headline), detail (subheadline), battery note with `battery.50percent` (caption 500, accent for Best Quality). A11y "Listening mode", value `"<name>. <battery>"`, hint "Shows the recommended mode and lighter alternatives".
3. Section "Noise Reduction" (only when enabled): segmented "Amount": "Light", "Medium", "Strong" (a menu picker at accessibility sizes). Footer = strength detail.
4. Section "Volume Boost": a row "Level" (or "Saved level" when boost is not available) … the current level name. Then a segmented control "Off", "Low", "Medium", "High", "Max" (gains 1, 1.5, 2, 3, 4; nearest wins). The whole section is disabled when DeNoise is off. Footer = boost explanation.
5. Section (only when enabled and Best Quality): disclosure "Fine-tune the voice" … preset name. Footer "Your choices apply to all discourses. Results vary by recording."

**Listening Mode** page (inline "Listening Mode"):
- Section "Recommended": Best Quality.
- Section "Other Options": Balanced, Gentle Cleanup. Footer "Try a lighter option if you prefer its sound or want to save battery."
- Each row is the mode label with a trailing `checkmark.circle.fill` (accent) or `circle` (secondary), title3 size. Tapping selects the mode and pops back.

**Quiet Speech** page (inline "Quiet Speech"): rows with name (headline) + detail
(subheadline, secondary) + the same trailing indicator. Tapping selects and pops.

| Mode | Name | Detail | Battery note |
| --- | --- | --- | --- |
| deepFilterNet | Best Quality | Our recommended cleanup for hiss and background noise. | Uses more battery |
| rnnoise | Balanced | Everyday noise reduction with lighter processing. May soften the voice. | Uses less battery than Best Quality |
| cadence | Gentle Cleanup | Reduces hum and noise in pauses. Less effective during speech. | Lightest on battery |

| Strength | Label | Detail |
| --- | --- | --- |
| light | Light | Gentle cleanup that keeps more of the original sound. |
| medium (default) | Medium | A good starting point for most recordings. |
| strong | Strong | More noise reduction. The voice may sound less natural. |

| Quiet speech preset | Name | Detail |
| --- | --- | --- |
| focus | Natural | Quieter pauses, with no extra lift for soft speech. Keeps more of the voice’s natural dynamics. |
| lift (default) | Gentle Lift | Brings out quieter words without turning up the whole recording. |
| strong | Extra Lift | More lift for soft speech and quieter pauses. The voice may sound less natural. |

| Status | Label | Detail |
| --- | --- | --- |
| off | Original sound | Noise reduction and volume boost are off. |
| waitingForPlayback | Ready for playback | Your choices will apply when you play a discourse. |
| preparing / loadingModel / modelReady | Getting ready… | Getting noise reduction ready. Volume boost starts once cleanup is working. |
| active | Enhancement is on | Reducing recording noise. Adjust the controls as you listen. |
| waitingForAudio / bypassing / sourceError (issue) | Enhancement paused | Noise reduction and volume boost are temporarily paused. Try another mode if this continues. |
| unsupportedFormat (issue) | Unavailable for this recording | This recording can’t use audio enhancement. Noise reduction and volume boost are paused. |
| setupFailed(playback) (issue) | Playback unavailable | Playback could not start. Try playing the discourse again. |
| setupFailed(other) (issue) | Enhancement unavailable | Enhancement couldn’t start. Try playing the discourse again. Volume boost is paused. |
| modelUnavailable (issue) | Enhancement unavailable | This mode couldn’t start. Try another listening mode. Volume boost is paused. |

Boost footer, first match wins:
1. DeNoise off: "Turn on DeNoise to use volume boost. It raises the volume after reducing noise."
2. Level ≤ 1: "Boost is off. Choose a level to make quiet recordings louder."
3. Boost available: "Makes quiet recordings louder after reducing noise."
4. Status is an issue: "Your level is saved. Boost is paused until noise reduction is working again."
5. Otherwise: "Your level is saved. Boost will apply when enhanced audio starts playing."

Defaults: DeNoise off, Best Quality, Medium, boost 2× (Medium), Gentle Lift.

### 6.10 Transcript reader (`Views/Player/TranscriptView.swift`, `TranscriptSelection.swift`)

Sheet, large, with the drag indicator. Background `systemBackground` (elevated). The
toolbar is as in §5.3. The screen stays awake only while this discourse is playing and
the app is in the foreground.

**States**
- Loading: spinner with the label "Loading transcript…", centred.
- Error: icon `doc.plaintext`, title "Transcript unavailable", description = error text. "Try Again" (filled, prominent button) is hidden for fetch errors. A link "Open on oshoworld.com" shows when there is a catalog entry. Fetch errors (`Services/TranscriptFetcher.swift:14-18`): `oshoworld.com answered with status <code>.` · `The page did not contain a transcript.` · `oshoworld.com has no text for this discourse yet.`
- None: icon `doc.plaintext`, title "No transcript yet", description "oshoworld.com has not published a transcript for this discourse."

**Reader**, top to bottom:
1. Top insets, stacked: search bar (when searching); alignment progress row (on-device sync only, hidden on Android v1).
2. A scrolling column of rows. Rows are one sentence each by default, or blocks of about 240 letters when "One sentence per line" is off.
   - Row text colour: current, tapped or picked rows are `label`. Past rows are `label` @ 45 %. Future rows are `label` @ 60 %. In the current row with aligned timing, the non-current sentences are @ 55 %. Emphasis paragraphs (questions, sutras) are serif italic. The current row is semibold.
   - Background: picked accent @ 14 %; current accent @ 10 %; tapped primary @ 5 %. The current row has a 3 dp accent bar at the leading edge (inset 12 top and bottom), hidden in select mode. Row change animates easeInOut 0.25 s.
   - Search matches: yellow @ 45 % background on each occurrence. Matches need ≥ 2 characters, case- and diacritic-insensitive.
3. Following: the reader auto-scrolls so the current row sits 35 % from the top (easeInOut 0.45 s). A drag > 24 dp or a fling stops following. A plain tap does not.
   - When not following, not searching and not selecting, the pill "Now playing" (`arrow.down` when the current row is below, else `arrow.up`) floats at the bottom + 12. Hint "Scrolls back to the paragraph being spoken". It slides up with a fade (0.2 s). Tapping resumes following (scroll 0.4 s) and clears the saved read position.
4. Tapping a row shows the action chips below it (fade + slide from top, 0.2 s). Tapping again or on empty space hides them. Chips, in a horizontal scroll:
   - "Play from here" (`play.fill`) and "Audio is here" (`scope`), only while this discourse is playing.
   - "Copy" (`doc.on.doc`), "Select" (`checkmark.circle`), "Share" (`square.and.arrow.up`).
5. Long-press menu:
   - Normal: "Copy", "Select Text", "Select Passages", "Share".
   - In select mode: "Select Up to Here" (when the row is not picked and the selection is not empty), "Select Whole Paragraph" (when the paragraph has > 1 row and is not fully picked).
   - Dragging a row out carries its text (iOS only; skip on Android).
6. Select mode: rows show a leading `circle` / `checkmark.circle.fill` (accent), size `min(fontSize, 22)`. Taps toggle rows (0.15 s). The bottom bar replaces the transport: "Done" (600) · "Tap passages" or `"<n> selected"` · icon buttons Select Text, Copy, Share (disabled when nothing is picked; a11y "Select Text", "Copy", "Share").
7. Bottom transport bar (sheet, while this discourse is playing): a thin accent progress bar. Then elapsed time · `gobackward.15` ("Back 15 seconds") · play/pause ("Play"/"Pause", 44) · `goforward.30` ("Forward 30 seconds") · `"-<remaining>"`.

**Search bar**: magnifier + field "Find in transcript" (no autocaps or autocorrect,
return key = search, Enter goes to the next match) + clear button (a11y "Clear search").
Then `"<i>/<n>"` with chevron up/down (a11y "Previous match"/"Next match"), or `"0/0"`
when the query has ≥ 2 characters and no match. Then "Cancel". Typing jumps to the first
match and stops following. Search turns on with an animation and focuses the field.

**Options menu** (`textformat.size`), sections:
- "Text size": "Smaller" (`textformat.size.smaller`), "Larger" (`textformat.size.larger`). Disabled at 15 and 28.
- No header: "Select Passages". Disabled with no transcript or while selecting.
- "Layout": toggle "One sentence per line" (default on).
- "Timing", only while this discourse is playing:
  - With shipped alignment in use: the text `"Synced from speech: <matched> of <count> paragraphs"`.
  - Otherwise, on Android v1 (no on-device sync): the text `Estimated from text length. Tap a paragraph and choose “Audio is here” to correct it.`
  - The iOS-only items "Sync from speech on this device" and "Redo speech sync" are hidden.
  - When anchors exist: `"Clear <n> sync anchor"` / `"Clear <n> sync anchors"` (`scope`, destructive).
- No header, when there is a catalog page: "Open on oshoworld.com" (`safari`).

**Toasts** (top, ultraThinMaterial capsule, 2 s; 5 s for failure):
"Copied" · `"Copied <n> passages"` · "Synced to this sentence" (sentence layout) /
"Synced to this paragraph" · (iOS sync only: `"Synced <m> of <t> paragraphs from speech"`,
"Speech sync found no matches", `"Speech sync failed: <message>"`).

**Share text**: `"<text>\n\n— Osho, <series> #<N>"`. Copied passages from one paragraph
rejoin with their original space or line break. Different paragraphs are separated by a
blank line (`TranscriptSelection.swift:10-27`).

**Row accessibility**: hint "Tap to select" / "Tap to deselect" (select mode), else
"Tap for play, sync, copy and share" (empty when the chips are shown). Custom actions
"Copy" and "Select Text". Selected trait on the current row (or the picked row in
select mode).

**Select Text sheet**: inline title "Select Text". Top hint on `.bar`: "Touch and hold to
select words, then copy, share or drag them into another app." (footnote, secondary,
padding 20 × 10). Leading button "Copy All" → "Copied" for 2 s, with a success haptic.
Trailing: Share icon and "Done". Body: read-only selectable text, system font at
`fontSize`, line spacing `fontSize × 0.28`, inset 16 (bottom 32).

### 6.11 Queue / Up Next (`Views/Player/QueueView.swift`)

Sheet, medium + large. Inline title "Up Next", "Done". Plain list with clear row
backgrounds:
- Lead (24 wide): for the current item, `waveform` (animated variable colour while playing) or `pause.fill`, accent. Other rows show `index + 1` (secondary, tnum).
- Title: the display title, e.g. "A Bird on the Wing - #1". 600 and accent when current. Series name below (caption, secondary).
- Tapping plays that item and dismisses the sheet.
- A11y: `"Now playing: <title>"` or `"<title>, <series>"`; hint "Plays this discourse" (none for the current item).

### 6.12 Downloads (`Views/Downloads/DownloadsView.swift`)

Inset-grouped list. Large title "Downloads". Search "Search downloads" (matches the
series name or the discourse display title). Sections in order:

1. **"Downloading"**, only when something is in flight and the user is not searching or editing. The waiting notice is the first row when the network blocks downloads. Then in-progress rows: series name (body, 2 lines) / "Discourse <N>" (caption2) / "Queued", or a linear accent progress bar plus `"<p>%"` (or the waiting label). Trailing `xmark.circle.fill` cancels (a11y "Cancel download", value "Queued", the waiting label, or `"<p> percent"`). Footer "Downloads run one at a time. Tap to cancel."
2. **One section per downloaded series.**
   - Header: thumb 32 + name (600) + `"<n> episodes"` or `"<n> episodes · <size>"`. The header is a link to the series. Trailing `ellipsis` Menu (a11y "Series options") → "Delete All in Series" (`trash`, destructive). The menu is hidden while editing.
   - Rows: `<N>` (caption, 24 column) · "Discourse <N>" (accent when current track) · size (caption2 tnum) · play/pause circle fill (title3, accent; hidden while editing).
   - Row tap plays the series' downloaded discourses as a queue. A11y label "Discourse <N>", hint "Plays this discourse".
   - Swipe left: delete.
   - Context menu: "Play"/"Pause", "Add Bookmark…" (current track only), divider, "Remove Download" (destructive).
   - Footer on the **last** series section only: "Swipe a discourse left to delete, or use a series' ••• menu to clear a whole series or select several." (hidden while editing). Then a divider. Then `"<total> used on this device"` (when not searching and total > 0). Both caption, secondary.
   - Empty: a section "Downloads" containing an empty-state view with a clear background. Icon `arrow.down.circle`, title "No Downloads", text "Downloaded discourses will appear here." While searching: icon `magnifyingglass`, title "No Results", text `No downloads match "<query>".`
3. **"Previously Downloaded"** (not searching, not editing; history minus what is on disk minus what is downloading; sorted by series then number). Rows: series name (body, 2 lines) / "Discourse <N>" (caption2). Trailing GET pill, or a 26 dp ring / spinner (cancel). Swipe left removes the item from history. Footer "Removed from this device. Tap to download again, or swipe to remove from this list."
4. **Activity** (not editing):
   - `chart.bar.fill` (title3, accent) "Listening Stats" / subtitle `"<h>h <m>m listened"`, `"<m>m listened"`, or "Start listening to track time".
   - `bookmark.fill` (title3, orange) "Bookmarks" / `"<n> saved"` (only when n > 0).

Edit mode ("Select"): selection circles on the series rows; the other sections are
hidden. Bottom bar (ultraThinMaterial): "Select discourses" or `"<n> selected"` ·
"Delete" (600, red, disabled when nothing is selected). Delete removes the selection and
exits edit mode.

Dialogs (action sheets with a visible title):
- `"Delete all <n> downloaded discourses?"`. Message "This removes the audio files from this device. Your bookmarks and listening history are kept." Buttons "Delete All" (destructive) and "Cancel".
- `"Delete all downloads in <series>?"`. Buttons "Delete Series Downloads" (destructive) and "Cancel".

Sizes use `ByteCountFormatter` `.file`: base 1000. 0 decimals for bytes and KB, 1 for
MB, 2 for GB and above, with trailing zeros dropped (e.g. "36.5 MB", "1.23 GB"). Write a
small formatter; Android `Formatter` rounds differently.

### 6.13 Bookmarks (`Views/BookmarksView.swift`)

Background `systemBackground`. Large title "Bookmarks".
- No bookmarks: icon `bookmark`, title "No Bookmarks", text "Tap the bookmark icon in the player to save a moment."
- Else:
  1. Chips: "All" (`bookmark.fill`), then the 6 categories with their icons. Tapping the active category returns to All. No animation.
  2. Inset-grouped list, hidden background. One section per series name (sorted A→Z; header = series name). Rows are newest first.
     - Row: title (the display title, e.g. "A Bird on the Wing - #1"; blue while playing) / category tag capsule (icon + custom name for Custom, else the category name) + timestamp / note (2 lines, when not empty).
     - Trailing: `play.circle.fill` (a11y "Play", hint "Plays from the bookmarked moment"), a spinner (a11y "Downloading"), or `arrow.down.circle` (a11y "Download").
     - Play: if this is the current track, seek with history. Otherwise play, then seek after 500 ms.
     - Swipe left to delete.
  3. Filtered empty: icon `bookmark.slash`, title "No bookmarks in this category", text "Try a different filter."

### 6.14 Listening Stats and History (`Views/Settings/ListeningStatsView.swift`, `ListeningHistoryDetailView.swift`)

**Stats** (inline "Listening Stats"; inset-grouped list on `systemBackground`):
1. A card with a 2 × 2 grid:

   | Card | Icon | Icon colour | Value |
   | --- | --- | --- | --- |
   | "All Time" | `infinity` | accent | `"<h>h <m>m"` / `"<m>m"` / `"<1m"` |
   | "Streak" | `flame.fill` | orange | `"<d>d"` |
   | "Discourses Done" | `checkmark.circle.fill` | green | count |
   | "Series Done" | `books.vertical.fill` | purple (hardcoded) | count |

2. Section "Time Periods": rows "Today", "Last 7 Days", "Last 30 Days", "All Time". Value `"<h>h <m>m"`, `"<m> min"`, `"<1 min"`, or `"—"` when 0.
3. Section: disclosure "Full Listening History" … `"<n> items"` (caption).

**History** (inline "Listening History"):
1. Section "Daily Log": newest first. The date label is "Today", "Yesterday", or `EEE, MMM d` (e.g. "Wed, Jul 29"). Duration `"<h>h <m>m"`, `"<m>m"`, or `"<1m"`. Empty: "No data yet" (secondary).
2. Section `"All Played Discourses (<n>)"`: display title (subheadline) / series (caption). Trailing: the saved position as a duration, or `checkmark.circle.fill` (caption, accent) when the position is 0. Empty: "No listening history yet".

### 6.15 Settings (`Views/Settings/SettingsView.swift`)

Form, grouped background. Large title "Settings". Sections in order:

1. "Content Language": segmented "Both" | "English" | "Hindi" (no row label shown).
2. "Player & Downloads": toggles "Auto-Play Next" (on), "Smart Download" (on), "Smart Delete" (off), "Download over Cellular" (off). Footer "Downloads use Wi-Fi only unless this is on. Each discourse is roughly 20–30 MB."
3. "Sound": a disclosure row with `waveform` (accent) "DeNoise" / subtitle (caption, secondary) = the mode name when on, else "Noise reduction and volume boost". Trailing "On"/"Off" (secondary).
4. (Apple Watch section, iOS only. Omit on Android.)
5. "Appearance":
   - Segmented "Light" | "System" | "Dark".
   - A horizontal row of 8 swatches. The selected swatch is the *effective* accent, so a shuffled colour also shows as selected. It has a white check and an accent ring.
   - Toggle "Shuffle Color Daily".
   - Footer, only when shuffle is on: "The accent color changes to a new one each day."
   - Swatch tap animates easeInOut 0.2 s.
6. "My Other Apps": "Bruce" / "Workout tracker", "Drop" / "The falling ball". Bundled 40 dp icons, `arrow.up.right`. They link to the iOS App Store (see §8).
7. "About":
   - "Version" … version name. "Series" … 351. "Discourses" … 5481 (computed).
   - Button "Support Development" (`cup.and.saucer.fill`, accent label, trailing `chevron.right`).
   - Links: "Rate Osho Talks" (`star`), "Source Code" (`chevron.left.forwardslash.chevron.right`, `https://github.com/aagrawal207/OshoDiscourses`), "Send Feedback" (`envelope`, `mailto:aagrawal207@gmail.com?subject=Osho%20Talks%20Feedback`). Trailing `arrow.up.right`.
   - Footer, four paragraphs, gap 8, top 8:
     1. "Acknowledgements: All discourses are copyright OSHO International Foundation. Audio is served from oshoworld.com."
     2. "Noise reduction uses RNNoise (Xiph.Org, BSD 3-Clause) and DeepFilterNet by Hendrik Schröter (MIT/Apache-2.0)."
     3. "This app is an independent player for publicly available audio content hosted at oshoworld.com. Not affiliated with or endorsed by the Osho International Foundation."
     4. "Your listening progress, bookmarks, and stats sync between your devices through your own iCloud. Everything else stays on your phone. There are no accounts, no servers, and no tracking of any kind." (platform wording: see §8)

### 6.16 Support Development / Tip jar (`Views/Settings/TipJarView.swift`)

Sheet. Inline title "Support Development", leading "Done". Grouped list,
`systemGroupedBackground`.

1. Intro section: `cup.and.saucer.fill` 40 sp accent. Body: "Osho Talks is free and has no ads or tracking. If it has become part of your days, an optional tip helps me keep improving it." Footnote (secondary): "Choose a one-time tip or yearly support through Apple. Every feature stays free for everyone."
2. Products section:
   - While loading: spinner + "Loading tips…".
   - Then the product rows, ordered by price, with consumables before subscriptions at equal price.
   - Then, if present: the tips load error + "Try Again", and the yearly load error + "Retry Yearly Options".
   - Footer when tips > 0: "One tip recorded on this device. Thank you." or `"<n> tips recorded on this device. Thank you."`
   - Row: name / kind (caption) / description (caption) … price capsule. Kind is "One-time tip", or for yearly plans "Renews yearly · Cancel anytime", "Current yearly plan", or "Awaiting approval". A yearly price reads `"<price> / year"`. A spinner replaces the price while purchasing. At accessibility sizes the row stacks vertically.
3. Section "Yearly support":
   - If a request is pending: "A yearly support request is awaiting approval. Another subscription can't be started until it is resolved." + "Check Pending Request" + "Request Was Declined".
   - If subscribed: `heart` "Thank you for your yearly support" + "Your Apple Account has a yearly support plan. You can change the amount, check its status, or cancel through Apple."
   - Always: "Manage Subscriptions", "Restore Subscription" ("Restoring…" while busy). Status error + "Check Subscription Status". Restore message. Links "Terms of Use", "Privacy Policy" (`https://github.com/aagrawal207/OshoDiscourses/blob/main/PRIVACY.md`).
   - Footer: "Yearly support is an auto-renewing subscription charged once a year unless cancelled at least 24 hours before renewal. Manage or cancel it in your App Store account. One-time tips do not renew. Neither option unlocks features or content."
4. Pending bar (bottom, regularMaterial): `clock` "Purchase pending" (headline) + "Your purchase is pending with the App Store. It may need approval, such as Ask to Buy. You don't need to try again." + "Got It".
5. Alert ("OK"):
   - "Thank you" / "Your yearly support helps me keep improving Osho Talks. Every feature stays free for everyone."
   - "Couldn't confirm subscription" / message.
   - "Thank you" / "Your tip keeps this app going. Enjoy the talks."
   - "Couldn't confirm tip" / message.
6. Dialog "Clear the pending request?". Message "Only clear this if the App Store request was declined or cancelled. A request that is still pending may be approved and charged later." Button "Clear Declined Request" (destructive).

Products (`OshoDiscourses/TipJar.storekit`):

| Product | Name | Description | US price |
| --- | --- | --- | --- |
| tip.small | Small tip | A coffee for the developer. | $3 |
| tip.medium | Generous tip | Covers a month of the odd fix. | $5 |
| support.annual5 | Small yearly support | Optional support for ongoing app development. | $5 / year |
| tip.large | Big tip | Funds an afternoon on a new feature. | $10 |
| support.annual10 | Generous yearly support | Optional support for ongoing app development. | $10 / year |
| support.annual15 | Extra yearly support | Optional support for ongoing app development. | $15 / year |
| tip.grand | Grand tip | You are keeping this app alive. | $25 |
| tip.patron | Patron tip | Helps fund more improvements to the app. | $50 |

Service messages:
- Tips (`Services/TipJarService.swift`): "Tips aren't available in the App Store right now. Please try again later." · "Some tips aren't available right now. You can choose an available tip or try again." · "Loading was interrupted. Please try again." · "Couldn't load tips from the App Store. Check your connection and try again." · "This tip is not available. Please reload the tip jar." · "In-app purchases aren't allowed on this device." · "This tip is currently unavailable in the App Store. Please try again later." · "This purchase was refunded or revoked. No tip was recorded."
- Yearly (`AnnualSupportService.swift`): "Some yearly support options aren't available right now. Please try again later." · "Couldn't load yearly support from the App Store. Check your connection and try again." · "Couldn't check your existing yearly support. Try again before starting a subscription." · "Couldn't confirm your subscription. Check your App Store subscriptions before trying again." · "Couldn't verify your subscription. Check your App Store subscriptions before trying again." · "No current yearly support subscription was found." · "Your yearly support subscription is restored. Thank you." · "Couldn't restore your subscription. Please try again later."

### 6.17 Launch view (`Views/LaunchView.swift`, `Resources/SplashScreen.storyboard`)

A full-bleed `#1E0F44` background. A centred vertical stack: `LaunchLotus` image
132 × 132, gap 22, "Osho Talks" (22 sp semibold, white, fixed size). A11y: one element
"Osho Talks". It holds for 0.15 s with no fade-in, then cross-fades out (easeOut 0.25 s)
over the app, which is already mounted underneath (`App/OshoDiscoursesApp.swift:63-70`).

### 6.18 Download waiting notice (`Views/Downloads/DownloadWaitingNotice.swift`)

Shown only when `waitingReason != nil`:
- Wi-Fi: label (`wifi`) "Waiting for Wi-Fi" (subheadline 600). Body (footnote, secondary): "Downloads use Wi-Fi only. Each discourse is about 20–30 MB." Then a filled accent button "Use Mobile Data" (hint "Downloads now and later can use mobile data. You can change this in Settings.").
- No connection: label (`wifi.slash`) "Waiting for a connection". Body "Downloads continue when you're back online." No button.

The row status labels are the same two titles. Placement: the first row of Downloads >
Downloading, and a card in Series detail.

## 7. Animations and haptics (summary)

| Event | iOS | Compose |
| --- | --- | --- |
| Launch splash exit | opacity, easeOut 0.25 s after a 0.15 s hold | `AnimatedVisibility(exit = fadeOut(tween(250, easing = LinearOutSlowInEasing)))` |
| Library chip change | easeInOut 0.2 s | `animateColorAsState(tween(200))` |
| Settings swatch | easeInOut 0.2 s | same |
| Clear All / dismiss row | default spring | `animateItem()` in Lazy lists |
| "Downloading..." hint | opacity, 2 s | `AnimatedVisibility(fadeIn/fadeOut)` + `delay(2000)` |
| Player toast | move from top + opacity, easeInOut, 2 s | `slideInVertically { -it } + fadeIn` |
| Transcript follow scroll | easeInOut 0.45 s; resume 0.4 s | `animateScrollToItem` with a 35 % viewport offset |
| Transcript current row | easeInOut 0.25 s | `animateColorAsState(tween(250))` |
| Action chips | opacity + move from top, 0.2 s | `expandVertically + fadeIn` |
| Select mode / pill / toast | easeInOut 0.2 s | `tween(200)` |
| Row pick toggle | easeInOut 0.15 s | `tween(150)` |
| Speed value | `.contentTransition(.numericText())` | `AnimatedContent` with a vertical slide per digit |
| Queue current item | `waveform` variable-colour pulse while playing | 3–4 bar equalizer, infinite transition |
| Disabled controls | opacity 0.35 | `alpha(0.35f)` |
| Speed change | `.sensoryFeedback(.selection)` | `HapticFeedbackType.SegmentTick` (Compose 1.8+), else `View.performHapticFeedback(CLOCK_TICK)` |
| Select Text "Copy All" | `.sensoryFeedback(.success)` | `HapticFeedbackType.Confirm`, else `CONFIRM` (API 30+) |
| Long-press context menu | system haptic | `HapticFeedbackType.LongPress` |
| Swipe full delete | system haptic | `HapticFeedbackType.GestureThresholdActivate` (Compose 1.8+) |

## 8. Android mapping notes

| iOS control | Compose substitute that keeps the iOS look |
| --- | --- |
| `TabView` with the iOS 26 floating glass tab bar | A custom `OshoTabBar` in `:core:ui`, not Material `NavigationBar`: a floating capsule (§3.3), glass recipe (§1.7), filled icons, selected pill. Content draws edge-to-edge behind it. Respect `WindowInsets.navigationBars`. |
| Floating mini-player | `Box` overlay in the tab shell above `OshoTabBar`. Provide `LocalMiniPlayerClearance` (dp) and apply it as bottom `contentPadding` on every scrolling tab page, including pushed pages. Zero inside sheets. |
| `NavigationStack` large title + `.searchable` | `LargeTopAppBar` with `exitUntilCollapsed` scroll behaviour, styled per §3.3 (34 bold, left; collapsed 17/600 centred; transparent container). The search capsule is the first item in the scroll content, so it scrolls with it. |
| Toolbar glass buttons, back chevron | A shared `GlassIconButton` (44 dp circle) and `GlassTextButton` (capsule, 17 sp). The system back gesture and predictive back still work. |
| `List(.insetGrouped)` / `Form` | `LazyColumn` with a shared `GroupedSection(header, footer) { rows }`. The card is r 22, side inset 16, `secondarySystemGroupedBackground`. Header and footer per §2.1. Dividers inset to the text start. No uppercase. |
| `.ultraThinMaterial`, `.bar`, `.regularMaterial` | Haze (`hazeSource`/`hazeEffect`) on API 31+ if the coordinator adds it; else the tinted fallbacks in §1.7. |
| `.sheet` with `.large` | `ModalBottomSheet(sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true))`. Top corners 28 dp. `containerColor` uses the elevated surface. Scrim black @ 40 %. Player: `dragHandle = null` (it draws its own 36 × 5 handle). Transcript and DeNoise use a custom 36 × 5 handle (secondary @ 50 %). Use `contentWindowInsets` for edge-to-edge. Alternative for the Player: a full-screen destination with slide-up enter and drag-to-dismiss. |
| `.presentationDetents([.medium, .large])` (Queue) | `ModalBottomSheet` with partial expansion allowed (opens at ≈ 50 %). |
| `.presentationDetents([.medium])` (Add Bookmark) | `ModalBottomSheet` opened partially expanded. The IME pushes it up. |
| `.popover` + `.presentationCompactAdaptation(.popover)` (Speed, Sleep) | `Popup` anchored above the tapped control (`PopupPositionProvider` with the control bounds). Card r 20, elevated `secondarySystemGroupedBackground` (or glass), shadow black @ 20 % blur 24 dp. Width 160 (sleep) / 300 (speed). No arrow is needed. Dismiss on outside tap. |
| `Menu` (toolbar, sort, series header) | `DropdownMenu` restyled: shape r 14–20, container elevated `secondarySystemGroupedBackground`, items 17 sp with the icon as `leadingIcon`, destructive items red. Section headers 13 sp secondary. Dividers between sections. A `Toggle` inside a menu → an item with a trailing check. |
| `.contextMenu` (rows) | Long press: `combinedClickable(onLongClick = …)`, a `LongPress` haptic, then the same restyled `DropdownMenu` anchored at the touch point. No preview lift. Destructive items go last after a divider. |
| `.onDelete` swipe | A reveal row built on `AnchoredDraggableState` with anchors 0 and −80 dp. A red "Delete" (white, 17 sp) button sits behind. A full swipe past 50 % width deletes. `SwipeToDismissBox` is acceptable if it is styled red with a "Delete" label. |
| `EditMode` multi-select (Downloads) | A selection state in the ViewModel. Rows show a leading `radio_button_unchecked` / `check_circle` (accent, filled) with a 0.2 s slide. The glass bottom bar per §6.12. |
| `confirmationDialog` (iPhone action sheet) | A shared `ActionSheet` composable: a bottom `ModalBottomSheet`, or a `Dialog` aligned to the bottom with 8 dp side margins. Two stacked cards: (title 13/600 secondary + message 13 secondary + action buttons 20 sp in accent or red, divided) and a separate "Cancel" card (20 sp, 600). r 14–22. |
| `.alert` | `AlertDialog` restyled: r 22, title 17/600 centred, message 13 centred, buttons in accent. |
| `ContentUnavailableView` | `EmptyState(icon, title, description, actions)`: icon 48 dp secondary, gap 12, title 22 bold, description 15 secondary centred, max width 320. |
| Segmented `Picker` | A custom `SegmentedControl` (§3.3). Material `SegmentedButton` has a different look. At `fontScale >= 1.6` use a dropdown row as iOS does. |
| `Toggle` | Material `Switch` with `SwitchDefaults.colors(checkedTrackColor = accent, checkedThumbColor = White, uncheckedTrackColor = systemFill, uncheckedThumbColor = White, uncheckedBorderColor = Transparent)` and no thumb icon. Always use the thumb at full size (`thumbContent` with a fixed 24 dp). |
| `Slider` (seek, speed) | Material 3 `Slider` with a custom `track` (4 dp, rounded) and `thumb` (white capsule 38 × 24 with 2 dp shadow). The speed slider uses `steps = 29` (0.5 to 2.0 in 0.05). Seek commits on `onValueChangeFinished`. |
| `ProgressView` circular / linear | `CircularProgressIndicator` (gray, 20 dp) / `LinearProgressIndicator` (accent, `systemFill` track, no gap, no stop indicator). |
| `ShareLink` | `Intent.ACTION_SEND` with `Intent.createChooser`. |
| `Link` (web, mailto, store) | `LocalUriHandler` / `Intent.ACTION_VIEW`, `ACTION_SENDTO` for mailto. |
| `AVRoutePickerView` (AirPlay) | API 34+: `MediaRouter2.getInstance(context).showSystemOutputSwitcher()`. Below that: `androidx.mediarouter` `MediaRouteButton` / dialog. Icon accent. |
| `UITextView` Select Text | `SelectionContainer { Text(...) }` in a vertical scroll. The system toolbar gives Copy, Share and Translate. Drag-out is not supported (omit). |
| `isIdleTimerDisabled` | `View.keepScreenOn = true` while the condition holds (`LocalView.current`). |
| `.monospacedDigit()` | `TextStyle(fontFeatureSettings = "tnum")`. |
| `@ScaledMetric` | `with(LocalDensity) { base * fontScale }`, with the same caps as §3.2. |
| Dynamic Type caps `...xxxLarge` | Wrap in `CompositionLocalProvider(LocalDensity provides Density(density, fontScale.coerceAtMost(1.35f)))`. |
| `hoverEffect`, keyboard shortcuts, sidebar, `fullScreenCover` player | iPad/Mac only. Skip. |

### Platform wording (decisions for the coordinator)

Copy is verbatim except where it names an Apple service that does not exist on Android.
Workers must keep the iOS string and flag it in their handoff. The coordinator decides:
- Settings > About footer: "…through your own iCloud." → Google Drive wording (sync is Drive app data).
- Tip jar: "through Apple", "App Store", "Apple Account", "Ask to Buy", "Manage or cancel it in your App Store account" → Google Play equivalents. "Restore Subscription" may be unnecessary on Play. "Terms of Use" points to Apple's EULA.
- Error strings that say "App Store" (TipJar/AnnualSupport services).
- Settings "My Other Apps" (Bruce, Drop) link to the iOS App Store. Hide the section, or link to Play listings if they exist.
- "Rate Osho Talks" → Play In-App Review, or the Play listing.
- Apple Watch section → removed in v1.
- Transcript Select Text hint "Touch and hold to select words, then copy, share or drag them into another app." Drag-out does not exist on Android, so consider dropping "or drag them into another app".

