# Osho Talks on Apple Watch

The Watch app browses and controls playback on the paired iPhone, and keeps
downloaded discourses on the Watch for offline listening. Both apps ship
together and speak one wire contract.

## Protocol

`Shared/Companion/CompanionProtocol.swift` is compiled into both targets and owns
every wire model. `CompanionWire.version` is **1**; a peer with another version is
rejected, never interpreted. Requests, replies, snapshots, position reports and
file metadata are JSON `Data` of at most **60 KiB** (`maximumPayloadBytes`), checked
before decoding and after encoding.

| Channel | Direction | Payload |
| --- | --- | --- |
| `sendMessageData` with reply | Watch -> iPhone | `CompanionRequest` -> `CompanionResponse` |
| `updateApplicationContext` | iPhone -> Watch | `[osho.snapshot.v1: CompanionSnapshot]` |
| `transferFile` | iPhone -> Watch | audio file + `[osho.offline.v1: CompanionOfflineFile]` metadata |
| `transferUserInfo` | Watch -> iPhone | `[osho.position.v1: CompanionPositionReport]` |

Only `sendMessageData` carries requests; the phone does not implement the
dictionary `sendMessage` callbacks.

- **Correlation.** Every request has a fresh `id`; the response echoes it as
  `requestID`. Malformed or oversized input, or a request past the phone's reply
  deadline, gets an **empty** reply because nothing can be correlated. A decoded
  request with another `version` gets a correlated rejection.
- **Reads and mutations.** `snapshot` and `browse` are read-only and may be
  retried. Everything else is sent once and never retried automatically.
- **Stale-state guard.** Transport actions (`setPlaying`, `skipForward`,
  `skipBackward`, `nextDiscourse`, `previousDiscourse`, `setRate`) must carry
  `expectedDiscourseID`, the discourse the Watch displayed. A missing or different
  id is rejected with an `errorMessage`, so a tap made against old state never
  lands on another talk. There is no lease.
- **Rows.** Row ids are opaque to the Watch (`d:`, `b:`, `s:` prefixes) and sent
  back unchanged in `playItem`; the phone resolves them against its current state.
- **Inventory.** Each request may carry `watchInventory`, the discourse ids stored
  on the Watch, so pages mark `isOnWatch` and the phone skips redundant transfers.
- **Snapshots.** `sessionID` identifies one phone process; `sequence` increases
  within it whenever snapshot content changes. `accentName` is the phone's
  effective `AccentTheme` raw value. Positions are a phone-side sample; the Watch
  interpolates from its own receipt clock.

## iPhone side

Files: `OshoDiscourses/Companion/Watch/` and `OshoDiscourses/Views/Watch/AppleWatchView.swift`.
Everything is compiled only where `WatchConnectivity` exists and not on Mac
Catalyst; Catalyst gets a no-op `WatchPhoneSession.start(runtime:)`.

`OshoDiscoursesApp.init` calls `WatchPhoneSession.shared.start(runtime:)` after
`AppRuntime.start()`. Start is idempotent. Under an XCTest host the session uses an
inert transport, so tests never activate the user's real session; setting
`OSHO_WATCH_SESSION_IN_TESTS=1` opts a deliberate paired test back in.

### Connection

`WatchConnectivityTransport` owns `WCSession.default`. Its delegate callbacks are
nonisolated and yield Sendable events into one `AsyncStream`, consumed on the main
actor in delivery order. No `WCSession`, `[String: Any]` or framework error crosses
an actor boundary. The SDK reply block is held by `WatchReply`, a lock-protected,
single-use wrapper that also answers empty data after a **6-second** deadline.
`sessionDidDeactivate` reactivates the session for the newly selected Watch.

Link state is `ready(paired:installed:reachable:)` once activated. Context and
file transfers need a paired Watch with the app installed; position-only
publication also needs reachability.

### Requests

