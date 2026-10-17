package com.agraabhi.oshodiscourses.downloads

import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadNetwork
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadSource
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonObject

/**
 * Chooses which server to try first (iOS `DownloadSourcePolicy`). Measured 2026-10-12: from
 * Mumbai, connecting took 28 ms to oshoworld.com and 300-570 ms to archive.org; from the US, the reverse.
 */
object DownloadSourcePolicy {
    val nearOshoworldRegions: Set<String> = setOf("IN", "NP", "BD", "LK", "BT")
    val nearOshoworldTimeZones: Set<String> = setOf(
        "Asia/Kolkata", "Asia/Calcutta", "Asia/Kathmandu", "Asia/Katmandu", "Asia/Dhaka", "Asia/Colombo", "Asia/Thimphu",
    )

    /** A measured server must be clearly faster before it overrides the regional default. */
    const val SWITCH_RATIO: Double = 1.25
    const val SPEEDS_KEY: String = "downloads.sourceBytesPerSecond"

    /** Either signal counts: many listeners in India set their phone's region to the US. */
    fun isNearOshoworld(region: String?, timeZone: String): Boolean =
        (region != null && region.uppercase() in nearOshoworldRegions) || timeZone in nearOshoworldTimeZones

    /** Android adds SIM and network country to the locale region; any one of them counts. */
    fun isNearOshoworld(regions: Collection<String?>, timeZone: String): Boolean =
        regions.any { isNearOshoworld(it, timeZone = "") } || timeZone in nearOshoworldTimeZones

    fun order(
        available: Collection<DownloadSource>,
        speeds: Map<DownloadSource, Double>,
        nearOshoworld: Boolean,
    ): List<DownloadSource> {
        val regional = if (nearOshoworld) listOf(DownloadSource.OSHOWORLD, DownloadSource.ARCHIVE) else listOf(DownloadSource.ARCHIVE, DownloadSource.OSHOWORLD)
        val order = regional.filter { it in available }
        if (order.size != 2) return order
        val first = speeds[order[0]] ?: return order
        val second = speeds[order[1]] ?: return order
        // This phone's own experience beats the regional guess once both servers have been tried.
        return if (second > first * SWITCH_RATIO) listOf(order[1], order[0]) else order
    }

    /** Recent downloads matter more than old ones, so a network change shows up within a few downloads. */
    fun blended(previous: Double?, sample: Double): Double {
        if (!sample.isFinite() || sample < 0) return previous ?: 0.0
        if (previous == null || !previous.isFinite()) return sample
        return previous * 0.5 + sample * 0.5
    }

    /** Parses the stored speeds, dropping unknown sources and damaged values. */
    fun decodeSpeeds(stored: String?): Map<DownloadSource, Double> {
        if (stored.isNullOrEmpty()) return emptyMap()
        val obj = runCatching { Json.parseToJsonElement(stored).jsonObject }.getOrNull() ?: return emptyMap()
        val speeds = mutableMapOf<DownloadSource, Double>()
        for ((key, value) in obj) {
            val source = DownloadSource.entries.firstOrNull { it.rawValue == key } ?: continue
            val speed = (value as? JsonPrimitive)?.takeUnless { it.isString }?.doubleOrNull ?: continue
            if (speed.isFinite() && speed >= 0) speeds[source] = speed
        }
        return speeds
    }

    fun encodeSpeeds(speeds: Map<DownloadSource, Double>): String =
        JsonObject(speeds.entries.associate { (source, speed) -> source.rawValue to JsonPrimitive(speed) }).toString()
}

/** iOS `DownloadNetwork.classify`, from Android transport flags. */
object DownloadNetworkClassifier {
    fun classify(satisfied: Boolean, wifi: Boolean, wired: Boolean, cellular: Boolean): DownloadNetwork {
        if (!satisfied) return DownloadNetwork.OFFLINE
        if (wifi || wired) return DownloadNetwork.UNRESTRICTED
        return if (cellular) DownloadNetwork.CELLULAR_ONLY else DownloadNetwork.UNRESTRICTED
    }
}
