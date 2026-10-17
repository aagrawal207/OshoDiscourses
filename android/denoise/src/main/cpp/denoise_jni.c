// JNI shim over RNNoise and the DeepFilterNet bridge. Frames go through stack copies, so the
// audio thread never pins a Java array or allocates while a model runs.

#include <jni.h>
#include <stdint.h>

#include "DeepFilterBridge.h"
#include "rnnoise.h"

// Both models use 480-sample hops; the cap only bounds the stack copies.
#define MAX_FRAME 2048

#define RN(name) Java_com_agraabhi_oshodiscourses_denoise_nativebridge_RNNoiseNative_##name
#define DF(name) Java_com_agraabhi_oshodiscourses_denoise_nativebridge_DeepFilterNative_##name

static inline void *from_handle(jlong handle) { return (void *)(intptr_t)handle; }

static inline jlong to_handle(const void *pointer) { return (jlong)(intptr_t)pointer; }

JNIEXPORT jint JNICALL RN(frameSize)(JNIEnv *env, jclass type) {
    (void)env;
    (void)type;
    return rnnoise_get_frame_size();
}

JNIEXPORT jlong JNICALL RN(create)(JNIEnv *env, jclass type) {
    (void)env;
    (void)type;
    return to_handle(rnnoise_create(NULL));
}

JNIEXPORT jint JNICALL RN(reset)(JNIEnv *env, jclass type, jlong handle) {
    (void)env;
    (void)type;
    if (handle == 0) return -1;
    return rnnoise_init((DenoiseState *)from_handle(handle), NULL);
}

JNIEXPORT void JNICALL RN(destroy)(JNIEnv *env, jclass type, jlong handle) {
    (void)env;
    (void)type;
    if (handle != 0) rnnoise_destroy((DenoiseState *)from_handle(handle));
}

JNIEXPORT jboolean JNICALL RN(processFrame)(JNIEnv *env, jclass type, jlong handle,
                                            jfloatArray output, jfloatArray input) {
    (void)type;
    const int frame = rnnoise_get_frame_size();
    if (handle == 0 || output == NULL || input == NULL || frame <= 0 || frame > MAX_FRAME) {
        return JNI_FALSE;
    }
    if ((*env)->GetArrayLength(env, input) < frame || (*env)->GetArrayLength(env, output) < frame) {
        return JNI_FALSE;
    }
    float in[MAX_FRAME];
    float out[MAX_FRAME];
    (*env)->GetFloatArrayRegion(env, input, 0, frame, in);
    rnnoise_process_frame((DenoiseState *)from_handle(handle), out, in);
    (*env)->SetFloatArrayRegion(env, output, 0, frame, out);
    return JNI_TRUE;
}

JNIEXPORT jlong JNICALL DF(create)(JNIEnv *env, jclass type, jstring path, jfloat attenuation) {
    (void)type;
    if (path == NULL) return 0;
    const char *utf = (*env)->GetStringUTFChars(env, path, NULL);
    if (utf == NULL) return 0;
    DfbHandle *handle = dfb_create(utf, attenuation);
    (*env)->ReleaseStringUTFChars(env, path, utf);
    return to_handle(handle);
}

JNIEXPORT jint JNICALL DF(hopSize)(JNIEnv *env, jclass type, jlong handle) {
    (void)env;
    (void)type;
    return (jint)dfb_hop_size((const DfbHandle *)from_handle(handle));
}

JNIEXPORT jint JNICALL DF(sampleRate)(JNIEnv *env, jclass type, jlong handle) {
    (void)env;
    (void)type;
    return (jint)dfb_sample_rate((const DfbHandle *)from_handle(handle));
}

JNIEXPORT jint JNICALL DF(setAttenuationLimit)(JNIEnv *env, jclass type, jlong handle, jfloat db) {
    (void)env;
    (void)type;
    return dfb_set_atten_lim((DfbHandle *)from_handle(handle), db);
}

JNIEXPORT jint JNICALL DF(setPostFilterBeta)(JNIEnv *env, jclass type, jlong handle, jfloat beta) {
    (void)env;
    (void)type;
    return dfb_set_post_filter_beta((DfbHandle *)from_handle(handle), beta);
}

JNIEXPORT jint JNICALL DF(reset)(JNIEnv *env, jclass type, jlong handle) {
    (void)env;
    (void)type;
    return dfb_reset((DfbHandle *)from_handle(handle));
}

JNIEXPORT void JNICALL DF(destroy)(JNIEnv *env, jclass type, jlong handle) {
    (void)env;
    (void)type;
    dfb_destroy((DfbHandle *)from_handle(handle));
}

JNIEXPORT jint JNICALL DF(processFrame)(JNIEnv *env, jclass type, jlong handle, jfloatArray input,
                                        jint inputOffset, jfloatArray output, jint frameLength,
                                        jfloatArray snr) {
    (void)type;
    DfbHandle *model = (DfbHandle *)from_handle(handle);
    if (model == NULL || input == NULL || output == NULL) {
        // The bridge owns the error contract, including for null arguments.
        return dfb_process_frame(model, NULL, NULL, frameLength < 0 ? 0 : (size_t)frameLength, NULL);
    }
    if (frameLength <= 0 || frameLength > MAX_FRAME || inputOffset < 0
        || (*env)->GetArrayLength(env, input) - inputOffset < frameLength
        || (*env)->GetArrayLength(env, output) < frameLength) {
        return DFB_ERR_ARG;
    }
    float in[MAX_FRAME];
    float out[MAX_FRAME];
    float estimate = 0;
    (*env)->GetFloatArrayRegion(env, input, inputOffset, frameLength, in);
    int status = dfb_process_frame(model, in, out, (size_t)frameLength, &estimate);
    if (status == DFB_OK) {
        (*env)->SetFloatArrayRegion(env, output, 0, frameLength, out);
        if (snr != NULL && (*env)->GetArrayLength(env, snr) > 0) {
            (*env)->SetFloatArrayRegion(env, snr, 0, 1, &estimate);
        }
    }
    return status;
}