`CompanionRequestHandler` runs each request synchronously on the main actor
against `WatchPlaybackSurface`, which the app implements over `AppRuntime`
(`AudioPlayerService`, `PlaybackLauncher`, `CompanionLibrary`). The reply deadline
is checked before and after decoding, so an expired request never starts a change.

| Action | Phone behavior |
| --- | --- |
| `snapshot` | Snapshot only |
| `browse(location)` | Snapshot + `CompanionLibrary.page`, at most 60 rows |
| `setPlaying(Bool)` | Play or pause the loaded discourse. It carries the chosen state rather than a toggle, so a late or repeated delivery cannot flip playback back |
| `skipForward` / `skipBackward` | 30 s forward / 15 s back |
| `nextDiscourse` | Next queued discourse; rejected at the end of the series |
| `previousDiscourse` | Restart, or previous discourse within 3 s of the start |
| `setRate` | Clamped to 0.5-2x; non-finite rates are rejected |
| `playItem(rowID)` | `PlaybackLauncher.playDiscourse` / `playBookmark`; series rows are rejected |
| `sendToWatch(discourseID)` | Queues a file transfer (below) |

Transport actions are rejected when nothing is loaded. Launcher and transfer
failures map to their listener-facing `message`. Browse replies stay under the
payload bound: if the encoded response exceeds the budget, row titles are cut to
80 characters and subtitles to 60, then rows are dropped from the end with
`isTruncated` set.

The handler keeps receipts for the last **64** request ids. A resend with the
same id, action and expected discourse returns the cached response without
running again; the same id with a different action is rejected. Receipts live in
memory only, so idempotency does not survive eviction or a phone relaunch.

### Now Playing publication

`WatchPhoneSession` observes the player (track, title, play state, rate, time,
duration, queue position), the sleep timer and the accent, and publishes one
`CompanionSnapshot` through application context:

- Track, play state, rate, duration, next/previous availability, sleep timer and
  accent changes publish immediately, including while the Watch is unreachable.
- Position-only changes publish at most every **10 s** and only while reachable,
  with one trailing update carrying the latest position.
- A failed context update retries on the same 10-second cadence.

The sleep timer label is minute-granular ("12 min", "End of discourse"), so a
countdown changes the snapshot once a minute rather than every second.

### Offline files

`WatchTransferService` handles `sendToWatch`. It refuses unknown or undownloaded
discourses, an unpaired Watch, a missing Watch app and an inactive session, each
with its own message. A discourse already on the Watch or already in flight
(including transfers from earlier launches, read back from
`outstandingFileTransfers`) is not sent again.

The download is cloned into `Caches/WatchTransfers/` and the clone is
transferred, so Smart Delete or a manual delete during the transfer cannot break
it. Metadata carries the title, series, current saved position and duration.
Finished transfers delete their clone; a success adds the id to the inventory
until the Watch's next report, which is authoritative.

The last inventory the Watch reported is saved under `watch.inventory.v1`.
**Deleting a download on iPhone does not remove the Watch copy**; the Watch owns
its storage.

### Position reports

`WatchPositionMerger` applies `CompanionPositionReport`s to
`PlaybackStateService`:

- An unfinished report saves position and duration and records a play, so the
  discourse surfaces in Continue Listening.
- A finished report marks the discourse listened-complete and clears its
  position, matching a natural finish on iPhone.
- A report arrives once and can arrive late, so it applies only when it is newer
  than this phone's own listening. `PlaybackStateService` records when the phone
  last moved each discourse's position (`playbackSavedAt_<id>`); an autosave of an
  unchanged, paused position does not count, and neither does a position merged
  from iCloud. A report recorded at or before that time is ignored.
- A report usually arrives because the phone app just woke, often because the
  listener pressed play there. So a report for the playing discourse still moves
  it, with position history, when that play stretch began under 60 s ago, from an
  older point at least 5 s behind the report, and after the report was recorded,
  with no phone listening between them (`AudioPlayerService.PlaySession`).
  Otherwise reports for a playing discourse are ignored, and a finished report
  never stops one.
