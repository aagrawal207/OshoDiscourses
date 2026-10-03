# Noise Reduction Lab

## 2026-09-15: DeNoise interface

Player > DeNoise and Settings > DeNoise open the shared
`AudioEnhancementView`. The Enable DeNoise switch controls recording noise reduction
and enables the saved boost level. Turning it off plays the original sound.
Transcript is beside DeNoise in the player's bottom row. The compact controls cap
Dynamic Type at xxxLarge so their labels fit on narrow screens.
Settings supplies extra bottom scroll-content clearance to DeNoise and its mode
and quiet-speech pages, allowing their last items to scroll above the mini-player.

| Listening mode | Implementation | Position in the interface |
| --- | --- | --- |
| Best Quality | DeepFilterNet 3 | Recommended, with a visible “Uses more battery” note |
| Balanced | RNNoise | Secondary option with lighter processing |
| Gentle Cleanup | Cadence filter | Secondary option for hum and noise in pauses |

First-use settings are Best Quality, Medium noise reduction, Medium volume boost
(2×) and Gentle Lift. DeNoise starts off. Registered defaults apply when a setting
has no saved value. Saved mode identifiers remain `deepFilterNet`, `rnnoise` and
`cadence`. Light / Medium / Strong retain their existing processing parameters;
attenuation limits are not part of the listening controls.

Volume Boost has Off / Low / Medium / High / Max choices, mapped to gains of
1 / 1.5 / 2 / 3 / 4. The level can be configured while playback is paused or the
filter is preparing. “Saved level” and the accompanying explanation distinguish
this preference from active boost. Gain still applies only to processed audio;
loading, failure and raw bypass do not boost the recording.

Fine-tune the voice opens Natural / Gentle Lift / Extra Lift, corresponding to
the existing `focus` / `lift` / `strong` presets. This control is offered with
Best Quality. The main page uses everyday status messages such as “Getting ready”
and “Enhancement paused”; the service retains distinct processing outcomes.

### Metrics

| Signal | Emitted when | Dimensions | Purpose |
| --- | --- | --- | --- |
| `AudioProcessing` OSLog | Processing status changes | Existing closed mode/outcome values | Explain preparation, active cleanup and failures |
| Processing/bypass diagnostics | Audio callbacks process or bypass a buffer | None; counters belong to each local tap | Confirm actual processing before reporting boost availability |

The interface consumes existing diagnostics. Integration tests assert status and
counter evidence; OSLog text is inspected manually rather than asserted in tests.

### Test coverage

| Case | Coverage | Type |
| --- | --- | --- |
| Saved mode keys and boost levels | `UserSettingsTests`, `DeepFilterNetTests` | Unit |
| Raw bypass and boost ceiling | `VolumeBoostTests` | Unit/native DSP |
| Active processing, parameter changes and unavailable boost | `AudioPlayerIntegrationTests` | AVPlayer integration |
| Player entry, off/on dependency and reopening | `AudioEnhancementPresentationTests.testPlayerCombinesNoiseReductionAndBoostWithoutStartingPlayback` | UI integration |
| Recommended/secondary modes, persistence and mini-player clearance | `AudioEnhancementPresentationTests.testSettingsOffersRecommendedAndSecondaryModesAndRemembersTheChoice` | UI integration |
| Large text, dark appearance and quiet-speech selection | `AudioEnhancementPresentationTests.testLargeTextDarkAppearanceKeepsControlsReachable` | UI integration |

All 61 unit/audio-integration tests passed across 66 runs in
`build/audio-enhancement-regression-tests.xcresult`. The three UI scenarios passed
on both iPhone 17 Pro and iPhone SE (3rd generation), iOS 26.5, in
`build/audio-enhancement-ui-verified.xcresult`. Screenshots are attached to that
result. The device Release build passed in
`build/audio-enhancement-release-final.xcresult`. The battery note describes relative processing cost; sustained phone
battery/thermal measurements remain device work.

The DeNoise rename and adjacent Transcript button passed all three UI scenarios on
both simulators in `build/denoise-player-controls.xcresult`. The follow-up Settings
scroll check asserts that the entire footer sits above the mini-player on both
screens: `build/denoise-settings-scroll.xcresult`.

The Gentle Lift default update passed the existing `UserSettingsTests` (unit) and
`AudioPlayerIntegrationTests` (AVPlayer integration): 24 tests / 29 runs in
`build/denoise-defaults-tests.xcresult`. These cover preference persistence, boost
defaults, live parameter changes and the local processing diagnostics above.

To run the UI checks, substitute an installed simulator ID:

