# Usage telemetry

Osho Talks sends anonymous usage data to [TelemetryDeck](https://telemetrydeck.com/)
from 1.17.2. It shows which features, settings and talks listeners use.

| Item | Value |
| --- | --- |
| SDK | TelemetryDeck SwiftSDK 2.14.2 (`project.yml` package, iOS app target only) |
| App ID | `584A18B7-DDF4-4BF5-9A28-C687DCEB6489` |
| Namespace | `com.abhishekagrawal` |
| Code | `Services/TelemetryService.swift` (the only caller of the SDK), `TelemetrySignals.swift` (events, counted parameters), `TelemetryDeckSink.swift` |
| Switch | Settings > About > Share Anonymous Usage Data (`settings.shareUsageData`, on by default). Off stops the SDK and discards counted usage |
| Debug builds | Signals are marked as test data; view them with Test Mode on in the dashboard. Unit tests never start the SDK |
| Free plan | 50,000 signals a month |

## Counted on the device, sent as a summary

Code reports events as they happen (`TelemetryService.send`, the listening calls).
The service counts them on the device and saves the counts in `UserDefaults`
(`telemetry.pending.v1`). It sends them only as:

| Signal | When | Content |
| --- | --- | --- |
| `Usage.summary` | When the app leaves the screen, returns or launches, if there is counted usage and the last summary is at least 12 hours old | One parameter per counter (exact up to 99, then `100+`), `<name>.minutes` for timed counters, library sizes (`Library.*`), `trigger`, `periodHours`. Value = minutes listened |
| `Listening.talk` | With each summary, one per talk heard for at least 1 minute or finished, at most 10 | Discourse parameters, `kind`, `sourceLanguage`/`targetLanguage`, `completed`, `starts`, `minutes`. Value = seconds heard |
| `Support.purchase` | At once (`TelemetryService.immediateSignals`) | `product`, `kind`, `outcome`, `failure` |
| `TelemetryDeck.Purchase.completed` | At once, for a verified tip or new subscription (SDK preset) | `kind`, `source` |

The SDK's own `TelemetryDeck.Session.started` is off (`sendNewSessionBeganSignal = false`);
it would cost a signal on every foreground. Daily users come from `Usage.summary`.
A listener costs about one summary plus one or two talks per day, so the free plan
covers roughly 1,500 monthly listeners.

## Rules

- Never record free text: no bookmark notes, custom category names, search text,
  transcript text, file paths, URLs or error messages.
- Counter values (`TelemetrySignal.countedDimensions`) must come from closed sets:
  enum raw values, booleans, language codes, buckets. Discourse IDs go only into
  `Listening.talk`.
- Add an event by adding a `TelemetrySignal` case and its counted dimensions. Do
  not add immediate signals for frequent events.

## Parameters on every signal

Settings (`TelemetryParameters.settingsContext`): `deviceFamily` (iPhone, iPad, mac),
`Settings.noiseReduction`, `Settings.noiseReductionMode` (deepFilterNet = Best
Quality, rnnoise = Balanced, cadence = Gentle Cleanup), `Settings.denoiseStrength`,
`Settings.voiceFocusPreset`, `Settings.volumeBoost`, `Settings.smartDownload`,
`Settings.smartDelete`, `Settings.autoPlayNext`, `Settings.allowCellularDownloads`,
`Settings.appearance`, `Settings.accentTheme`, `Settings.dailyAccentShuffle`,
`Settings.languageFilter`, `Settings.defaultPlaybackRate`,
`Settings.transcriptSentenceLayout`, `Settings.transcriptFontSize`,
`Settings.transcriptSpeechSync`.

`watch` (`WatchLinkState.telemetryLabel`): `appInstalled`, `notInstalled`,
`notPaired` or `unsupported` (iPad, Mac).

## Summary counters

Each event adds `<Event>` and, per counted parameter, `<Event>.<parameter>.<value>`.

| Event | Counted parameters | Recorded at |
| --- | --- | --- |
| Listening (built-in) | `Listening.minutes`, `Listening.original.minutes`, `Listening.translation.minutes`, `Listening.starts.<reason>` (user, next, previous, queueItem, autoAdvance, restored, bookmark), `Listening.completed`, `Listening.skipsForward`, `Listening.skipsBack`, `Listening.seeks` | Player start, finish, switch, stop, background |
| `Playback.speedChanged` | none (speed is in the settings) | Speed settles for 2 s |
| `Playback.failed` | `category` | Item fails |
| `SleepTimer.started` / `.cancelled` | `option` | Listener sets or cancels |
| `Download.completed` | `origin` (user, downloadAll, smartDownload, unknown), `source`, `fallback` | Download saved |
| `Download.failed` | `origin`, `category` | Download fails |
| `Download.allRequested` | none | Download All confirmed |
| `Download.deleted` | `reason` (user, smartDelete), `scope` | Delete |
| `Translation.prepareStarted` | `targetLanguage`, `automatic`, `resumed` | Preparation starts |
| `Translation.consent` | `result` | Apple's language prompt |
| `Translation.prepareFinished` | `outcome`, `stage`, `reason`, `targetLanguage`; minutes | Run ends |
| `Translation.deleted` | none | Saved translation deleted |
| `Bookmark.added` | `hasNote`, `category` | Listener adds (not iCloud merges) |
| `Bookmark.deleted`, `Bookmark.opened` | `from` for opened | Bookmarks |
| `Transcript.opened` | `presentation`, `outcome` | Reader loads |
| `Transcript.searched`, `Transcript.action` | `action` | Reader |
| `Settings.changed` | `setting` | Any setting change except speed |
| `Library.searched` | `results` | Typing stops for 1.5 s |
| `Library.filterSelected` | `filter` | Chip tapped |
| `Series.opened` | none | Series page appears |
| `Support.sheetOpened`, `Support.prompt` | `action` for prompt | Support |
| `Review.requested`, `WhatsNew.shown` | none | System prompt asked, What's New appears |
| `CarPlay.connected` | `layout`; `CarPlay.listening.minutes` counts listening while connected | CarPlay |
| `Watch.command` | `command` (every command except snapshots: play/pause, skips, next, speed, browse, play item, send to Watch) | Watch remote |
| `Watch.transfer` | `outcome` | Talk sent to the Watch |
| `Watch.offlineListening` | `finished`; minutes = forward distance from the phone's last position, up to 4 hours | Watch reports a position after listening without the phone |

## Useful dashboard questions

| Question | Query |
| --- | --- |
| Most listened series and talks | `Listening.talk`, group by `seriesName` or `discourseID`, sum of value |
| Where listeners stop | `Listening.talk` with `completed = false`, by `minutes` |
| Daily and monthly listeners | Distinct users sending `Usage.summary` |
| DeNoise adoption and mode | Distinct users on `Usage.summary`, by `Settings.noiseReduction` and `Settings.noiseReductionMode` |
| Smart Download, Smart Delete, Shuffle Color Daily | Same, by the matching `Settings.*` parameter |
| Apple Watch owners and users | Distinct users by `watch = appInstalled`; with `Watch.command` or `Watch.offlineListening` above 0 |
| CarPlay users | Distinct users with `CarPlay.connected` above 0 |
| Bookmarking | Distinct users with `Bookmark.added` above 0 |
| Translation use and failures | `Translation.prepareFinished.outcome.*` counters; `Listening.talk` with `kind = translation` |
| Download health | `Download.failed.category.*` and `.origin.*` counters |

## Tests

`OshoDiscoursesTests/TelemetryServiceTests.swift`, `TelemetryPlaybackTests.swift` and
`TelemetryFeatureTests.swift` assert each event and its parameters through
`RecordingTelemetrySink` (`signals` = events, `sent` = what reaches TelemetryDeck),
and the summary rules in `TelemetryServiceTests`. They sit under one serialized
parent suite (`SharedTelemetrySuites`), because they route the shared service to a
recorder. Views and live network transfers are checked by hand.