- A discourse loaded but paused on iPhone takes the reported position, and the
  paused player moves there so its autosave cannot write the old position back. A
  finished report unloads the paused talk, like a natural finish.
- Pausing saves the position at once, so the newest phone listening reaches the
  Watch in the pause snapshot. Snapshots carry `savedPositions` for discourses in
  the Watch's last inventory (stored values and save times, newest 100); changes to
  them alone are not semantic. Offline-file metadata carries `resumeSavedAt`.
- A report no newer than the last one applied for that discourse is ignored. The
  map of `recordedAt` values is saved under `watch.positionApplied.v1` (newest
  200 discourses).
- Unknown discourses, malformed data and non-finite or zero positions change
  nothing.

Applied reports trigger the normal iCloud push.

### Apple Watch screen

`AppleWatchView` lists discourses on the Watch, transfers in progress and failed
transfers, with pairing or installation guidance when needed. Discourses are
chosen on the Watch; the phone screen only reports.

### Logging

Local OSLog, subsystem `com.agraabhi.oshodiscourses`, category `WatchSession`:
link state, request outcome by action kind, transfer queued/finished/failed and
position-report outcome. No ids or titles are logged.

### Tests

| Suite | Covers |
| --- | --- |
| `WatchPhoneSessionTests` | Malformed, oversized, version-mismatched and expired requests; cached resend; browse payload bound; position throttling with trailing update; immediate semantic changes; unreachable and uninstalled publication; context retry; report routing |
| `WatchRequestHandlerTests` | Expected-discourse guard; rate clamp; end of series; `playItem` routing and launcher messages; reused ids; receipt window bound; snapshot sequencing; inventory propagation; text shortening before truncation |
| `WatchTransferTests` | Staged copy and metadata, including `resumeSavedAt`; dedupe by outstanding and inventory; a queued talk stays sending while the session's list lags; failure messages; finish/failure handling; inventory persistence; staged-file cleanup timing |
| `WatchPositionMergerTests` | Newer applies; older ignored across relaunch; phone listening after the report wins, but autosave of an unmoved position and iCloud merges do not count; playing discourse protected except a just-resumed stretch, which catches up; paused loaded discourse moves, or unloads on finish; invalid reports |

The suites use injected transport, scheduler, clock and transfer library, with
isolated `UserDefaults` suites and test-owned `PlaybackStateService` instances.
The paired-simulator run below exercises this side through real WatchConnectivity.

## Watch app

Target `OshoDiscoursesWatch` (watchOS 11+, `WatchApp/Sources`, `WatchApp/Resources`,
`Shared/Companion`). It links only Apple frameworks and the shared contract; no
catalog or phone service is compiled in.

| Folder | Contents |
| --- | --- |
| `Connectivity/` | `WatchTransport` protocol and clock, `WatchConnectivityTransport`, `WatchRequestClient`, `WatchSnapshotState` |
| `Model/` | `WatchCompanionModel` (remote), `WatchAccent`, `WatchAppSession` (process-owned objects) |
| `Offline/` | `OfflineFileStore`, `OfflineLibrary`, `OfflinePlayer`, `PositionReporter` |
| `Views/` | Root list, players, phone library pages, saved talks |
| `Debug/` | `--watch-fixture` transport and seed data, compiled only in DEBUG |

### Navigation

A `NavigationStack` with a list root, in the manner of Podcasts on Apple Watch:

1. **Now playing.** A row for the Watch's own player (when a talk is loaded) and
   one for the iPhone (title, "On iPhone" or "Last seen on iPhone"). Without a
   phone snapshot the connection message sits here instead.
2. **iPhone.** Continue Listening, Downloads (series, then discourses) and
   Bookmarks, loaded with `browse`.
3. **On Watch.** Saved Talks, with count and storage used.

When the iPhone is unreachable and talks are saved, On Watch moves to the top,
because saved talks are then the only thing that can play.

