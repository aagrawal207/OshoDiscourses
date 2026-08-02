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
Sentence endings and overall clarity were confirmed fixed; these remain.

**1. Chirping while Osho speaks. It is the model's musical noise, exposed.**

The first hypothesis — imaging or aliasing in `PolyphaseResampler` — was measured
and is **wrong**. Recording it because the reasoning was plausible and someone
will otherwise re-run it:

- DeepFilterNet's 48 kHz output holds energy above 11,025 Hz at **-143 dB**
  relative to total. The input was upsampled from a band-limited 22.05 kHz
  source, and the model's gains are multiplicative, so it never creates content
  up there. The downsampler has nothing to fold down.
- Rendering 40:00-42:00 with the downsampler at 16 taps against 256 taps changes
  the 2-10 kHz band by 0.2 dB and leaves the frame-to-frame burble index
  identical (2.45 vs 2.45).

What it actually is, measured over 1.5-8 kHz on speech frames at 40:00-42:00:
the model pushes the **masking noise bed down 10.4 dB while the residual blobs
only fall 2.1 dB**, so the blobs end up standing 8.3 dB further out of the bed
than they did in the source. Spectrograms show it plainly: the source's smooth
noise wash is replaced by sparse speckle, and a 1.3 s pause is driven to nearly
black.

So the blob *count* is not the problem — it barely moves (182/s in the source
against 196/s enhanced). The problem is that the noise which used to **mask**
them has been removed. This is ordinary musical noise, and it only became
audible once the tail-muting fix stopped hiding it.

The knob is DeepFilterNet's attenuation limit, which caps how far any band may
be pushed down and therefore leaves a masking bed in place. It already exists
and is already wired to Settings > Noise reduction as Light/Medium/Strong
(`AudioPlayerService.DenoiseStrength`: 6 / 12 / 100 dB). Measured with preset
Focus:

| strength | noise removed | chirp exposure |
| --- | --- | --- |
| Strong (100 dB, no limit) | -11.1 dB | 9.9 dB |
| Medium (12 dB, the default) | -6.5 dB | 5.8 dB |
| Light (6 dB) | -3.9 dB | 3.8 dB |

Exposure falls monotonically with the limit, and so does the noise reduction —
it is a direct trade, not a free fix.

**Note the earlier listening tests were run at full attenuation**, as
`VoiceFocusPreset`'s doc comment says. That is the Strong setting, not the
`medium` default the app actually ships, so those clips were harsher than what a
default install produces. Any future preset comparison must state its
attenuation limit or it is not reproducible.

Awaiting a listening verdict on which strength is acceptable before changing any
default.

**2. Breathing sounds are obtrusive.**

Probably a different cause, and partly a side effect of the tail fix:

- The 220 ms hold keeps the gate fully open through a breath taken right after
  speech, while ducking the noise around it, so the breath now stands out.
- The +3.5 dB bell at 1.6 kHz sits in the breath and fricative band.
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
factor 0.123**, about 8x faster than playback, with zero bypassed blocks and
~103 ms of constant latency. Model load is ~230 ms, which is why it happens off
the audio thread.

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
3. If DeepFilterNet wins consistently but costs too much battery, consider a Core ML port (stateful recurrent graph, STFT/ISTFT and ERB in Accelerate) or pre-processing into a post-download cached file.
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
