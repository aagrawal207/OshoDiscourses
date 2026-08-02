/// Panic-safe C interface to DeepFilterNet 3 (48 kHz full-band speech denoiser).
///
/// Implemented in Rust over upstream's `tract` inference runtime; see
/// `native/deepfilter-bridge`. Every function is safe to call with a NULL
/// handle and never unwinds into the caller — failures come back as negative
/// status codes so the audio path can fall back to passthrough instead of
/// crashing mid-playback.

#ifndef DEEPFILTER_BRIDGE_H
#define DEEPFILTER_BRIDGE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DFB_OK 0
#define DFB_ERR_NULL (-1)
#define DFB_ERR_ARG (-2)
#define DFB_ERR_PANIC (-3)
#define DFB_ERR_RUNTIME (-4)

typedef struct DfbHandle DfbHandle;

/// Load a DeepFilterNet `.tar.gz` model export. `atten_lim_db` caps noise
/// attenuation in dB (>= 100 means unlimited). Returns NULL on failure.
DfbHandle *dfb_create(const char *model_path, float atten_lim_db);

/// Samples consumed and produced per `dfb_process_frame` call (480 for DFN3).
/// Returns 0 for a NULL handle.
size_t dfb_hop_size(const DfbHandle *handle);

/// Sample rate the model expects (48000 for DFN3). Returns 0 for NULL.
size_t dfb_sample_rate(const DfbHandle *handle);

/// Change the attenuation limit without reloading the model.
int dfb_set_atten_lim(DfbHandle *handle, float atten_lim_db);

/// Post-filter strength; 0 disables it. Useful range up to about 0.05.
int dfb_set_post_filter_beta(DfbHandle *handle, float beta);

/// Denoise exactly one frame of +/-1.0 float PCM. `frame_len` must equal
/// `dfb_hop_size`. `out_snr` may be NULL. `input` and `output` must not alias.
///
/// The model is causal but not zero-latency: output lags input by its internal
/// lookahead, so delay the dry signal to match before blending.
int dfb_process_frame(DfbHandle *handle,
                      const float *input,
                      float *output,
                      size_t frame_len,
                      float *out_snr);

/// Clear streaming analysis state after a seek or track change.
int dfb_reset(DfbHandle *handle);

/// Free a handle. Safe to call with NULL.
void dfb_destroy(DfbHandle *handle);

#ifdef __cplusplus
}
#endif

#endif /* DEEPFILTER_BRIDGE_H */
