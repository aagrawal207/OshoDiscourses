# Noise Reduction Lab

Noise Reduction remains a beta with three processors: RNNoise (baseline),
Cadence (the first Osho-specific experiment), and DeepFilterNet 3 with Voice
Focus (the strongest option, now running natively on device).

## The source audio is not 48 kHz — and that was the real bug

Measured on `OSHO-Maha_Geeta_05.mp3`: **22,050 Hz, 43 kbps**. The archive.org
mirror is byte-identical, so no better master is available.

Both RNNoise and DeepFilterNet are 48 kHz models. Before resampling existed:

- DeepFilterNet **never ran at all** on this material — it was bypassed outright,
  so noise reduction appeared to "do nothing".
- RNNoise ran at the wrong rate, mapping its learned bands onto the wrong
  frequencies.

`PolyphaseResampler` now converts source rate → 48 kHz → back, which is what
makes any neural filtering possible on the catalog.

## Why aircraft noise cannot simply be removed

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

## Voice Focus

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
| shipping, aligned (Focus) | -2.7 dB | -20.9 dB | **+41.2 dB** |

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

### Open issues — next session starts here

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

Cost: output RMS is ~3.8 dB below the source, part noise removal and part the
emphasis normalisation. Level cannot be given back — the source has no headroom.

**Note the earlier listening tests were run at full attenuation**, as
`VoiceFocusPreset`'s doc comment says. That is the Strong setting, not the
`medium` default the app actually ships, so those clips were harsher than what a
default install produces. Any future preset comparison must state its
attenuation limit or it is not reproducible.

Medium was chosen on that listen: Light still left audible noise. Medium is
already the default, so no default changed. Note that the default *mode* is
still `rnnoise`, so DeepFilterNet remains opt-in.

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

### The resampler is still a weak filter, on its own merits

Not the cause of the chirping, but the measurements stand and are worth fixing
separately. Transition width is `5.5 * inputRate / tapsPerPhase`: at 16 taps
that is ~7.6 kHz upsampling and ~16.5 kHz downsampling. Measured rejection of a
tone that should vanish entirely:

| tone (48 kHz in) | folds to | 16 taps | 256 taps |
| --- | --- | --- | --- |
| 12 kHz | 10,050 Hz | **-18.8 dB** | -104.1 dB |
| 14 kHz | 8,050 Hz | -29.8 dB | -125.3 dB |
| 15 kHz | 7,050 Hz | -36.7 dB | -127.1 dB |

-18.8 dB is only 13 dB below the tone itself. This is inert in the current
pipeline solely because the 22.05 kHz source has nothing up there — it would
bite immediately on 44.1 kHz input, or if anything in the chain ever generated
high-frequency content. `suppressesContentAboveTheOutputNyquist` asserts only
~17 dB, which is why it passed.

Fix when convenient: ~128 taps up / ~256 down for roughly a 1 kHz transition,
Kaiser window with a specified stopband, then tighten that test to demand real
rejection. Cost is a few million multiply-adds per second against a 0.123
real-time factor.

### Measured cost

Full chain (resample → model → focus → resample) at 22,050 Hz: **real-time
factor 0.123 per channel**, about 8x faster than playback, with zero bypassed
blocks and **53 ms** of constant latency. Model load is ~230 ms, which is why it
happens off the audio thread.

**Per channel matters here.** The downloads are not mono: oshoworld ships
22,050 Hz joint-stereo MP3s, so DeepFilterNet runs one model instance and one
resampler pair per channel and the real cost during playback is about **0.246**,
roughly a quarter of a core held for the length of a discourse. Measured on Maha
Geeta #5 the two channels differ by only **-18.4 dB**, so this is a near-dual-mono
source in a stereo container and half that work is close to redundant. Collapsing
to mono would halve the CPU, the battery and the model memory; it has not been
done because it changes what the listener hears from what the source contains, and
that is a product decision rather than a measurement.

A test pins the two channels to the same latency. Two independent model instances
and two independent resampler pairs that drifted apart would smear the stereo
image rather than clean it up, and it would be easy to miss by ear on
near-dual-mono material.

That latency was 103 ms and grew by 50 ms on every reset until the reset path was
fixed — see below.

### The reset path used to leak latency

`reset()` runs on every track change, seek and settings toggle. It forwarded to
`dfb_reset`, which forwards to upstream's `DfTract::init()`, and that method is
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

`resetStreamState` now displaces the stale spectra by pushing 8 hops of silence
through the model instead of calling `dfb_reset`. Latency is constant at 1,174
frames across any number of resets, and the baseline dropped to 53 ms because the
startup path had been paying one spurious `init()` too.

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
- Status must never read `Active` while audio is audibly unprocessed.

Settings and the player both show the runtime's real state (`Loading…`,
`Active`, `Model missing`, `Failed to load`, `Unsupported rate`,
`Stopped on error`). Anything other than `Active` means audio is passing through
untouched, and no failure ever silently substitutes RNNoise.

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
3. If DeepFilterNet wins consistently but costs too much battery, the cheapest win is collapsing the near-dual-mono stereo to a single channel, which halves everything. After that, consider a Core ML port (stateful recurrent graph, STFT/ISTFT and ERB in Accelerate).

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
instead of a fixed delay, and two-pass loudness normalisation to recover the
3.8 dB the ceiling fix costs.
4. Fine-tune only after the baseline comparison. Use clean speech plus synthetic hum, hiss, traffic, and recording artifacts; use noise-only Osho pauses as noise material, not as clean targets.
5. Gate any default-on change to DeepFilterNet on blind preference, preserved Hindi and English consonants, zero playback underruns, sustained thermal performance, and verified model/data licenses.

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