```bash
xcodegen generate
xcodebuild -project OshoDiscourses.xcodeproj -scheme OshoDiscoursesUI \
  -destination 'platform=iOS Simulator,id=SIMULATOR_ID' \
  -parallel-testing-enabled NO \
  -only-testing:OshoDiscoursesUITests/AudioEnhancementPresentationTests test
```

## 2026-09-14: RNNoise repair and stream isolation

The current working tree contains unreleased DSP changes compared with baseline
`b627551` (2026-09-13). Local measurements are saved in
`build/noise-lab/evidence/report.json`, with validation scope in
`build/noise-lab/evidence/validation.json`. The offline harness is in
[`Tools/NoiseReductionLab`](../Tools/NoiseReductionLab/).

### Implementation

- **RNNoise had two integration defects.** It still received source-rate
  samples at 22.05 kHz despite the earlier documentation saying both models
  were resampled. Only DeepFilterNet used the resampler. The dry path also
  delayed one 480-sample hop, while the vendored model needs two hops, or
  960 samples at 48 kHz. `RNNoiseProcessor` uses `DenoiserStream` for conversion
  to the trained rate and back, with the dry/wet mix aligned at that rate.
- **The 16-tap resampler attenuated the upper speech band and rejected aliases
  poorly.** `PolyphaseResampler` uses a Kaiser-windowed filter with 128 taps per
  phase up and 280 down for 22.05 kHz / 48 kHz conversion. Its measured round
  trip preserves the 9.5 kHz passband; stopband results are below.
- **Model strength and Voice Focus are separate controls.** Settings and the
  player expose DeepFilterNet Light / Medium / Strong as 6 dB / 12 dB / no cap
  (100 dB in the bridge), independently of Focus / Lift / Strong post-processing.
  This snapshot used Medium and Focus as defaults, with noise reduction off.
  Strength, Voice Focus and boost changes retain the tap and neural streaming
  history instead of rebuilding or re-priming it.

`NoiseReductionProcessor` selects the current `NoiseReductionTapContext`. Each
tap generation owns a separate `NoiseReductionStream`, model state and outcome
counters, so an old tap cannot mutate the replacement's DSP or processing
evidence. Each new DeepFilterNet tap loads its own model asynchronously. A short
interval of original audio during loading is accepted. Output gain applies only
to successfully processed buffers; loading and model-failure bypasses retain
raw audio.

Source discontinuities request deferred resets off the render path to clear
pre-boundary history. The real AVPlayer test found seeks with no discontinuity
flag and no new prepare callback. `SourceAudioTimeline` also checks the source
asset time ranges, allowing rational timestamp rounding and resetting on gaps
or loss/recovery of valid timing. Both neural methods pass the simulator seek
test with an observed completed reset. The existing DeepFilterNet reset flush
of eight silent hops is preserved; it does not call the upstream reset that
accumulated latency.

Diagnostics are local: fixed outcome counters cover processed, disabled,
unprepared, invalid, model-bypassed and lock-contended buffers, plus source-read
failures and resets. OSLog records setup and status transitions off the render
path, with no per-callback logging or remote telemetry. The player distinguishes
model readiness from recent processed buffers belonging to the current tap.
Swift stream buffers are preallocated and callbacks use try-locks; the native
tract runtime still allocates during inference.

### Measured speech fidelity

The comparison uses RNNoise Medium (0.5 wet), DeepFilterNet Medium (12 dB) with
Focus, and Boost off (1x). Human male and female references come from the Open
Speech Repository at 8 kHz, resampled to 22.05 kHz. The report's Hindi reference
is synthetic macOS speech, not a human recording.

| RNNoise reference and metric | Baseline `b627551` | Working-tree snapshot |
| --- | ---: | ---: |
| Clean male, SI-SDR (dB) | 0.28 | 20.81 |
| Clean female, SI-SDR (dB) | 2.59 | 20.29 |
| Male with hiss at 10 dB global input SNR, SI-SDR (dB) | -0.17 | 14.11 |
| Clean male, STOI | 0.876 | 0.997 |

Scale-invariant signal-to-distortion ratio (SI-SDR) measures fidelity and is
sensitive to phase and EQ. Short-time objective intelligibility (STOI) is an
intelligibility proxy. The clean-speech results show less distortion, not 20 dB
of noise removal. The unprocessed hiss mixture itself scores 10.17 dB SI-SDR.

For Maha Geeta #5 at **40:15-40:45**, the same high- and low-energy source
windows give these output/input gains:

| Processor | High-energy gain, before / after | Low-energy gain, before / after |
| --- | ---: | ---: |
| RNNoise | -5.54 / -0.87 dB | -6.01 / -6.02 dB |
| DeepFilterNet + Focus | -3.73 / -3.62 dB | -25.05 / -25.22 dB |

