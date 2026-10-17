# Translation listening redesign

The listener's task is to choose a language and voice and listen. Preparation,
saved versions and the transcript must not become three competing interfaces.
Existing translated audio, selections and positions are preserved.

## Implementation

- One listening screen leads with language, voice, an inline voice preview and
  pace, followed by Listen. It starts finished audio immediately and prepares
  the rest. Read along and saved variants are secondary.
- The series selector includes all supported target languages. Language choices
  persist per series and voice choices persist per target language/script. Old
  original/translated choices and saved audio identities are preserved.
- The window owns consent and preparation. iOS 26+ generation uses an independent
  installed-language TranslationSession after the foreground download/consent.
  Closing the listening sheet does not cancel preparation; scene disconnection,
  explicit Pause and unavailable/expired background time do.
- Removed the unconditional app-background and audio-interruption cancellations.
  Background state distinguishes requesting, granted, unavailable and paused,
  with the reason and actual Low Power Mode state. iOS 27 uses async submission.
- Delayed playback validates both the loaded-track generation and explicit
  playback intent, including lock-screen Pause, seeking and voice previews.

## Work ownership

- Coordinator: listening screen, preparation controller, integration and checks.
- Series selector worker: `ses_eccfc2420ffeHSg8P9VcIMjSXZ`; supported languages,
  per-series target preference and migration of the old original/translated switch.
- Voice picker worker: `ses_eccfc137effeE00ZwGe3dGCBfz`; audible voice comparison,
  selection persistence, no changes to the underlying listening position.
- Background investigation: `ses_eccfc5c4affeqmHTSgCQt9Lvpo`; device evidence and
  Apple's background/translation constraints. No claim of reliable locked-phone
  preparation until the physical-device workflow is verified.

## Metrics

The app uses local OSLog, not remote telemetry. Keep existing bounded
stage/outcome logs; do not add discourse IDs or transcript text.

| Signal | When | Fields | Purpose |
| --- | --- | --- | --- |
| Narration preparation | start, ready, pause, failure | stage, outcome | Trace ownership and resumability |
| Background processing | submitted, attached, rejected, expired | stage, outcome, system error code, power state | Explain why locked-phone work stops |
| Voice preview | State is directly observable; no remote telemetry | none | Test auditions do not overlap playback |

## Test coverage

| Case | Coverage |
| --- | --- |
| All supported target languages, retained series choice, old boolean migration | Unit and series UI |
| Voice selection, rapid audition changes, missing voice and explicit stop | Unit plus device audible check |
| Listen reuses matching audio, starts preparation otherwise, auto-starts first ready passage | Unit and UI |
| Dismiss/reopen preparation, one owner, stale completion ignored | Unit and UI |
| Lock/background with Low Power Mode on/off | Physical device; logs and saved-passage progress |
| Small/large layouts, appearance, large text, read-along remains optional | UI screenshots and interaction |

## Verification

- Full unit regression: 756 tests in 76 suites passed, excluding the existing
  simulator-only StoreKit expiry suite. The final direct progress callback then
  passed 75 targeted service/controller/playback tests, including its new test.
- Small iPhone UI: language switching, inline controls, voice picker and dark
  accessibility text passed. Screenshots in `build/listening-redesign-final-captures`.
- Simulator interface tests use `-debugNarrationOptions` to replace only Apple's
  unsupported simulator language-availability response. Voices remain actual
  installed voices; translation and speech rendering are not faked by that flag.
  Native availability/error screens are also covered without it.
- Large iPhone: two UI scenarios passed. iPad: voice flow, dark accessibility text
  and keyboard dismissal passed (three scenarios). No changes to other apps'
  simulators or data.
- Independent read-only review cleared the final ownership/playback guards.
- Signed Release preview 1.17.0 (36) built and installed on the owner's iPhone.
  Launch was denied because the phone was locked. This is not a successful
  runtime or background-verification result.
