package com.agraabhi.oshodiscourses.core.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** iOS `UserSettings.Appearance`. Raw values are the persisted strings. */
@Serializable
enum class Appearance(val rawValue: String) {
    @SerialName("system") SYSTEM("system"),
    @SerialName("dark") DARK("dark"),
    @SerialName("light") LIGHT("light"),
    ;

    companion object {
        fun fromRawValue(value: String?): Appearance? = entries.firstOrNull { it.rawValue == value }
    }
}

/**
 * The eight accent colours (iOS `AccentTheme`), in palette order. The order drives the daily
 * shuffle, so it must not change. Colour values live in `:core:ui`.
 */
@Serializable
enum class AccentTheme(val rawValue: String) {
    @SerialName("blue") BLUE("blue"),
    @SerialName("teal") TEAL("teal"),
    @SerialName("purple") PURPLE("purple"),
    @SerialName("pink") PINK("pink"),
    @SerialName("orange") ORANGE("orange"),
    @SerialName("green") GREEN("green"),
    @SerialName("indigo") INDIGO("indigo"),
    @SerialName("mint") MINT("mint"),
    ;

    val displayName: String get() = rawValue.replaceFirstChar { it.uppercase() }

    companion object {
        fun fromRawValue(value: String?): AccentTheme? = entries.firstOrNull { it.rawValue == value }

        /** Maps a day index to a palette colour by cycling through all cases in order. */
        fun shuffled(daysSinceEpoch: Long): AccentTheme {
            val count = entries.size
            val index = ((daysSinceEpoch % count) + count) % count
            return entries[index.toInt()]
        }
    }
}

/** iOS `LanguageFilter`; raw values are the persisted strings and the picker labels. */
@Serializable
enum class LanguageFilter(val rawValue: String) {
    @SerialName("Both") BOTH("Both"),
    @SerialName("English") ENGLISH("English"),
    @SerialName("Hindi") HINDI("Hindi"),
    ;

    val hidesHindi: Boolean get() = this == ENGLISH
    val hidesEnglish: Boolean get() = this == HINDI

    companion object {
        fun fromRawValue(value: String?): LanguageFilter? = entries.firstOrNull { it.rawValue == value }
    }
}

/** Post-model pause reduction and quiet-speech lift (iOS `VoiceFocusPreset`). */
@Serializable
enum class VoiceFocusPreset(val rawValue: String, val displayName: String, val detail: String) {
    @SerialName("focus")
    FOCUS(
        "focus",
        "Natural",
        "Quieter pauses, with no extra lift for soft speech. Keeps more of the voice’s natural dynamics.",
    ),

    @SerialName("lift")
    LIFT(
        "lift",
        "Gentle Lift",
        "Brings out quieter words without turning up the whole recording.",
    ),

    @SerialName("strong")
    STRONG(
        "strong",
        "Extra Lift",
        "More lift for soft speech and quieter pauses. The voice may sound less natural.",
    ),
    ;

    companion object {
        fun fromRawValue(value: String?): VoiceFocusPreset? = entries.firstOrNull { it.rawValue == value }
    }
}

/** Which denoiser runs (iOS `NoiseReductionMode`). */
@Serializable
enum class NoiseReductionMode(
    val rawValue: String,
    val displayName: String,
    val batteryNote: String,
    val detail: String,
) {
    @SerialName("deepFilterNet")
    DEEP_FILTER_NET(
        "deepFilterNet",
        "Best Quality",
        "Uses more battery",
        "Our recommended cleanup for hiss and background noise.",
    ),

    @SerialName("rnnoise")
    RNNOISE(
        "rnnoise",
        "Balanced",
        "Uses less battery than Best Quality",
        "Everyday noise reduction with lighter processing. May soften the voice.",
    ),

    @SerialName("cadence")
    CADENCE(
        "cadence",
        "Gentle Cleanup",
        "Lightest on battery",
        "Reduces hum and noise in pauses. Less effective during speech.",
    ),
    ;

    companion object {
        fun fromRawValue(value: String?): NoiseReductionMode? = entries.firstOrNull { it.rawValue == value }
    }
}

/**
 * Noise reduction amount (iOS `AudioPlayerService.DenoiseStrength`). DeepFilterNet uses
 * [attenuationLimitDb]; RNNoise uses [wetMix]; Cadence uses [intensity].
 */
@Serializable
enum class DenoiseStrength(
    val rawValue: String,
    val label: String,
    val detail: String,
    val wetMix: Float,
    val intensity: Float,
    val attenuationLimitDb: Float,
) {
    @SerialName("light")
    LIGHT("light", "Light", "Gentle cleanup that keeps more of the original sound.", 0.35f, 0.45f, 6f),

    @SerialName("medium")
    MEDIUM("medium", "Medium", "A good starting point for most recordings.", 0.5f, 0.7f, 12f),

    @SerialName("strong")
    STRONG("strong", "Strong", "More noise reduction. The voice may sound less natural.", 0.6f, 1.0f, 100f),
    ;

    companion object {
        fun fromRawValue(value: String?): DenoiseStrength? = entries.firstOrNull { it.rawValue == value }
    }
}

/** Boost ladder shown in the DeNoise screen (iOS `AudioEnhancementView.boostLevels`). */
enum class BoostLevel(val gain: Float, val label: String) {
    OFF(1f, "Off"),
    LOW(1.5f, "Low"),
    MEDIUM(2f, "Medium"),
    HIGH(3f, "High"),
    MAX(4f, "Max"),
    ;

    companion object {
        /** Highest boost offered; above unity the peaks are limited rather than clipped. */
        const val MAXIMUM_GAIN: Float = 4f
    }
}
