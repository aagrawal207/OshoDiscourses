# Usage telemetry

Osho Talks sends anonymous usage signals to [TelemetryDeck](https://telemetrydeck.com/)
from 1.17.2. They show which features, settings and talks listeners use.

| Item | Value |
| --- | --- |
| SDK | TelemetryDeck SwiftSDK 2.14.2 (`project.yml` package, iOS app target only) |
| App ID | `584A18B7-DDF4-4BF5-9A28-C687DCEB6489` |
| Namespace | `com.abhishekagrawal` |
| Code | `Services/TelemetryService.swift` (the only caller of the SDK), `TelemetrySignals.swift` (names and parameters), `TelemetryDeckSink.swift` |
| Switch | Settings > About > Share Anonymous Usage Data (`settings.shareUsageData`, on by default). Off stops the SDK; nothing is sent |
| Debug builds | Signals are marked as test data; view them with Test Mode on in the dashboard. Unit tests never start the SDK |
| Free plan | 50,000 signals a month. Heavy use needs a paid plan |

## Rules

- Never send free text: no bookmark notes, custom category names, search text,
  transcript text, titles typed by the listener, file paths, URLs or error messages.
- Values are catalog IDs, enum raw values, booleans, language codes or bucketed
  counts (`TelemetryParameters.bucket`: 0, 1, 2-5, 6-10, 11-25, 26-50, 51-100, 100+).
- No signal per tick or keystroke. Listening time is summed per talk, speed and
  library search are debounced, and Watch transport commands are not sent.
- Watch-side offline listening is not counted; the phone reports only what it sees.

## Parameters on every signal

`TelemetryService.updateContext` adds the listener's settings to every signal,
including the SDK's own `TelemetryDeck.Session.started`. Use them as filters, for
example "DeNoise mode among active users".

`platform` (iPhone, iPad, mac), `Settings.noiseReduction`, `Settings.noiseReductionMode`
(deepFilterNet = Best Quality, rnnoise = Balanced, cadence = Gentle Cleanup),
`Settings.denoiseStrength`, `Settings.voiceFocusPreset`, `Settings.volumeBoost`,
`Settings.smartDownload`, `Settings.smartDelete`, `Settings.autoPlayNext`,
`Settings.allowCellularDownloads`, `Settings.appearance`, `Settings.accentTheme`,
`Settings.dailyAccentShuffle`, `Settings.languageFilter`, `Settings.defaultPlaybackRate`,
`Settings.transcriptSentenceLayout`, `Settings.transcriptFontSize`,
`Settings.transcriptSpeechSync`.

Discourse parameters (`TelemetryParameters.discourse`): `discourseID`, `seriesID`,
`seriesName`, `language`. Translation adds `sourceLanguage`, `targetLanguage`.

## Signals

| Signal | Sent when | Parameters (beyond discourse ones) |
| --- | --- | --- |
| `Listening.session` | A talk segment ends: next talk, finish, stop, app to background, or every 30 minutes of listening. Value = seconds heard | `kind` (original, translation), `startReason` (user, next, previous, queueItem, autoAdvance, restored, bookmark, recovered, continued), `endTrigger` (finished, skippedToEnd, switched, stopped, background, periodic), `completed`, `skipsForward`, `skipsBack`, `seeks`, `rate`, `minutes` |
| `Playback.speedChanged` | Speed settles for 2 s | `rate` |
| `Playback.failed` | An item fails to play | `category` (network, notFound, decode, mediaServices, unknown) |
| `SleepTimer.started` / `.cancelled` | Listener sets or cancels it | `option` (minutes or endOfDiscourse) |
| `Download.completed` | A download is saved | `origin` (user, downloadAll, smartDownload, unknown), `source` (archive, oshoworld, unknown), `fallback` |
| `Download.failed` | A download fails (not cancelled) | `origin`, `category` (DownloadError case or transport) |
| `Download.allRequested` | Download All confirmed | series parameters, `count` |
| `Download.deleted` | A download is deleted | `reason` (user, smartDelete); batches add `scope` (selection, all), `count` |
| `Translation.prepareStarted` | A translation starts or resumes preparing | `pace`, `voiceQuality`, `automatic`, `listen`, `resumed` |
| `Translation.consent` | Apple's language prompt state | `result` (shown, notAsked, accepted, declined, sheetClosed) |
| `Translation.prepareFinished` | A run ends. Value = seconds | `outcome` (ready, failed, cancelled, paused), `stage`, `reason`, `minutes`, `audioMinutes` |
| `Translation.deleted` | A saved translation is deleted | `complete`, `minutes` |
| `Bookmark.added` / `.deleted` | Listener adds or deletes one (not iCloud merges) | `hasNote`, `category` (enum case only) |
| `Bookmark.opened` | Played from Bookmarks | `from`, `sameTalk` |
| `Transcript.opened` | Reader loads | `presentation` (sheet, embedded), `playing`, `outcome`, `shippedTiming` |
| `Transcript.searched` | Once per reader visit with a search | `matches`, `queryLength` |
| `Transcript.action` | Reader action | `action` (playFromHere, anchor, copy, selectText, selectPassages, speechSyncRedo, clearAnchors), `passages`/`anchors` |
| `Settings.changed` | Any setting changes value (not speed, which has its own signal) | `setting`, `value` |
| `Library.searched` | Typing stops for 1.5 s | `queryLength`, `results` |
| `Library.filterSelected` | A chip is tapped | `filter`, `theme` |
| `Series.opened` | A series page appears | series parameters, `downloaded` |
| `Library.snapshot` | At most weekly, 5 s after launch | `downloads`, `bookmarks`, `completed`, `played`, `tips`, `yearlySupport`, `iCloud`, `savedTranslations` |
| `Support.sheetOpened` | Support Development opens | `hasTipped` |
| `Support.purchase` | A tip, yearly purchase or restore ends | `product`, `kind` (tip, yearly), `outcome`, `failure` |
| `TelemetryDeck.Purchase.completed` | Verified tip or new subscription (SDK preset, revenue charts) | `kind`, `source` |
| `Support.prompt` | Home support card | `action` (shown, accepted, notNow, dontAskAgain) |
| `Review.requested` | The system review prompt is asked for | `activeDays` |
| `CarPlay.connected` | CarPlay connects | `layout` |
| `Watch.command` | Browse, play or send-to-Watch from the Watch | `command`, `outcome` |
| `Watch.transfer` | A talk finishes transferring to the Watch | `outcome` |
| `WhatsNew.shown` | What's New appears | `version`, `skippedReleases` |

## Useful dashboard questions

| Question | Query |
| --- | --- |
| Most listened series and talks | `Listening.session`, group by `seriesName` or `discourseID`, sum of value |
| Where listeners stop | `Listening.session` with `completed = false`, by `minutes` |
| DeNoise adoption and mode | Distinct users on `TelemetryDeck.Session.started`, by `Settings.noiseReduction` and `Settings.noiseReductionMode` |
| Smart Download, Smart Delete, Shuffle Color Daily | Same, by the matching `Settings.*` parameter |
| Translation use and failures | `Translation.prepareFinished` by `outcome`, `targetLanguage`; `Listening.session` with `kind = translation` |
| Bookmarking | Distinct users sending `Bookmark.added` |
| Download health | `Download.failed` by `category` and `source` |

## Tests

`OshoDiscoursesTests/TelemetryServiceTests.swift`, `TelemetryPlaybackTests.swift` and
`TelemetryFeatureTests.swift` assert the signals and parameters through
`RecordingTelemetrySink`. They sit under one serialized parent suite
(`SharedTelemetrySuites`), because they route the shared service to a recorder.
Views (library search, filters, series visits, transcript actions, support sheet)
and live network transfers are checked by hand; see the release record.
