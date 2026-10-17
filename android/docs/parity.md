# Visual parity: Android phone vs iPhone (A17 part b, #35)

Reference: iPhone 17 Pro, iOS 27, `index.md` in the reference folder records each state.
Android: `emulator-5556` (Pixel 9, Android 16, 411 × 923 dp), same seeded state: A Bird on
the Wing #1–#2 and Main Mrityu Sikhata Hun #1 downloaded, Bird #1 at 25:20 and Mrityu #1 at
10:10, a week of stats (2 h 52 m, 2-day streak) and the two Bird #1 bookmarks. The state comes
from the debug receiver's `seed` and `seed_bookmarks` commands plus a rewritten
`listening_stats.json`; the driver scripts are `run.py` and `p.py` next to the pairs.

Pairs are iOS left, Android right, both at 1.6 px per pt/dp, in
`$TMPDIR/opencode/parity/<screen>_<light|dark>.png` (`$TMPDIR` is the opencode temp folder,
`/private/var/folders/2l/z44p1mns4yl3rc34xd7ymljr0000gq/T/`).

Status: **fixed** = differences found and corrected; **match** = no change needed;
**accepted** = remaining difference allowed by PLAN.md or the platform, reason given.

## Summary

| Status | Screens (light and dark each) |
| --- | --- |
| fixed | 38 (5 of them keep an accepted difference) |
| match | 4 |
| accepted | 1 |

All 43 screens have light and dark pairs (86). The emulator's system server crashed during
the last full rerun, so the light pairs of the player, DeNoise, transcript, Downloads waiting,
Bookmarks and Support screens predate the last small fixes (battery glyph, DeNoise top inset,
waiting notice, Bookmarks row padding); their dark pairs include them.

## Screens

| Screen | State | Status | Notes | Pairs |
| --- | --- | --- | --- | --- |
| Home | top | fixed | Tab bar glyphs (filled books, solid download disc), icon size, label size, selected pill contrast; large-title position; bar fade | `home_top_*` |
| Home | shelves | fixed | Shared chrome fixes only | `home_shelves_*` |
| Home | Hindi shelves | fixed | Shared chrome fixes only | `home_shelvesHindi_*` |
| Home | mini-player | match | Card, artwork, titles, progress and position above the tab bar match | `home_miniPlayer_*` |
| Home | mini-player, scrolled | match | Inline title fades in; last row clears the mini-player | `home_miniPlayerScrolled_*` |
| Library | top | fixed | Search field hidden until pulled down, as `.searchable` on iOS 26 | `library_top_*` |
| Library | theme chip | fixed | Same as top | `library_themeChip_*` |
| Library | sort menu | fixed | Menu corner 26, leading accent chevron on the current field, no trailing check | `library_sortMenu_*` |
| Library | search | fixed / accepted | Active search replaces the bar with a glass field and Close circle; title hides. Keyboard is Gboard | `library_search_*` |
| Series | Bird top | fixed | Description inset 24; Download All solid disc icon 20; back chevron 24; bar height 44 | `series_birdTop_*` |
| Series | Bird rows | fixed | Play circle 28 (was 32) | `series_birdRows_*` |
| Series | Bird playing | match | Blue playing title, pause circle, mini-player | `series_birdPlaying_*` |
| Series | Hindi top | fixed | Same as Bird top | `series_hindiTop_*` |
| Series | Hindi rows | fixed | Same as Bird rows | `series_hindiRows_*` |
| Player | playing | fixed | Sheet sits under the status bar with the dimmed page above (corner 38); Up Next accent; play glyph larger | `player_playing_*` |
| Player | paused | fixed | Same as playing | `player_paused_*` |
| Player | speed popover | fixed | Popover arrow, corner 28, 16 dp screen margin | `player_speedPopover_*` |
| Player | sleep popover | fixed | Moves beside the control with a side arrow when the arrow would hit a corner, as UIKit does; row gap 2 | `player_sleepTimer_*` |
| Player | Up Next | fixed / accepted | Medium sheet floats 8 dp inside the edges with rounded bottom corners and docks at full height; rules above the first and below the last row; Done is plain glass with accent text. iOS blurs the player through the sheet; Android shows it solid | `player_upNext_*` |
| Player | Add Bookmark | fixed | Sheet grows to full height while the keyboard is up, so the note stays visible; Cancel and Save are glass with accent text (Save semibold) | `player_addBookmark_*` |
| DeNoise | from player | fixed | Done is plain glass with accent text | `denoise_fromPlayer_*` |
| DeNoise | off | fixed | 40 dp inset above the first section; disabled segmented control keeps its thumb and grays only labels; Saved level row no longer dimmed | `denoise_off_*` |
| DeNoise | on | fixed | Battery glyph drawn after SF `battery.50percent` (horizontal); switch | `denoise_on_*` |
| DeNoise | on, bottom | fixed | Same as on | `denoise_onBottom_*` |
| DeNoise | Listening Mode | fixed | Battery glyph | `denoise_listeningMode_*` |
| DeNoise | Quiet Speech | fixed | 40 dp inset above the first section | `denoise_quietSpeech_*` |
| Transcript | from player | fixed | Sheet card under the status bar over the dimmed player; title sits beside Close as iOS 26 places a principal item; accent toolbar glyphs; `AA` text-size glyph instead of Material's "TT" | `transcript_english_*` |
| Transcript | following | fixed | Same as from player | `transcript_sheetFollowing_*` |
| Transcript | action bar | fixed | Same chrome fixes | `transcript_actionBar_*` |
| Transcript | search | fixed / accepted | Same chrome fixes; keyboard is Gboard | `transcript_search_*` |
| Transcript | options menu | fixed | Leading check column for the toggle with every row indented to match; section dividers are hairlines; Timing note reads as a disabled row | `transcript_options_*` |
| Downloads | top | fixed | Section headers in secondary colour (the iOS list tints them); `ellipsis.circle` toolbar glyph; header spacing; row padding | `downloads_top_*` |
| Downloads | scrolled | fixed | Listening Stats glyph drawn after SF `chart.bar.fill`; activity icons 26 | `downloads_scrolled_*` |
| Downloads | waiting for Wi-Fi | fixed | Accent Wi-Fi glyph 22 with a 12 gap; Use Mobile Data in body text | `downloads_waitingWifi_*` |
| Bookmarks | list | fixed | Row padding 15 | `bookmarks_*` |
| Stats | top | fixed | 35 dp inset above the first card; Series Done glyph drawn after SF `books.vertical.fill` | `stats_top_*` |
| Stats | bottom | fixed | 38 dp gap before Full Listening History | `stats_bottom_*` |
| History | top | match | Rows and headers already matched; shared header spacing applies | `history_top_*` |
| Settings | top | fixed | iOS 26 switch (63 × 28 capsule, 39 × 24 thumb, darker off track); 52 dp rows; segmented 32 high; header gaps 29 after a card, 18 after a footer | `settings_top_*` |
| Settings | middle | fixed | Same plus swatch row height | `settings_middle_*` |
| Settings | bottom | fixed / accepted | About link icons 24 with the separator under the label; footer line height 16. Sync section (Google Drive) is Android-only; My Other Apps is hidden (PLAN.md) | `settings_bottom_*` |
| Support | top | fixed / accepted | Done is glass with accent text. Google Play wording and Play prices (PLAN.md) | `support_top_*` |
| Support | middle | accepted | Same wording difference | `support_middle_*` |