These windows are speech/pause proxies selected from source energy, not clean
speech and isolated noise. They cannot establish clean-target SNR. DeepFilterNet's
steady-state suppression on the measured recordings is broadly similar before
and after. On the 32 kHz Bird excerpt, RNNoise reduces both window groups by
about 6 dB, mainly changing level. These results do not establish a universal
denoising improvement or a listening preference.

### Conversion, latency and cost

The resampler probe measures gain relative to the input tone:

| Probe | Baseline `b627551` | Kaiser filter |
| --- | ---: | ---: |
| 9.5 kHz round trip, 22.05 kHz / 48 kHz | -9.14 dB | approximately 0 dB |
| 11,025 Hz into 48 kHz to 22.05 kHz conversion | -7.49 dB | -91.85 dB |
| 12 kHz into 48 kHz to 22.05 kHz conversion | -12.72 dB | -110.76 dB |

The longer filter adds about 5.4 ms to the measured DeepFilterNet recording
delay. The reset probe measures **58.64 ms** at both zero and twelve resets.
The earlier **53 ms** result below belongs to the old resampler.

On the 130-second, 22.05 kHz stereo Maha Geeta excerpt, the macOS release build
measures real-time factors of **0.039 for RNNoise** and **0.071 for DeepFilterNet**.
DeepFilterNet's p99 processing time is **4.16 ms** for a 1,024-frame buffer
containing **46.44 ms** of audio. Model loading and file I/O are excluded.
These offline timings do not measure phone scheduling, battery or thermals.

### Validation and listening status

`validation.json` records passing macOS DSP/model checks and an Address
Sanitizer run for the captured snapshot. Unit coverage includes rate conversion,
ragged buffers, failure preservation and Voice Focus envelopes. Native-model
integration coverage includes RNNoise delay alignment, DeepFilterNet loading
races, constant reset latency and raw-audio boost bypass. The sanitizer run
covers Swift buffers; the prebuilt native libraries are not instrumented.
Two iOS service-wiring assertions are excluded from that harness and covered
by the app suite. The final iPhone 17 Pro / iOS 26.5 simulator run passed
**315 test functions / 351 parameterized runs**, with no failures or skips:
`build/tipjar-noise-final-tests.xcresult`. Release builds also passed for device
arm64 and the universal simulator. Real AVPlayer integration covers processing
22.05 kHz stereo audio, live settings, seeks, replacement taps and media-reset
recovery. Source-timeline unit tests cover unflagged gaps, invalid timing and
asset-time progression at different playback rates; these are not sustained
phone performance measurements.

Five recorded excerpts produced **50 before/after audition WAVs**, including raw,
RNNoise and DeepFilterNet variants at native and matched levels. Matching uses
RMS on the same high-energy source windows, with shared headroom within each
group. Export checks found zero clipped samples and a maximum estimated 4x
true peak of **-1.41 dBFS**; existing source clipping cannot be undone.
No listening was performed for this comparison. Blind preference, sustained
phone playback at 2x, and phone battery/thermal behavior remain unmeasured.

### Reproduction

Run from the repository root on an Apple Silicon Mac with the macOS 26.5
toolchain and Rust. The before/after matrix reuses the saved baseline executable
and the four trimmed source WAVs in `build/noise-lab/sources/`:
`maha-aircraft`, `maha-quiet`, `bird-opening` and `wisdom-hiss`. Their `.wav.json`
sidecars record the original files, cut offsets and durations.

```bash
python3 -m venv build/noise-lab/.venv
source build/noise-lab/.venv/bin/activate
python -m pip install -r Tools/NoiseReductionLab/requirements.txt
python Tools/NoiseReductionLab/build.py --name current
python Tools/NoiseReductionLab/experiments.py mixtures
python Tools/NoiseReductionLab/experiments.py render --name baseline
python Tools/NoiseReductionLab/experiments.py render --name current
python Tools/NoiseReductionLab/run-tests.py
python Tools/NoiseReductionLab/run-tests.py --sanitize address \
  --filter 'DenoiserStreamTests|NoiseReductionProcessorTests|PolyphaseResamplerTests'
python Tools/NoiseReductionLab/report.py --render
```

`build.py --name baseline --from-snapshot baseline` rebuilds the saved baseline
Swift sources; `source-info.json` records source/model/library fingerprints.
A fresh checkout needs those baseline artifacts and source cuts for this matrix.
`prepare.py --download` fetches Maha Geeta and Bird audio and generates alignment
probes, but does not create the four trimmed WAVs. `experiments.py mixtures`
fetches the human references and includes synthetic Hindi only when
`sources/hindi-reference.wav` is present. `resampler-probe.swift` measures filter
gain; `analyze.py` compares delay-aligned outputs. `report.py` merges existing
probe and validation JSON, so re-rendering alone does not refresh that validation
record.

