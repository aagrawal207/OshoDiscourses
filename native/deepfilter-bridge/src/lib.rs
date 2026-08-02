//! Panic-safe C bridge over DeepFilterNet 3's `tract` inference runtime.
//!
//! Why this crate exists instead of using upstream's own `capi` feature:
//! upstream's C API calls `.expect(...)` on model loading and on every
//! processed frame. A Rust panic that unwinds across an FFI boundary is
//! undefined behaviour and in practice aborts the host process — so a corrupt
//! bundled model or one bad frame would crash the app mid-playback rather than
//! degrade. Every entry point here wraps the call in `catch_unwind` and reports
//! failure as a negative status code, letting Swift fall back to passthrough.
//!
//! Threading: all state lives behind the opaque handle and nothing is shared,
//! so the caller may use one handle per audio channel from its own thread. No
//! entry point is safe to call concurrently on the *same* handle.

use std::ffi::{c_char, CStr};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;

// The `deep_filter` package declares `[lib] name = "df"`, so that is the name
// the crate is linked and imported under.
use df::tract::{DfParams, DfTract, ReduceMask, RuntimeParams};
use ndarray::{ArrayView2, ArrayViewMut2};

pub const DFB_OK: i32 = 0;
pub const DFB_ERR_NULL: i32 = -1;
pub const DFB_ERR_ARG: i32 = -2;
pub const DFB_ERR_PANIC: i32 = -3;
pub const DFB_ERR_RUNTIME: i32 = -4;

/// Opaque handle. Single channel: DeepFilterNet is a mono speech model, and the
/// caller runs one handle per channel.
pub struct DfbHandle {
    model: DfTract,
}

/// Load a DeepFilterNet model from a `.tar.gz` export (enc/erb_dec/df_dec ONNX
/// plus `config.ini`).
///
/// `atten_lim_db` caps how far the model may attenuate noise; upstream treats
/// >= 100 dB as "no limit". Returns null on any failure — bad path, unreadable
/// or corrupt archive, or a panic inside the runtime.
#[no_mangle]
pub unsafe extern "C" fn dfb_create(model_path: *const c_char, atten_lim_db: f32) -> *mut DfbHandle {
    if model_path.is_null() {
        return std::ptr::null_mut();
    }
    // Copy the path out before entering catch_unwind so the closure touches no
    // raw pointers.
    let path = match CStr::from_ptr(model_path).to_str() {
        Ok(value) => value.to_owned(),
        Err(_) => return std::ptr::null_mut(),
    };
    if !atten_lim_db.is_finite() || atten_lim_db < 0.0 {
        return std::ptr::null_mut();
    }

    let created = catch_unwind(AssertUnwindSafe(move || {
        let params = DfParams::new(PathBuf::from(path)).ok()?;
        // Thresholds and mask reduction mirror upstream's reference C API so
        // output matches the published `deep-filter` binary's behaviour.
        let runtime = RuntimeParams::default_with_ch(1)
            .with_atten_lim(atten_lim_db)
            .with_thresholds(-15.0, 35.0, 35.0)
            .with_post_filter(0.0)
            .with_mask_reduce(ReduceMask::MAX);
        let model = DfTract::new(params, &runtime).ok()?;
        Some(Box::into_raw(Box::new(DfbHandle { model })))
    }));

    match created {
        Ok(Some(handle)) => handle,
        _ => std::ptr::null_mut(),
    }
}

/// Number of samples consumed and produced per `dfb_process_frame` call (480
/// for the 48 kHz DFN3 models).
#[no_mangle]
pub unsafe extern "C" fn dfb_hop_size(handle: *const DfbHandle) -> usize {
    match handle.as_ref() {
        Some(handle) => handle.model.hop_size,
        None => 0,
    }
}

/// Sample rate the loaded model was trained for (48000 for DFN3). Audio at any
/// other rate must be resampled by the caller.
#[no_mangle]
pub unsafe extern "C" fn dfb_sample_rate(handle: *const DfbHandle) -> usize {
    match handle.as_ref() {
        Some(handle) => handle.model.sr,
        None => 0,
    }
}