Choosing a discourse or bookmark sends `playItem(rowID:)`; on success the Watch's
own player pauses and the stack becomes `[iPhone player]`. Series rows open
`browse(.series(rowID))`. Discourse rows offer **Save to Watch** as a swipe action
and a VoiceOver action, hidden once the talk is on the Watch or being sent.

Both players share one layout: title (2 lines), series, then skip back 15 /
play-pause (52 pt) / skip forward 30 (44 pt minimum), progress with elapsed and
remaining time in monospaced digits, and a status line with the sleep timer. The
iPhone player's second row has previous talk, speed (0.5-2x list) and next talk.
The Digital Crown scrolls; it is not taken for volume. On the Watch SE 3 (40 mm)
the transport row is fully visible before scrolling, including at
accessibility-large text.

The accent follows `CompanionSnapshot.accentName` (the eight `AccentTheme` raw
values map to SwiftUI system colors). It is applied as `tint` and as the
navigation bar's foreground style, saved under `osho.watch.accent`, and defaults
to orange. Missing or unknown names keep the current accent; only snapshots the
timeline accepts can change it.

### Connection and requests

`WatchConnectivityTransport` sets a nonisolated delegate on `WCSession.default`.
Callbacks yield Sendable events into one `AsyncStream` consumed on the main actor;
the reply closures are created in a nonisolated helper. `WatchAppSession.shared`
owns the transport, client, model, offline store and player, so view recreation
never replaces the delegate. `.backgroundTask(.watchConnectivity)` activates the
session, waits up to 8 s for `hasContentPending == false` (files and context drain
through the delegate meanwhile) and then reads the retained context.

`WatchRequestClient`:

- Correlates replies by `requestID`; rejects malformed, mismatched and other-version
  replies.
- Has an **8 s** deadline per request, checked again against the monotonic clock
  when a late reply arrives.
- Allows up to four requests in flight but only **one mutation**. A second
  mutation is refused as busy, not queued.
- Never resends a mutation. Losing reachability retires every pending request.

`WatchCompanionModel` sends `watchInventory` (the ids in the offline store) with
every request. Transport actions carry `expectedDiscourseID` from the displayed
snapshot and are also checked locally against the newest snapshot before they
leave (`setPlaying` additionally checks the play state). `playItem` and
`sendToWatch` carry no expected discourse, since a choice from a list is not tied
to what is playing. Displayed state changes only when the phone replies.

A mutation whose outcome is unknown (timeout, delivery failure, invalid or
mismatched reply, lost connection or cancellation after dispatch) disables every
control, cancels other requests and sends a fresh `snapshot` read. Controls return
when that read is accepted; the listener sees "Updated from iPhone. Check the
player before trying again." A phone `errorMessage` is shown as given.

`WatchSnapshotState` orders snapshots by `(sessionID, sequence)`. Older and
duplicate sequences cannot rewind the display. Application context cannot
introduce a new phone process; a correlated reply must, after which the old
process is rejected for 20 s. The newest context from an unconfirmed process is
held, not dropped: when a reply confirms that process, the held context wins if
its sequence is higher. After a phone relaunch, the new process's "now playing"
context often arrives before the first reply, whose content predates it, and
WCSession never resends that context. Position interpolates on the Watch's monotonic
clock at the snapshot's rate, only while confirmed, reachable, foreground and
playing, and clamps to duration. A read-only heartbeat runs every **12 s** in the
foreground. Confirmation lasts **20 s**; after that, or when unreachable or
backgrounded, the position freezes and the player shows "Last seen on iPhone"
with controls disabled.

Distinct copy: "Install Osho Talks on iPhone", "Unlock your iPhone", "Open Osho
Talks on iPhone" (unreachable, inactive), "Connecting to iPhone…", "Loading from
iPhone…", the page's `emptyMessage`, the phone's `errorMessage`, "Still waiting
for iPhone…" (busy) and "Sending from iPhone…" for transfers.