## Historical source-rate diagnosis (corrected)

Measured on `OSHO-Maha_Geeta_05.mp3`: **22,050 Hz, 43 kbps**. The archive.org
mirror used in the comparison is byte-identical.

Both RNNoise and DeepFilterNet are 48 kHz models. Their original rate defects
were fixed at different times:

- DeepFilterNet was bypassed on this material before its resampling path was
  added, so noise reduction appeared to "do nothing".
- RNNoise continued to run at the source rate through `b627551`, mapping its
  learned bands onto the wrong frequencies. The earlier claim that
  `PolyphaseResampler` converted both neural paths was incorrect. The
  `RNNoiseProcessor` / `DenoiserStream` work above supplies that missing path.

## Historical aircraft-noise experiments

Band energy at 40:20 (aircraft overhead) versus clean speech at 10:00:

| Band | Plane | Speech |
|---|---|---|
| 150–300 Hz | 29.8% | 35.8% |
| 300–700 Hz | 59.1% | 51.0% |
| 1500–3000 Hz | 1.0% | 0.7% |
| above 3000 Hz | 0.4% | 0.3% |

The interference sits in the *same* band as the voice, and only ~0.5% of the
energy lives above 3 kHz. So:

- Subtractive EQ cannot separate them.
- A 3–8 kHz "presence" boost would amplify codec hiss, not consonants.
- A high-pass steep enough to remove rumble would take Osho's fundamentals too.

Two approaches were measured and **rejected**:

- **Downward compression** — collapsed contrast from +9.7 dB to +2.0 dB, because
  it lifts the pauses along with everything else.
- **DSP without the neural stage** — measured *worse than doing nothing*
  (-7.2 dB), so the model is doing the real work.

## Historical Voice Focus experiments

The measurements and listening reports in this section belong to the earlier
experiments, with the old resampler and the attenuation settings stated below.
The 2026-09-14 comparison has no listening results.

What does work is raising speech-to-pause contrast using DeepFilterNet's own
per-frame local SNR estimate: duck noise-dominated frames, optionally lift quiet
speech, and emphasise only the band this material actually uses.

| Preset | Ducks | Lifts quiet speech | Character |
|---|---|---|---|
| Focus | -14 dB floor, 220 ms hold, 400 ms close | no | most transparent |
| Lift | -14 dB floor, 220 ms hold, 400 ms close | up to +9 dB | soft passages stay forward |
| Strong | -22 dB floor, 150 ms hold, 240 ms close | up to +9 dB | clearest, most processed |

### Model latency matters

Measured with a tone burst through the bridge: DeepFilterNet's **output lags its
input by 3 frames**, while the **local SNR it returns leads the corresponding
output audio by 2 frames**. Gating the same call's samples therefore ducks 20 ms
early — clipping speech tails and releasing before the pause ends.
`VoiceFocusChain` delays the SNR by 2 frames to correct this, which both
preserves speech better and ducks pauses more completely:

| | speech gain | pause gain | speech-to-pause |
|---|---|---|---|
| original | — | — | +23.1 dB |
| offline prototype (misaligned) | -3.4 dB | -14.1 dB | +33.9 dB |
| earlier aligned implementation (Focus) | -2.7 dB | -20.9 dB | **+41.2 dB** |

### The gate must be slow to close, not fast

The first version muted the ends of Osho's sentences. Diagnosed from the sample
at 41:37 of Maha Geeta #5, where a sentence tail decays like this:

| time | level | flatness | DFN local SNR |
|---|---|---|---|
| 41:37.20 | -16.8 dB | 0.03 | +16.5 (clear speech) |
| 41:37.35 | -23.5 dB | 0.45 | +6.0 |
| 41:37.45 | -28.0 dB | 0.53 | -13.0 (reads as noise) |

His final words fall 11 dB in level and the model's SNR collapses by ~30 dB, so
a plain SNR gate classifies them as noise. The original envelope made this
fatal: it closed with a **10 ms** time constant, so the gate shut directly on
the last words of every sentence.

A speech gate needs the opposite shape — fast to open, then **hold**, then slow
to close:

- open 8 ms (never clip a syllable onset)
- hold 220 ms after clear speech (150 ms on Strong)
- close 400 ms (240 ms on Strong)

Measured on 41:30-41:50 after the fix:

| preset | mid-speech | sentence tail | tail − mid | long pause |
|---|---|---|---|---|
| Focus | -3.3 dB | -2.6 dB | +0.7 dB | -26.4 dB |
| Lift | -1.2 dB | -2.2 dB | -1.0 dB | -22.9 dB |
| Strong | -1.2 dB | -2.2 dB | -1.0 dB | -25.4 dB |