- Real consent and locked-phone preparation (including Low Power Mode on/off)
  are not yet verified. The earlier phone inspection found 37 of 109 passages and
  three pending translations; no user data was changed during diagnosis.
- Changes remain uncommitted in the translation worktree; nothing was pushed or
  submitted. Retained evidence: `build/listening-redesign-full-unit.xcresult`,
  `build/listening-redesign-final-targeted.xcresult`,
  `build/listening-redesign-ui-r3.xcresult`, `build/listening-redesign-ipad.xcresult`,
  `build/listening-redesign-large-phone.xcresult` and the current signed preview.
  Superseded failed test bundles and duplicate captures were removed; logs remain.

## Button review (build 38)

A tap-through of every listening control against a seeded native rendition
(`Tools/NarrationTranslationProbe/seed-reader.py`) found these and fixed them.
`NarrationListeningButtonTests` repeats the walk and passes on the iPhone mini,
iPhone Pro Max and iPad mini simulators. It runs only with the
`TEST_RUNNER_OSHO_NARRATION_*` fixture variables.

| Problem | Fix |
| --- | --- |
| A discourse with saved audio opened on the remembered voice/pace instead, so Listen started a new preparation from zero while the saved audio sat in a collapsed list | Opens on the playing, preparing or best saved version (complete first, then most passages) |
| Saved versions matched choices by exact struct equality, so a renamed voice never matched | `TranslatedListening.isSameVersion`: language/script, voice ID and pace |
| Language, voice, pace, preview and Osho's recording were greyed out during any preparation, which can run for many minutes | Always enabled; Listen on another version pauses the running one, and a note says so with a Pause it button |
| Speed and sleep timer opened as full-height sheets around popover-sized content | Popovers on their buttons, labelled "Speed 1×" and the timer's remaining time |
| After pausing, the button said "Listen in Hindi" again | "Resume"; a status line says Saved, N of M passages ready, or Not prepared yet |
| Saved rows had Listen/Pause/Resume/Rebuild/Delete side by side | One row to choose the version (the main button plays it) and a trash button that asks first |
| Playback controls sat below Read along, off screen on small phones | Transport sits right under the main button |
| Reader passages were disabled until something played, and a disabled "Return to Original" with explainer showed without a download | A passage starts playback from its beginning; the recording button shows only when the recording is downloaded |
| A voice preview failure was silent on the main screen; previews of another language read the saved Hindi text | Error shown under Preview; samples come from a saved passage in the voice's own language |

## Translate, then play (build 39)

Phone feedback on build 38: a translation stopped at 53 of 109 passages showed no
way to continue, translating with the phone locked usually stopped, and the
screen gave the most room to settings that are rarely changed.

- **Two actions.** Play only plays what is ready. Translate into X, Continue
  translating and Pause translating only translate. Neither starts the other.
- **Settings fold away.** Once a version exists, Language, Voice and Pace show as
  one line (`Hindi · Lekha · Natural pace`) with a small Change button.
- **Why it stopped.** The status says how many passages are ready and, for a run
  the app last owned, why and when it stopped.
- **Continues by itself.** `NarrationUnfinishedRun` (UserDefaults
  `narration.unfinishedRun`) remembers the last run. A run still marked running
  at launch was ended by iOS. Any stop the listener didn't ask for continues when
  the app is active again, up to three tries in a row that save nothing new.
- **Keeps going while listening.** Playing audio keeps the app running, so
  entering the background with audio playing no longer pauses translation, even
  without a continued-processing grant. Without audio, iOS can still suspend the
  app; the run then continues on return.
- **On-device record.** `NarrationJournal` keeps the last 400 events in
  `Library/Application Support/narration-journal.log`: starts, each saved
  passage with the background-time state, scene changes, stops with reasons, and
  error type and code (never text). Copy it from a phone with
  `xcrun devicectl device copy from --domain-type appDataContainer`.
- **Series rows.** A row with any passages ready shows Play, even while the rest
  is translating.

## Background progress (build 40)

