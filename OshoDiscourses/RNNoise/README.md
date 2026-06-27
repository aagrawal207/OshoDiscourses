# RNNoise (vendored)

Speech denoiser used by `NoiseReductionProcessor`. RNNoise is a recurrent
neural network trained on speech + noise that predicts a per-band gain mask
every 10ms frame — far smoother than spectral subtraction, with no musical
noise.

## Provenance

- Source: https://github.com/xiph/rnnoise (BSD licensed — see `COPYING`)
- Model: the **little** variant (`rnnoise_data_little.c`), ~5.7MB compiled.
  Generated from the upstream `download_model.sh` weights tarball
  (model_version `0a8755f8e2d834eff6a54714ecc7d75f9932e845df35f8b59bc52a7cfe6e8b37`).

## What was vendored

- `src/*.c` — the 10 core sources needed for inference (denoise, kiss_fft,
  pitch, celt_lpc, rnn, nnet, nnet_default, rnnoise_tables,
  parse_lpcnet_weights, rnnoise_data_little). Training/dump tools and the
  large model variant are intentionally excluded.
- `src/*.h` and `src/x86/*.h` — headers. The `x86/` directory keeps only the
  headers that `vec.h`/`nnet.h` include unconditionally; the x86 `.c` SIMD
  sources are removed (NEON path is used on arm64).
- `include/rnnoise.h` — public API.
- `include/RNNoiseBridge.h` — Swift bridging header.

## Integration notes

- RNNoise processes fixed 480-sample frames and expects samples in int16 range
  (±32768). The Swift wrapper scales ±1.0 ↔ ±32768 and uses a per-channel FIFO
  delay line (primed with one block) so the audio tap gets exactly N samples
  out for N in, at a constant ~10ms latency.
- Built with `GCC_FAST_MATH: NO` — RNNoise's `arch.h` rejects `-ffast-math`
  without `FLOAT_APPROX`.
- `GCC_WARN_INHIBIT_ALL_WARNINGS: YES` for this target keeps the vendored C
  quiet; our own Swift still warns normally.

To update the model or sources, re-run upstream `download_model.sh` and re-copy.