`gateDoesNotSwallowTheEndsOfSentences` locks this in: it synthesises a decaying
tail with falling SNR and fails if the tail is attenuated more than 6 dB below
mid-speech, or if long pauses stop ducking.

### Levelling must track speech, not individual frames

The lift originally aimed *each frame* at a fixed target level, so the quieter
the frame the harder it boosted — which amplified quiet noise between clauses
more than the voice (pauses came out +7.9 dB against speech's +3.7 dB). It now
tracks a running estimate of Osho's speech level, updated only on speech frames,
and applies one steady boost. Covered by
`liftTracksSpeechLevelRatherThanEachFrame`.

### Emphasis placement is measured, not assumed

Band energy ratios (speech ÷ plane) on the aircraft passage:

| band | speech | plane | ratio |
|---|---|---|---|
| below 150 Hz | 10.8% | 0.4% | 27x |
| 150–300 Hz | 35.8% | 29.8% | 1.20 |
| 300–700 Hz | 51.0% | 59.1% | 0.86 |
| 700–1500 Hz | 1.3% | 9.3% | **0.14** |

The first attempt high-passed at 110 Hz and put a +4 dB bell at 900 Hz — cutting
the *most* speech-favoured band and boosting the *most* plane-dominated one. It
now high-passes at 90 Hz and places a +3.5 dB bell at 1.6 kHz, which is sparse
in both and therefore lifts consonants without dragging up a large noise mass.
This reduced noise in short gaps from +3.2 dB to +2.2 dB.

### Known limitations

- Audience laughter is largely suppressed: the model classifies it as noise, and
  the gate ducks it. The hold recovers the first ~200 ms only.
- Short gaps between clauses are ~2 dB brighter than the source, because the
  emphasis is static. It does not pump.
- Lift and Strong measure close together on this material; Focus is the clearly
  distinct option (no levelling, deepest ducking).

### Earlier listening feedback

Reported after listening to all three presets on Maha Geeta #5 around 41:37.
Sentence endings and overall clarity were confirmed fixed.

**1. Chirping — resolved. It was clipping, and the bug was real in playback too.**

Two hypotheses were measured and both were wrong. Recorded because each was
plausible and someone will otherwise re-run them.

*Wrong hypothesis one: imaging or aliasing in `PolyphaseResampler`.*

- DeepFilterNet's 48 kHz output holds energy above 11,025 Hz at **-143 dB**
  relative to total. The input was upsampled from a band-limited 22.05 kHz
  source, and the model's gains are multiplicative, so it never creates content
  up there. The downsampler has nothing to fold down.
- Rendering 40:00-42:00 with the downsampler at 16 taps against 256 taps changes
  the 2-10 kHz band by 0.2 dB and leaves the frame-to-frame burble index
  identical (2.45 vs 2.45).

*Wrong hypothesis two: the model's musical noise, exposed.* The measurement below
is real and worth keeping as characterisation, it just is not what was being
reported. Over 1.5-8 kHz on speech frames the model pushes the **masking noise
bed down 10.4 dB while the residual blobs only fall 2.1 dB**, so blobs stand
8.3 dB further out than in the source. The blob *count* barely moves (182/s
source against 196/s enhanced) — what changes is that the noise which used to
mask them is gone. Spectrograms show the smooth noise wash replaced by sparse
speckle, and a 1.3 s pause driven nearly black. Attenuation limit controls it:

| strength | noise removed | blob exposure |
| --- | --- | --- |
| Strong (100 dB, no limit) | -11.1 dB | 9.9 dB |
| Medium (12 dB, the default) | -6.5 dB | 5.8 dB |
| Light (6 dB) | -3.9 dB | 3.8 dB |

On a blind listen of that ladder, none of the three was reported as chirping.
That is what ruled this out as the cause.

*The actual cause: the audition WAV files were clipping.*

| clip set | peak | clipped samples |
| --- | --- | --- |
| `AB_*`, the Python prototypes that were approved | -0.92 dBFS | 0 |
| `SWIFT_focus/lift/strong` | 0.00 dBFS | 1,559-1,730 (0.18-0.20%) |
| `at-41-37/4137_*` | 0.00 dBFS | 478-1,404 (0.11-0.32%) |

Clipped speech peaks crackle, which is what "chirping" described. It was absent
from the zero-clipped prototypes, and absent again once renders were written with
shared headroom. `4137_lift` and `4137_strong` clipped 2.4x more than
`4137_focus` — those are the two presets carrying the +9 dB lift, which is the
tell.

**And the same defect was real in live playback, not just in the renders.** With
no normalisation the chain handed back, on 40:00-42:00:

| strength | preset | peak out | samples over full scale |
| --- | --- | --- | --- |
| Medium | focus | +3.34 dBFS | 7,977 |
| Medium | lift | +10.06 dBFS | 11,487 |
| Medium | strong | +10.06 dBFS | 11,333 |

Two structural causes, since this archive is already mastered into full scale
(Maha Geeta #5 peaks at 0 dBFS):

1. The emphasis bell added a flat +3.5 dB. It is now normalised so its peak
   response is unity — the same tilt, achieved by cutting elsewhere.
2. The lift aims at **-20 dBFS RMS**, but speech carries ~18 dB of crest factor,
   so a frame at -20 dBFS RMS is already peaking near -2 dBFS and 9 dB of lift
   put it past full scale. The lift is now capped by what the frame's own peak
   can take, and clamped at unity so it stays an upward-only control.

A safety limiter backs both up, with instantaneous attack by construction (the
gain applied to a sample never exceeds `ceiling / |sample|`, so no look-ahead
delay is needed) and a 120 ms release. Its ceiling is -1 dBFS rather than 0
because the downsampler that follows reconstructs intersample peaks slightly
above the samples it is handed — measured output lands at -0.94 dBFS.

Fixing the causes rather than leaning on the limiter mattered: with the limiter
alone it engaged on **44% of samples**, which is a compressor, not a safety net.
After both fixes it engages on 0.005% (Focus) to 0.04% (Lift/Strong).

On the measured Maha Geeta #5 passage, output RMS is ~3.8 dB below the source,
part noise removal and part emphasis normalisation. This is not a catalog-wide
loudness result; limited boost can recover some perceived level by spending
speech crest factor, not by creating peak headroom.

**The earlier listening tests were run at full attenuation.** That is the
Strong setting, not the `medium` default, so those clips used more suppression
than a default install. Any future preset comparison must state its attenuation
limit or it is not reproducible.

Medium was chosen on that listen: Light still left audible noise. Medium is
already the default, so no strength default changed. DeepFilterNet is now the
mode selected when a listener opts into noise reduction.

Any future audition file must be written with shared headroom and checked for
clipped samples before anyone is asked to judge it. That mistake cost two wrong
diagnoses.

**2. Breathing sounds are obtrusive.**

Probably a different cause, and partly a side effect of the tail fix:

- The 220 ms hold keeps the gate fully open through a breath taken right after
  speech, while ducking the noise around it, so the breath now stands out.
- The 1.6 kHz emphasis tilt sits in the breath and fricative band. It no longer
  adds absolute level, but it still raises that band relative to the rest.
- DeepFilterNet partially suppresses then releases breath, which modulates it.

Worth trying in order: trim the emphasis gain, then consider treating
low-harmonicity frames inside the hold window differently from voiced ones.
Note the emphasis bell also sits inside the chirp band, and measurably makes
exposure worse (7.9 dB model-only against 8.3 dB with Focus applied), so it is
implicated in both issues.

### Historical 16-tap resampler measurements

The old filter was not the cause of that chirping, but it had weak rejection.
Transition width was `5.5 * inputRate / tapsPerPhase`: at 16 taps
that was ~7.6 kHz upsampling and ~16.5 kHz downsampling. The historical
tone-probe readings were:

| tone (48 kHz in) | folds to | 16 taps | 256 taps |
| --- | --- | --- | --- |
| 12 kHz | 10,050 Hz | **-18.8 dB** | -104.1 dB |
| 14 kHz | 8,050 Hz | -29.8 dB | -125.3 dB |
| 15 kHz | 7,050 Hz | -36.7 dB | -127.1 dB |

-18.8 dB was only 13 dB below the tone itself. The sampled 22.05 kHz pipeline
had little energy above its Nyquist limit, but 44.1 kHz input or generated
high-frequency content could expose the defect.
`suppressesContentAboveTheOutputNyquist` required only about 17 dB then.

The proposed follow-up was about 128 taps up / 256 down, a Kaiser window with
a specified stopband, and a stronger rejection test. The Kaiser implementation
and measurements at the top of this document complete that follow-up.

### Historical measured cost

Full chain (resample → model → focus → resample) at 22,050 Hz: **real-time
factor 0.123**, about 8x faster than playback, with zero bypassed blocks and
**53 ms** of constant latency. Model load is ~230 ms, which is why it happens off
the audio thread.

**One model instance, not one per channel.** The downloads are not mono:
oshoworld ships 22,050 Hz joint-stereo MP3s. Running DeepFilterNet per channel
meant two model instances and twice the inference — about 0.246 of real time — to
reproduce nearly the same signal twice, because measured on Maha Geeta #5 the two
channels differ by only **-18.4 dB**. It is a near-dual-mono source in a stereo
container.

The channels were mixed to mono, denoised once, and the result written back to
both. That halved model instances and roughly halved measured inference cost;
phone battery savings were not measured. It also removed an artifact the
per-channel version could produce: two independent gates ducking at
slightly different moments make the stereo image wander, which is worse on a voice
recording than having no width at all. The cost is that genuine stereo content in
the source is collapsed, which is an accepted trade for spoken word.

That latency was 103 ms and grew by 50 ms on every reset until the reset path was
fixed — see below.

### The reset path used to leak latency

The old reset path ran on track changes, seeks and settings toggles. It forwarded
to `dfb_reset`, which forwards to upstream's `DfTract::init()`, and that method is
not idempotent: it clears `rolling_spec_buf_y` before re-priming it but never
clears `rolling_spec_buf_x`, so each call appends another `df_order` (5) frames
to the noisy-spectrum buffer.

Measured on a 22.05 kHz source, delay through the chain over successive resets:

| resets | delay |
| --- | --- |
| 0 | 103 ms |
| 1 | 153 ms |
| 2 | 203 ms |
| 3 | 253 ms |
| 4 | 303 ms |

Unbounded, and not merely cosmetic: the output FIFO is sized
`primeCount + 2 * maxFrames + downCapacity + 64`, so after roughly eight resets
it overflowed, `push` began returning false, and DeepFilterNet fell back to
passthrough for the rest of the session. Anyone who seeked a few times silently
lost noise reduction.

`resetStreamState` displaced stale spectra with 8 hops of silence instead of
calling `dfb_reset`. With the earlier resampler, the measured delay stayed at
1,174 frames, about 53 ms, across repeated resets. The startup path had been
paying one spurious `init()` too. The flush is preserved in the current code;
the Kaiser-filter reset probe above measures about 58.6 ms.

`rolling_spec_buf_x` is private, so it cannot be cleared from the bridge. The
alternative fix — destroying and recreating the native handle — is also correct
but re-parses the ONNX model on every seek, about 230 ms of unprocessed audio
each time. The running normalisation states are deliberately left alone: they are
not part of the latency, they re-adapt within a few frames, and keeping them
means a seek does not start from a cold estimate.

This was found while building offline rendering, because a render has to know the
chain's delay to trim it, and the measured delay kept disagreeing with itself.

Device app bundle grows from roughly 4 MB to 32 MB (static tract code plus the
7.6 MB model).

### What to watch for on device

- Pumping or breathing on Strong, especially in long pauses.
- Underruns at 1.75x–2x playback (headroom says no, but confirm).
- Battery and thermals over a full discourse.
- `Enhancement is on` must be backed by recent processed buffers from the current tap.

The service distinguishes loading, model-ready, processing, bypass and error
states. The interface groups preparation states under “Getting ready”. A loaded
model alone does not activate boost. Gain is gated again per processed buffer,
and a DeepFilterNet failure does not substitute RNNoise.

## Listening Set

Build a fixed set of 30 to 50 excerpts, each 15 to 30 seconds. Include English
and Hindi speech, silence and long pauses, low and high hum, hiss, horns or
trains, birds, music, and relatively clean recordings. Keep excerpts grouped by
discourse when splitting training and evaluation data so the same recording
noise does not leak into both sets.

For every processor and strength, record:

- Voice clarity: 1 to 5
- Noise reduction: 1 to 5
- Overall preference: 1 to 5
- Problems heard: muffled voice, pumping, metallic sound, lost consonants, or other
- Noise present: 50/60 Hz hum, hiss, transient traffic, birds, crowd, or unknown

Listen blind when possible and keep the unprocessed excerpt as a reference.

## Experiments

1. Compare Off, RNNoise, Cadence, and DeepFilterNet in the app on the fixed listening set.
2. Confirm DeepFilterNet's real-time factor, battery, and thermal behaviour on the phone across a full discourse.
3. If DeepFilterNet still costs too much battery, consider a Core ML port (stateful recurrent graph, STFT/ISTFT and ERB in Accelerate). The cheap win — collapsing the near-dual-mono stereo to one channel — is already taken.

### Pre-rendering after download was built and removed

Worth recording so it is not re-litigated from scratch. A full offline renderer
existed briefly: it drove the same `NoiseReductionProcessor` the tap drives, wrote
48 kbps AAC beside the download, and playback preferred the rendered copy and
skipped the tap. It worked, with tests.

It was removed because the costs outweighed a live chain that had become good
enough:

- **Settings bake in.** Changing strength or preset means re-rendering, so the
  instant A/B that all of this tuning depended on is gone.
- **Time.** The sources are joint-stereo, so a render ran at about 0.246 real
  time — roughly 20 minutes for an 85-minute discourse.
- **Storage.** Each rendered copy roughly doubles that discourse's footprint.
- **A second path through the DSP** to keep in sync forever.

Two things it left behind, both kept: the output-ceiling fix, and the reset
latency leak below. The second was only found because a renderer has to know the
chain's delay in order to trim it, and the measurement kept disagreeing with
itself.

If it is ever revisited, the argument for it is not CPU — it is that offline work
can be non-causal, which allows a true look-ahead limiter, exact SNR alignment
instead of a fixed delay, and two-pass loudness normalisation.
4. Fine-tune only after the baseline comparison. Use clean speech plus synthetic hum, hiss, traffic, and recording artifacts; use noise-only Osho pauses as noise material, not as clean targets.
5. Gate turning noise reduction **on** by default on blind preference, preserved Hindi and English consonants, zero playback underruns, sustained thermal performance, and verified model/data licenses. None of the device-side items have been measured yet, so noise reduction still ships off.

### Next measured micro-experiments

Do not ship DeepFilterNet twice or chained with RNNoise without evidence. Both
neural processors make independent speech/noise decisions, so a cascade adds
latency and overlapping suppression; this repository has not measured a
complementary benefit.

Test these one variable at a time on the fixed listening set:

1. Compare the static 1.6 kHz emphasis at 3.5, 2 and 0 dB. Measure breath-to-
   adjacent-speech level, 1.5-8 kHz residual-blob exposure, sentence-tail gain
   and blind clarity preference. This is the most direct test for the reported
   prominent breaths.
2. Compare DeepFilterNet's native post-filter at beta 0, 0.01, 0.02 and 0.05,
   holding the attenuation limit at 12 dB. Upstream's command-line tool uses
   0.02 when the optional filter is enabled and describes it as slightly over-
   attenuating very noisy sections. Compare both native-level and loudness-
   matched output; measure hiss reduction, consonant loss and residual-blob
   exposure before adopting it.
3. Detect stable 50/60 Hz hum and its harmonics from long pauses, then apply only
   the detected narrow notches. Start after DeepFilterNet so the detector cannot
   perturb model input, then compare before-model placement. Do not always notch
   50, 60, 100 and 120 Hz: Osho's fundamental occupies the same lower band. Test
   hum attenuation and 80-250 Hz speech loss on both synthetic mixtures and real
   excerpts.
4. If breath handling still needs work, do not classify it from harmonicity alone.
   Measure pitch confidence and spectral/temporal context alongside the model's
   aligned local SNR, and alter only the optional emphasis tilt. Never close the
   gate faster: breaths and unvoiced consonants can look alike, and the earlier
   fast gate swallowed words.

The current chain is archive-tuned, not Osho-selective. A custom model would need
representative, rights-cleared targets and mixtures; pretrained target-speaker
extraction could instead use enrollment audio, but adds model, licensing,
identity-preservation and runtime risk. EQ alone cannot identify a person, and
the available measurements show that aircraft noise overlaps the same 150-700 Hz
band as his voice. Establish that competing speech is a material failure mode and
exhaust the low-risk tests above before taking on a new model.

DeepFilterNet **is** now the mode you get when you switch noise reduction on: it
was reached only by changing a setting most listeners never open, which meant the
work above reached almost nobody. That is a smaller step than default-on — nobody
spends battery without asking for it — so it is not held behind the gate above.

Volume boost is intentionally available only while noise reduction is actually
producing output. The unfiltered archive already peaks at full scale, so making it
louder requires a limiter to spend speech crest factor; listening showed that
this damaged the raw recordings more than it helped. On one Maha Geeta #5 render,
Medium/Focus measured about 3.8 dB lower in full-segment RMS, including removed
noise and the normalised emphasis tilt. That is not catalog-wide loudness or
guaranteed peak headroom; restricting boost remains a listening-policy choice
pending representative LUFS, true-peak, limiter-reduction and blind-preference
measurements. Turning noise reduction off removes the processing tap entirely;
DeepFilterNet loading/failure bypasses boost; the chosen level is remembered for
the next active filtered session.

Cadence is intentionally conservative. It rejects narrow 50/60 Hz hum and its
first harmonics, rolls off only the highest hiss band, and lowers noise after a
long quiet interval. It is not expected to remove horns, trains, or other sounds
that overlap speech; DeepFilterNet is the option to reach for there, since its
complex multi-frame deep filtering can attenuate noise that overlaps the voice.

## Rebuilding the native bridge

Only needed when changing the Rust bridge or bumping the pinned upstream commit.
Normal app builds just link the committed XCFramework and need no Rust toolchain.

```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
./native/deepfilter-bridge/build-xcframework.sh
xcodegen generate
```

The simulator slice must stay universal (arm64 + x86_64): Release builds do not
restrict themselves to the active architecture, so an arm64-only simulator slice
breaks `xcodebuild -configuration Release` for the simulator.
