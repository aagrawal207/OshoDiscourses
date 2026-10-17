package com.agraabhi.oshodiscourses.core.domain.player

/** Why the audio chain could not attach (iOS `AudioPlayerService.AudioMixFailure`). */
enum class AudioMixFailure(val rawValue: String, val label: String) {
    TRACK_LOADING("trackLoading", "Couldn't load audio track"),
    NO_AUDIO_TRACK("noAudioTrack", "No audio track"),
    TAP_CREATION("tapCreation", "Couldn't attach noise reduction"),
    PLAYBACK("playback", "Playback unavailable"),
}

/** DeepFilterNet model state (iOS `DeepFilterProcessor.Status`). */
sealed interface DeepFilterStatus {
    val label: String

    /** True while the listener hears unprocessed audio despite choosing DeepFilterNet. */
    val isBypassing: Boolean get() = this != Idle && this != Active

    data object Idle : DeepFilterStatus { override val label = "Off" }
    data object Loading : DeepFilterStatus { override val label = "Loading…" }
    data object Active : DeepFilterStatus { override val label = "Active" }
    data object ModelMissing : DeepFilterStatus { override val label = "Model missing" }
    data object InitializationFailed : DeepFilterStatus { override val label = "Failed to load" }
    data class UnsupportedSampleRate(val rate: Double) : DeepFilterStatus { override val label = "Unsupported rate" }
    data object UnsupportedAudioFormat : DeepFilterStatus { override val label = "Unsupported format" }
    data object RuntimeFailure : DeepFilterStatus { override val label = "Stopped on error" }
}

/**
 * What the DeNoise chain is doing right now (iOS `AudioPlayerService.AudioProcessingStatus`).
 * [label] and [detail] are the exact strings the player and DeNoise screen show.
 */
sealed interface AudioProcessingStatus {
    data object Off : AudioProcessingStatus
    data object WaitingForPlayback : AudioProcessingStatus
    data object Preparing : AudioProcessingStatus
    data object LoadingModel : AudioProcessingStatus
    data object ModelReady : AudioProcessingStatus
    data object Active : AudioProcessingStatus
    data object WaitingForAudio : AudioProcessingStatus
    data object Bypassing : AudioProcessingStatus
    data object UnsupportedFormat : AudioProcessingStatus
    data object SourceError : AudioProcessingStatus
    data class SetupFailed(val failure: AudioMixFailure) : AudioProcessingStatus
    data class ModelUnavailable(val status: DeepFilterStatus) : AudioProcessingStatus

    val isActive: Boolean get() = this == Active

    val isIssue: Boolean
        get() = when (this) {
            WaitingForAudio, Bypassing, UnsupportedFormat, SourceError, is SetupFailed, is ModelUnavailable -> true
            else -> false
        }

    val label: String
        get() = when (this) {
            Off -> "Original sound"
            WaitingForPlayback -> "Ready for playback"
            Preparing, LoadingModel, ModelReady -> "Getting ready…"
            Active -> "Enhancement is on"
            WaitingForAudio, Bypassing, SourceError -> "Enhancement paused"
            UnsupportedFormat -> "Unavailable for this recording"
            is SetupFailed -> if (failure == AudioMixFailure.PLAYBACK) "Playback unavailable" else "Enhancement unavailable"
            is ModelUnavailable -> "Enhancement unavailable"
        }

    val detail: String
        get() = when (this) {
            Off -> "Noise reduction and volume boost are off."
            WaitingForPlayback -> "Your choices will apply when you play a discourse."
            Preparing, LoadingModel, ModelReady ->
                "Getting noise reduction ready. Volume boost starts once cleanup is working."
            Active -> "Reducing recording noise. Adjust the controls as you listen."
            WaitingForAudio, Bypassing, SourceError ->
                "Noise reduction and volume boost are temporarily paused. Try another mode if this continues."
            UnsupportedFormat ->
                "This recording can’t use audio enhancement. Noise reduction and volume boost are paused."
            is SetupFailed ->
                if (failure == AudioMixFailure.PLAYBACK) {
                    "Playback could not start. Try playing the discourse again."
                } else {
                    "Enhancement couldn’t start. Try playing the discourse again. Volume boost is paused."
                }
            is ModelUnavailable -> "This mode couldn’t start. Try another listening mode. Volume boost is paused."
        }

    /** Stable token for local logs. */
    val outcome: String
        get() = when (this) {
            Off -> "off"
            WaitingForPlayback -> "waiting"
            Preparing -> "preparing"
            LoadingModel -> "model_loading"
            ModelReady -> "model_ready"
            Active -> "processing"
            WaitingForAudio -> "waiting_for_audio"
            Bypassing -> "bypassing"
            UnsupportedFormat -> "unsupported_format"
            SourceError -> "source_error"
            is SetupFailed -> "setup_${failure.rawValue}"
            is ModelUnavailable -> "model_unavailable"
        }
}