## Shared differences accepted

| Difference | Reason |
| --- | --- |
| Status bar, gesture handle, keyboard | System chrome. The iOS status bar is the simulator override; Android uses demo mode at 9:41 |
| Roboto instead of SF Pro | ui-style.md §2.1. Roboto runs wider, so some lines wrap one word earlier |
| Weaker glass | Haze blur is lighter than Liquid Glass. Tab bar, mini-player and bars use the tuned tints |
| AirPlay glyph | Android opens the system output switcher (PLAN.md); icon is `speaker_group` |
| Swipe-back | Android uses the system back gesture, not the iOS edge pan with a parallax page |
| iOS-only rows | Apple Watch, My Other Apps, speech sync toggle, Select Text drag-out (PLAN.md, ui-style.md §8) |

## Interaction checks

| Check | Result |
| --- | --- |
| Tab re-tap pops to root | Pass: Library > series, re-tap Library returns to the list |
| Tab switch | Fixed: switching tabs cross-faded through Navigation 3's push animation for about 300 ms; each tab now has its own display, so a switch is instant as on iOS while pushes still slide |
| System back from a pushed page | Pass: edge swipe pops the series page |
| Large-title collapse | Fixed: inline title appears once the large title's baseline passes under the bar (40 dp), with an opaque lifted bar and soft edge |
| Search reveal | Fixed: pull down at the top reveals the field, scrolling up folds it away, a half pull settles to the nearer state; active search survives push and pop without re-raising the keyboard |
| Mini-player above the tab bar | Pass: 6 dp gap; every page reserves its height plus 12 |
| Popovers and sheets | Popovers scale from the arrow; medium sheets float and dock while dragged; the player and transcript slide up over a 20 % scrim |
| Tap feedback | Rows use the platform ripple; toolbar glass buttons and the tab bar have no ripple, as on iOS |
| Font scale 1.5 | Pass on Home, Player and Settings: no clipping; bars cap at 1.35 (`stress_*_font15.png`) |
| 360 dp wide (1080 × 2160 at 480 dpi) | Pass on Home, Player and Settings; Player uses 16 dp side padding (`stress_*_small360.png`) |

## Seeding

```sh
adb -s emulator-5556 shell am broadcast -a com.agraabhi.oshodiscourses.DEBUG -p com.agraabhi.oshodiscourses --es cmd download --es id english-A_Bird_on_the_Wing__-1
# … the same for english-A_Bird_on_the_Wing__-2 and hindi-Main_Mrityu_Sikhata_Hun-1
adb -s emulator-5556 shell am broadcast -a com.agraabhi.oshodiscourses.DEBUG -p com.agraabhi.oshodiscourses --es cmd seed
adb -s emulator-5556 shell am broadcast -a com.agraabhi.oshodiscourses.DEBUG -p com.agraabhi.oshodiscourses --es cmd seed_bookmarks
adb -s emulator-5556 shell am broadcast -a com.agraabhi.oshodiscourses.DEBUG -p com.agraabhi.oshodiscourses --es cmd appearance --es value dark
```

`seed` merges stats, so it only raises a day's total; rewrite `files/listening_stats.json`
with `run-as` to reset today after listening.