The journal from build 39 showed iOS ending background time after about six
minutes, with the phone locked and no audio playing. Translation batches took
25-60 seconds each in the background but about 3 seconds in the foreground.
Progress was reported only once a passage was spoken, so each batch looked like
a stall. The run continued automatically when the app was opened and finished.

- A translated passage now counts as half done until it is spoken
  (`NarrationProgressEstimator.workFraction`), so iOS sees progress after each
  translated batch.
- When iOS ends the time, the Live Activity subtitle changes to "Paused at N of
  M passages. Open the app to continue." before the task is completed.

## Low Power Mode (build 41)

The build 40 journal showed Low Power Mode on for every run. iOS ended
background time 102, 29 and 2 seconds after the phone locked, sometimes before
any passage could finish. Reporting progress more often can't help there, so
the screen now says so. When translation is offered or running and Low Power
Mode is on, an orange note above the Translate button says: "Low Power Mode is
on. iOS stops translating soon after you lock the phone. Keep this screen open,
or listen while it translates." It updates when Low Power Mode changes.
Debug builds accept `-debugLowPowerMode` for simulator checks.

## No "Failed" on the lock screen (build 42)

iOS shows "Failed" on the continued-processing Live Activity whenever the task
is completed with `success: false`. The work is saved and continues later, so
`NarrationContinuedProcessing` now completes every ending with `success: true`.
A stop first sets the title to "Paused by iOS" (expiry) or "Translation paused"
(the app stopped it), the subtitle to "N of M passages ready. Open the app to
continue.", and the bar to full. This follows on-device measurements published
with github.com/aermes-ai/expo-continued-task. An Apple forum thread reports
that iOS can post its own failure for an expiry before the app's handler runs,
so the label may still appear in some expiries.

## Heat warning (build 43)

Whenever a version can be translated or is translating, the listening card's
footer says: "Translating uses a lot of processing power. Your phone may get
warm, and the battery may drain faster." It is hidden for finished translations.

## Tap to continue, and no lock-screen task in Low Power Mode (build 44)

On build 43 the title read "Paused by iOS", but iOS still added its own "Task
failed" line and a warning icon when it ended the task. The app can't change
that. Published measurements (blog.aermes.ai, "What iOS 26 background tasks
actually do") also show that continued-processing work submitted without a
person's tap is suspended and expires. So, as the owner chose:

- **No automatic restart.** After iOS stops a translation, the screen says
  "Paused by iOS at 9:51 PM", and Continue translating picks up from the
  last saved passage. The automatic-continue code and its attempt limit are
  removed; `NarrationUnfinishedRun` now records only what stopped and when.
- **No lock-screen task in Low Power Mode.** `beginBackground` doesn't ask
  for continued processing when Low Power Mode is on
  (`NarrationBackgroundReason.lowPowerMode`). Translation runs while the
  screen is open or audio plays, and pauses when the listener leaves, with no
  "Task failed" banner.

## No lock-screen notification (build 45)

The owner chose to drop the lock-screen notification entirely, since iOS adds
"Task failed" and a warning icon whenever it ends that task.

- `NarrationContinuedProcessing` and the `BGTaskSchedulerPermittedIdentifiers`
  entry are removed. `NarrationGraceTime` uses `beginBackgroundTask`: about 30
  seconds after the app leaves the screen, with no banner.
- While audio plays, the app keeps running, so an expired grace period doesn't
  stop translation (`audioKeepsAppRunning`). Returning to the screen renews it
  (`renewBackgroundTimeIfNeeded`).
- Translation continues by itself from the last saved passage whenever the
  app is on screen and a run iOS stopped is waiting. The check also runs when a
  run stops while on screen. A listener's own pause never continues by itself,
  and three tries in a row that save nothing new stop the retries.
- The listening card says: "iOS stops translating soon after you leave the app
  or lock the phone. If you play the translation, it keeps translating in the
  background. When you come back, it continues from where it stopped." The Low
  Power Mode note is gone, since every run now gets the same short grace time.