### Offline listening

`session(_:didReceive:)` calls `OfflineFileStore.receive` synchronously, because
the system deletes the incoming file when the callback returns. The store is
lock-protected and owns `Application Support/Offline/`:

- Audio is moved to `<sanitized id>.<ext>` (`mp3`, `m4a`, `aac`, `wav`, `caf`;
  anything else becomes `mp3`). Ids are reduced to `[A-Za-z0-9_-]` with an FNV
  suffix when changed, so distinct ids cannot collide.
- The directory, each file and `index.json` are excluded from backup.
- Re-sending a talk replaces its audio and keeps the newer progress: local, or
  the file's `resumePosition` stamped `resumeSavedAt`. Missing metadata rejects
  the file.
- On launch, entries whose audio is gone are dropped and audio without an entry
  is deleted.

The phone cannot report outgoing transfers to the Watch, so a talk the phone
accepted for sending during this launch shows "Sending from iPhone…" until its
file lands. Saved Talks lists title, series, progress and time left, with swipe
to remove, and storage used in the header.

`OfflinePlayer` uses `AVPlayer` with `.playback` / `.spokenAudio` /
`.longFormAudio` and `activate(options:)`, which shows the system route picker.
A false or failed activation shows "Connect Bluetooth headphones to listen on
Apple Watch." Playback resumes from the saved position (seeded from
`resumePosition`), starting over when finished or within 5 s of the end. It
supports skip 15/30, speed (saved under `osho.watch.offlineRate`) and
`MPRemoteCommandCenter` / `MPNowPlayingInfoCenter`, so the system Now Playing
controls work. An audio interruption pauses.

The position is saved every 10 s while playing, on pause, at the end and when
the app moves to the background. A save restamps the entry's `positionUpdatedAt`
only when the position moved at least 1 s or the talk finished. A
`CompanionPositionReport` goes out with `transferUserInfo` on pause and finish
(marked `finished`) and at most every 60 s while playing, only for a new stamp,
and is recorded at that stamp. When the session cannot take a report, the newest
per talk is held and sent once it activates.

Progress flows both ways and the newer side wins. The Watch adopts each
`savedPositions` entry from any phone reply or context whose `savedAt` is newer
than its own stamp, and never reports it back; the phone applies a Watch report
only when it is newer than its `playbackSavedAt_<id>`. A talk loaded in the local
player, playing or paused, is never moved; it catches up when released or reloaded.

### Debug fixtures

DEBUG builds accept `--watch-fixture playing|paused|empty|disconnected|offline`.
They use an in-memory phone, a throwaway store under
`tmp/OshoWatchFixture-<mode>/` with silent seeded audio and a separate defaults
suite, so real data is untouched. `--watch-route home|player|offline|local|continue|downloads|bookmarks`
picks the opening screen (`local` also starts the first saved talk);
`--watch-accent <name>` sets the fixture phone's accent. `sendToWatch` delivers
the file three seconds later. The fixture phone sends `savedPositions` newer than
the seeded Watch copies of The Mustard Seed #3 and Ek Omkar Satnam #4 (finished),
so every launch adopts them. A Release build contains no fixture symbols or
strings.

### Watch tests

`OshoDiscoursesWatchTests` (Swift Testing, scheme `OshoDiscoursesWatch`):