/// Update the attenuation limit in dB without reloading the model.
#[no_mangle]
pub unsafe extern "C" fn dfb_set_atten_lim(handle: *mut DfbHandle, atten_lim_db: f32) -> i32 {
    let Some(handle) = handle.as_mut() else {
        return DFB_ERR_NULL;
    };
    if !atten_lim_db.is_finite() || atten_lim_db < 0.0 {
        return DFB_ERR_ARG;
    }
    match catch_unwind(AssertUnwindSafe(|| handle.model.set_atten_lim(atten_lim_db))) {
        Ok(()) => DFB_OK,
        Err(_) => DFB_ERR_PANIC,
    }
}

/// Post-filter strength. 0 disables it; upstream suggests up to ~0.05.
#[no_mangle]
pub unsafe extern "C" fn dfb_set_post_filter_beta(handle: *mut DfbHandle, beta: f32) -> i32 {
    let Some(handle) = handle.as_mut() else {
        return DFB_ERR_NULL;
    };
    if !beta.is_finite() || beta < 0.0 {
        return DFB_ERR_ARG;
    }
    match catch_unwind(AssertUnwindSafe(|| handle.model.set_pf_beta(beta))) {
        Ok(()) => DFB_OK,
        Err(_) => DFB_ERR_PANIC,
    }
}

/// Denoise exactly one frame.
///
/// `input` and `output` must each hold `frame_len` floats, where `frame_len`
/// equals `dfb_hop_size`. Samples are ±1.0 float PCM. `out_snr`, when non-null,
/// receives the frame's local SNR estimate. In-place use (`input == output`) is
/// not supported.
///
/// Note the model is causal but not zero-latency: its output lags the input by
/// its internal lookahead, so the caller must delay the dry signal to match if
/// it intends to blend the two.
#[no_mangle]
pub unsafe extern "C" fn dfb_process_frame(
    handle: *mut DfbHandle,
    input: *const f32,
    output: *mut f32,
    frame_len: usize,
    out_snr: *mut f32,
) -> i32 {
    if input.is_null() || output.is_null() {
        return DFB_ERR_NULL;
    }
    let Some(handle) = handle.as_mut() else {
        return DFB_ERR_NULL;
    };
    // A mismatched length would make tract read or write out of bounds.
    if frame_len == 0 || frame_len != handle.model.hop_size {
        return DFB_ERR_ARG;
    }

    let noisy = ArrayView2::from_shape_ptr((1, frame_len), input);
    let enhanced = ArrayViewMut2::from_shape_ptr((1, frame_len), output);

    match catch_unwind(AssertUnwindSafe(|| handle.model.process(noisy, enhanced))) {
        Ok(Ok(snr)) => {
            if !out_snr.is_null() {
                *out_snr = snr;
            }
            DFB_OK
        }
        Ok(Err(_)) => DFB_ERR_RUNTIME,
        Err(_) => DFB_ERR_PANIC,
    }
}

/// Clear the streaming state (rolling spectrogram and analysis buffers) so a
/// seek or track change does not smear the previous audio into the new
/// position.
///
/// This resets the STFT/deep-filter buffers. The neural network's recurrent
/// state is not separately zeroed by upstream's `init`, so a small amount of
/// history decays over the first few frames rather than vanishing instantly.
#[no_mangle]
pub unsafe extern "C" fn dfb_reset(handle: *mut DfbHandle) -> i32 {
    let Some(handle) = handle.as_mut() else {
        return DFB_ERR_NULL;
    };
    match catch_unwind(AssertUnwindSafe(|| handle.model.init())) {
        Ok(Ok(())) => DFB_OK,
        Ok(Err(_)) => DFB_ERR_RUNTIME,
        Err(_) => DFB_ERR_PANIC,
    }
}

/// Free a handle created by `dfb_create`. Safe to call with null.
#[no_mangle]
pub unsafe extern "C" fn dfb_destroy(handle: *mut DfbHandle) {
    if handle.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| drop(Box::from_raw(handle))));
}
