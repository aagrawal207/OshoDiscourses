# Translation and narrated playback

## Scope and baseline

The current listening interface and background-lifecycle fixes are recorded in
[Translation listening redesign](translation-listening-redesign.md). That record
supersedes the screen-owned preparation behavior described below. The updated
preview is installed; locked-phone preparation still needs physical verification.

This work restores the translation feature from `wip/translated-narration-1.16`
(`17c9039`) onto the submitted 1.16.3 source. The working branch is
`feature/translated-narration` in `OshoDiscourses-Translation`. The original
`OshoDiscourses-Swift` worktree and its submitted archive are untouched.

The base commit predates the uncommitted 1.16.3 changes. Those changes were copied
into this worktree before the port; `build/translation-baseline.json` records the
exact source snapshot. No release, upload, commit or push is part of this work.

The feature translates a source transcript with Apple Translation, then renders
ordinary system-voice audio. It does not clone Osho's voice. Saved audio can play
offline, with a translated reader and independent resume positions.

## Try locally

Open this worktree's `OshoDiscourses.xcodeproj` and run the `OshoDiscourses` scheme.
In the player, choose **Translate**, select a language and system voice, then
choose **Prepare narration**. Apple may need to download a language pack. Keep the
preparation screen open; locking the phone or switching apps keeps it going on iOS 26+.
**Pause and save** preserves completed work. Saved translations are listed in
**Downloads**, under their series, with unfinished ones under **In Progress**.

The local feature flag is `TRANSLATED_NARRATION_UI=TRANSLATED_NARRATION`. This is
not a new App Store submission. iPhone/iPad translation uses iOS 18+; native Mac
translation requires Catalyst 26, while the rest of the app keeps its older Mac
minimum. A ready narration remains separate from the original recording.

### Physical-device preview

With the owner's approval, **Osho Talks Preview** was installed as a separate
development app on the connected iPhone 16 Pro. Its identifier is
`com.agraabhi.oshodiscourses.translationpreview`. It has no shared iCloud,
application-group or Watch entitlements, and the original Osho Talks app record
was unchanged after installation. Its library and settings are separate.

The temporary app-only Xcode project is in `build/Preview/`, generated from
`build/Preview/preview-project.json`. Since the background-preparation work it is
installed as an optimized **Release** build (`Release-iphoneos` in
`build/PreviewDerivedData/`), still with `TRANSLATED_NARRATION` enabled. Launch automation was blocked by the
phone lock; the owner chose to open and test it manually. Native phone generation,
download consent, audible quality and background behavior are not yet recorded as
verified. No preview build was uploaded to App Store Connect or TestFlight.

## Integration boundaries

- Preserve current AppRuntime ownership, Watch/CarPlay, adaptive player and
  transcript copy/selection behavior. Do not restore old shared files wholesale.
- Keep translated IDs and positions separate from original recordings, history,
  statistics, cloud snapshots, bookmarks and smart download/delete actions.
- Saved narrations survive deletion or Smart Delete of the original recording.
  Their library owns deletion; returning to the original requires downloading it again.
- Reserve preparation before native consent/preflight. Only its owning window
  may cancel it. Closing the preparation screen pauses it; swipe-to-dismiss is
  disabled while preparing and Done asks first.
- Keep screen-awake requests scoped to their visible owners, including original
  transcript readers. One window closing must not clear another window's request.
- Suppress rating/support prompts during narration presentation and preparation.
  Existing 1.16.3 cooldowns and donor state remain unchanged.
- Apple Translation is available on iOS 18+, but the installed SDK requires
  Catalyst 26 for its native APIs. Preserve the app's Catalyst 18 minimum and gate
  those entry points. High-fidelity translation requires 26.4.
- The current Watch protocol does not support synthetic timelines. Do not publish
  translated seconds as original-discourse progress. CarPlay retains system
  transport but cannot bookmark synthetic audio or start preparation.

## Listening through translation

**A separate way to listen.** Translation needs only the transcript, so it no longer
starts from the player of a recording. A series page with transcripts has a
"Listen in" switch between its own language and the other catalog language
(English ↔ Hindi). In translated mode the recording actions and Download All are
hidden. Rows show the narration state (prepare, progress, ready) and open or play the
narration directly. Rows without a transcript are dimmed. Every row's menu also has
"Listen in Hindi…" (or English). The choice is stored per series; a series in a
language hidden by the content-language setting starts out translated. With one
content language selected, Library gains a "Translated to Hindi" (or English) chip
listing the hidden language's series that have transcripts. The player's globe
remains as a shortcut. `TranslatedListening` holds the rules.

**Osho's pace (default).** The rendering measured on the iPhone ran about 2.9× faster
than Osho: 544 s of Hindi for paragraphs that take 1,567 s in the recording. With
Osho's pace, each passage's target length is its share of the original paragraph's
duration. That comes from the shipped `AlignmentCatalog` through `TranscriptSyncModel`
(`NarrationOriginalTiming`, `NarrationPacingTargets`), so no audio download is
needed. The voice renders at 0.88× its default rate. `NarrationPausePacer` then
lengthens its existing pauses toward the target, weighted by pause length, with caps
of 3 s per interior pause and 6 s at the paragraph end. Speech samples are preserved.
Natural pace keeps the earlier output. Pace is part of `NarrationSelection`; saved
renditions without it decode as natural and keep their identity.