| Suite | Covers |
| --- | --- |
| `CompanionProtocolTests` | Round trips for every action, page, offline metadata and saved positions; optional `savedPositions`; 60 KiB bound both ways; read-only actions |
| `WatchRequestClientTests` | Out-of-order correlation; foreign, malformed and other-version replies; timer and monotonic deadlines; one mutation with reads alongside; no resend after failure; unreachable without queuing; retirement on lost reachability; dispatch veto; context decoding |
| `WatchSnapshotStateTests` | Rate interpolation, paused, clamp, freeze on disconnect and background, 20 s expiry, unconfirmed context, stale and duplicate sequences, new and retired process, time formatting |
| `WatchCompanionModelTests` | Inventory on every request; expected discourse and no optimistic flip; ambiguous failure and timeout disable controls and refresh without resending; local stale rejection; phone rejection copy; `playItem` routing; Save to Watch pending until arrival; page storage; last-seen freeze; connection copy |
| `OfflineFileStoreTests` | Move, backup flag and index; bad metadata; resend keeps the newer progress; delete; reconciliation on launch; id sanitizing; start position; newer phone progress adopted, older or equal ignored, loaded talk skipped, phone finish; index without stamps; restamp only on movement |
| `PhoneProgressTests` | Loaded talk catches up on release; replies and contexts, including a held new phone process, all feed adoption; nothing adopted is reported; only new listening is reported, and its echo is not taken back |
| `PositionReportPolicyTests`, `PositionReporterTests` | 60 s throttle; pause and finish; encoding; held reports flushed newest-per-talk |
| `WatchAccentTests` | Mapping, orange default, unknown names, persistence from accepted snapshots |

`OshoDiscoursesWatchUITests` (XCTest, scheme `OshoDiscoursesWatchUI`) runs the
fixtures: first-viewport transport geometry, play-pause waiting for the reply,
choosing a row, Save to Watch through arrival, removing a saved talk and the
disconnected layout.

```sh
xcodebuild -project OshoDiscourses.xcodeproj -scheme OshoDiscoursesWatch \
  -destination 'id=<watch-sim>' -derivedDataPath build/DerivedData-watchapp test
xcodebuild -project OshoDiscourses.xcodeproj -scheme OshoDiscoursesWatchUI \
  -destination 'id=<watch-sim>' -derivedDataPath build/DerivedData-watchapp \
  -collect-test-diagnostics never test
```

## Paired-simulator run

`WatchUITests/OshoWatchConnectivityUITests.swift` uses real WatchConnectivity and
skips unless `OSHO_WATCH_INTEGRATION=1` reaches the test process:

```sh
P=45722FC2-EE56-410C-A8E1-5ADFAC08565E   # Osho iPhone 17 Pro
W=48797CD8-0154-46F5-8A4C-EA7C684E1663   # Osho Watch 46mm, paired with P
# Seed A Bird on the Wing #1-#3 on the phone (CLAUDE.md, "Seed a simulator download").
xcrun simctl launch --terminate-running-process $P com.agraabhi.oshodiscourses \
  -debugTranscript english-A_Bird_on_the_Wing__-1 -debugPlayer
TEST_RUNNER_OSHO_WATCH_INTEGRATION=1 xcodebuild -project OshoDiscourses.xcodeproj \
  -scheme OshoDiscoursesWatchUI -destination "id=$W" -derivedDataPath build/DerivedData-watch \
  test -only-testing:OshoDiscoursesWatchUITests/OshoWatchConnectivityUITests \
  -collect-test-diagnostics never
```

It pauses and resumes the phone from the Watch, opens Downloads, a series and
a discourse, requests Save to Watch, and plays the discourse on iPhone from the
row. Simulator WatchConnectivity often takes 4 to 12 seconds per message and
drops reachability, so the test waits for controls to re-enable before each tap
and allows 30 seconds per confirmed reply. In the final build it passed 3 of 4
runs, each after a fresh phone relaunch. The failed run lost reachability while
opening Downloads, and the Watch showed "Couldn't reach Osho Talks on iPhone"
with Try Again, as designed. The simulator never delivers `transferFile` to the
Watch app although the phone reports the transfer finished, so the test stops at
"Sending from iPhone".

Earlier runs found two problems, both fixed: after a phone relaunch the Watch
kept the old process's context (see held context above), and a late toggle could
flip playback back after the Watch had given up on it, which `setPlaying(Bool)`
replaces.

Not yet verified: file delivery, Bluetooth routing and background audio on a
physical Watch, position reports reaching the phone, VoiceOver walkthroughs and
Always On appearance.
