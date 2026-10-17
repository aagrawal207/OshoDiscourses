package com.agraabhi.oshodiscourses.core.data.json

import kotlinx.serialization.KSerializer
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import kotlin.math.roundToLong

/**
 * Matches Swift's synthesized `Codable` with a default `JSONEncoder`: every non-optional
 * property is written, nil optionals are omitted, and unknown keys from newer versions are ignored.
 */
internal val IosJson: Json = Json {
    encodeDefaults = true
    explicitNulls = false
    ignoreUnknownKeys = true
}

/** Milliseconds between 1970-01-01 and Foundation's reference date, 2001-01-01 UTC. */
internal const val APPLE_REFERENCE_DATE_OFFSET_MILLIS: Long = 978_307_200_000L

/**
 * Epoch milliseconds stored as a Swift `Date` under the default strategy: Double seconds since
 * 2001-01-01. iOS keeps sub-millisecond precision, which rounds away on decode.
 */
internal object AppleDateSerializer : KSerializer<Long> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor("AppleDate", PrimitiveKind.DOUBLE)

    override fun serialize(encoder: Encoder, value: Long) = encoder.encodeDouble(toAppleSeconds(value))

    override fun deserialize(decoder: Decoder): Long = fromAppleSeconds(decoder.decodeDouble())

    fun toAppleSeconds(epochMillis: Long): Double = (epochMillis - APPLE_REFERENCE_DATE_OFFSET_MILLIS) / 1000.0

    fun fromAppleSeconds(seconds: Double): Long = (seconds * 1000).roundToLong() + APPLE_REFERENCE_DATE_OFFSET_MILLIS
}