Measured on six real Hindi passages from the phone, before the caps were lowered
and the slower rate added: 22.8 s → 43.4 s and 24.2 s → 97.2 s, each within 0.3 s of
Osho's paragraph length. The 97 s passage had 14 pauses up to 8.3 s, which is why
the caps were lowered and part of the stretch moved into the voice rate. How it
sounds still needs the owner's ear on the device.

**One clock for both languages.** `NarrationTimeline` maps translated time to
original time piecewise between paragraph starts. "Return to Original" resumes the
recording at the matching moment. Starting a translation while its recording is
loaded begins at the matching passage. Bookmarks made while a translation plays are
saved on the recording at the matching moment. Listening statistics, history and
cloud progress remain separate.

**Controls.** Translated audio already used the player's speed and sleep timer;
DeNoise stays off for it. The translated reader now also has speed (the same
0.05-step control) and sleep timer buttons. The sleep timer UI is shared
(`SleepTimerControl`), and finishing a partial-then-complete narration counts as
the end of the discourse for the timer.

## Background preparation, partial listening and time left

**Background.** On iOS 26+, each preparation submits a `BGContinuedProcessingTask`
(`NarrationContinuedProcessing`) with a unique `<bundle>.narration.<UUID>` identifier,
allowed by `BGTaskSchedulerPermittedIdentifiers`. The system shows its progress as a
Live Activity on the Lock Screen and Dynamic Island. The request uses the `.fail`
strategy: if the system will not run it now, preparation still works in the
foreground and pauses when the app leaves the screen, as before. Expiry, including
the listener tapping Stop in the system UI, pauses and keeps finished passages.
Playback and audio interruptions no longer pause preparation; speech rendering does
not use the app's audio session.

**Partial listening.** Finished passages form a contiguous prefix. `NarrationPreviewPlayback`
joins their saved files into an `AVMutableComposition` without re-encoding, and
`AudioPlayerService.playNarrationPreview` plays it. The timeline belongs to one
document and passage count, so it cannot be reused for another rendition. Reaching
its end pauses and records a caught-up point; the next saved passage continues from
there, including after preparation is paused and resumed. Once the narration is
complete and fully heard, it finishes once with its position reset. Positions for a
partial rendition clamp to its finished passages.

**Time left.** `NarrationProgressEstimator` weights progress by source characters and
estimates from this run's speed only, after two passages and ten seconds. Earlier
saved passages count toward progress but not speed. The last share of progress is
reserved for joining the audio.

**Verification (2026-10-11).** Narration suites passed (`build/bg-narration-unit-r2.xcresult`).
The full unit suite outside the existing StoreKit fixture passed, 623 tests / 766 runs
(`build/bg-full-unit.xcresult`). Debug Catalyst compiled with only the existing
availability warning. An independent review found that caught-up playback did not continue
after a paused preparation resumed; that is fixed and covered. The Release preview was
installed on the iPhone 16 Pro and launched. The Live Activity, translation while locked
and partial playback on the device still need the owner's hands-on check.

**Measured on the iPhone 16 Pro (Debug preview, before this change).** Vigyan Bhairav
Tantra Vol 1 #1 has 109 passages. Audio rendering took about 1 second per passage;
each batch of four passages then waited 25-35 seconds for translation. Translation,
not speech, sets the pace: roughly 7-8 seconds per passage, or about 13-15 minutes
for this discourse. 24 passages (543 seconds of Hindi audio) were saved before the
screen locked.

## Metrics

The app uses local OSLog only. No text, customer IDs or remote analytics are added.

| Category | Emitted outcomes | Purpose |
| --- | --- | --- |
| Narration | Cache hit/miss/repair, reservation, checkpoint, retry, cancellation, ready/failure | Diagnose preparation and recovery |
| NarrationTranslation | Strategy, retry counts including zero, invalid responses, cancellation | Diagnose native translation without recording text |
| NarrationSpeech | Render/assembly/validation outcomes | Diagnose synthesis and saved audio |
| AudioProcessing | Synthetic bypass and playback failures | Keep translated audio separate from recording cleanup |
| ScreenAwake | Aggregate enabled/disabled transitions | Verify ownership without logging window IDs |
| Engagement | Narration presentation active/inactive | Verify prompt suppression |
| NarrationBackground | register rejected, submit submitted/failed (error code), launch running/stale, expire, end completed/stopped | Verify system background time without recording text |
| NarrationPreview | complete_narration, preview_started (passage count), nothing_ready, preview_failed, caught_up, finished | Diagnose partial listening |
| AudioProcessing | narration_preview_end | Distinguish the end of finished passages from the end of a narration |

## Test coverage

| Case | Coverage | Type |
| --- | --- | --- |
| Language availability, script matching, response ordering and retries | Restored language/translator tests | Unit |
| Unicode chunks, identity, pending text, cancellation, damaged checkpoints | Restored cache/service tests | Unit/local integration |
| AAC rendering and assembly | Restored speech renderer tests and native probe | Unit/native integration |
| Preparation reservation, other-window cancellation, retired preflight | New ownership tests | Unit |
| Original/synthetic switching, seeks, completion, resume, DSP and cloud isolation | Restored and extended playback tests | AVPlayer integration |
| Length-weighted progress, estimate thresholds, resumed-run speed, time wording | `NarrationProgressTests`, `NarrationServiceTests` | Unit |
| Background begin/update/complete, rejection fallback, expiry keeps passages | `NarrationServiceTests` with a fake activity | Unit |
| Playable prefix, partial positions, service events | `NarrationServiceTests` | Unit/local integration |
| Partial playback waits, continues with new passages, finishes once; resumes after a paused preparation; timeline not reused | `NarrationPlaybackTests` | AVPlayer integration |
| Real Live Activity, Translation while locked, expiry from the system UI | iPhone 16 Pro preview | Manual device |
| Multiple screen-awake owners and background reset | New screen-awake tests | Unit |
| Watch snapshot/control and CarPlay bookmark/queue guards | Extended companion tests | Unit/integration |
| Prompt suppression during presentation and synthetic playback | Extended engagement/rating tests | Unit |
| Captured first sheet, availability failure/retry, saved library, keyboard and large text | Restored UI scenarios | UI integration |
| Installed native translation, synthesis and saved reader | Native probes and simulator fixture workflow | Native/UI integration |

## Verification status

The core port is implemented and locally verified. It has not been released.
The old branch's recorded 451 functions / 581 runs are historical evidence, not
a passing result for this branch.

- Native macOS speech renderer: 20 tests passed through the production renderer.
- Native English-to-Hindi pipeline: nine original test paragraphs produced nine
  validated audio segments and a 77.48-second M4A. Cache reload/reuse and separate
  positions passed. One translation call and one render call ran at most at once;
  0.24 seconds of overlap was observed in this small test, not a throughput claim.
- The isolated Catalyst app also prepared that Hindi rendition through its real
  view-bound translation task. Accessibility inspection verified the saved reader,
  playback progress and a paused seek to passage six at 49.53 seconds.
- Native evidence is under `build/narration-translation-probe/` and
  `build/native-ui-evidence/`. Test paragraphs are explicitly not Osho quotations.
- A fresh installed-only Hindi-to-English request also returned a validated
  English translation (`build/native-hi-en.jsonl`).

| Check | Current result |
| --- | --- |
| Regression tests outside the existing StoreKit fixture | 615 functions / 758 runs passed, `build/translation-regression.xcresult` |
| Small iPhone presentation | 7 passed; the iPad-only keyboard case skipped, `build/translation-ui-mini-r2.xcresult` |
| Large iPhone saved reader | Both native-fixture tests passed: seeking, process relaunch, original playback and library opening, `build/translation-reader-large.xcresult` |
| Feature disabled | Both original visibility tests passed, `build/translation-ui-disabled.xcresult` |
| iOS Release compilation | Passed without warnings, `build/translation-release-device.xcresult` |
| Catalyst Release compilation | Passed; one redundant cross-platform availability warning and the existing native-library alignment warning |
| iPad presentation | All 8 scenarios passed, including keyboard dismissal, `build/translation-ui-ipad.xcresult` |
| iPad saved reader | Both native-fixture scenarios passed, `build/translation-reader-ipad.xcresult` |
| Final local Catalyst Debug app | Rebuilt with the isolated `com.agraabhi.oshodiscourses.translation-local` identifier |

Physical-device language-download consent, long-discourse wording/pronunciation,
sustained battery use and real device suspension still need verification. Mac
screen-recording permission was not enabled; its native UI was inspected through
accessibility instead.

### Existing StoreKit test limitation

The full run reached 619 test functions, with one failing function in
`AnnualSupportStoreKitTests.purchaseRenewalCancellationExpiryAndRelaunch`. The
simulated subscription remained active with a future expiration after the test
requested expiry. The same failure was recorded during 1.16.3 preparation.
Production support code and that test remain identical to the submitted baseline;
the other three StoreKit scenarios passed. The 615-function regression result
above excludes that four-test native fixture and does not claim it passed.
This fixture still needs investigation before another store release.

For a repeatable native check after installing the chosen language in the app:

```sh
python3 Tools/NarrationTranslationProbe/run.py --pipeline --target hi \
  --ui-fixture english-A_Bird_on_the_Wing__-1
```

The probe uses installed-only sessions and never requests a language download.
`Tools/NarrationTranslationProbe/seed-reader.py` verifies that report and its audio
hashes before copying the fixture to an explicitly listed test simulator. It
preserves unrelated data and uses a labelled silent WAV as the original recording.
`NarrationSavedReaderTests` opt into that fixture through `TEST_RUNNER_OSHO_NARRATION_*`
environment values; they do not run against ordinary listener data.
