package com.agraabhi.oshodiscourses.transcript

import kotlinx.serialization.json.Json
import kotlin.math.abs

/**
 * Paragraph start times computed ahead of time by `Tools/AlignTranscripts` and shipped with the
 * app (iOS `AlignmentCatalog`). Each discourse is one string, `"<paragraphs>;<duration>;<starts>"`,
 * in tenths of a second, each start a delta from the previous known one and `-` where unmatched.
 */
class AlignmentCatalog(private val encoded: Map<String, String>) {
    data class Entry(
        val paragraphCount: Int,
        /** Seconds; length of the recording the alignment was made against. */
        val duration: Double,
        /** Seconds, one per paragraph; null where no landmark fell inside it. */
        val starts: List<Double?>,
    ) {
        val matchedCount: Int get() = starts.count { it != null }

        /** Same split and same recording only: a trimmed intro would shift every paragraph. */
        fun matches(paragraphCount: Int, duration: Double): Boolean =
            this.paragraphCount == paragraphCount && starts.size == paragraphCount &&
                abs(this.duration - duration) <= DURATION_TOLERANCE

        companion object {
            const val DURATION_TOLERANCE: Double = 2.5
        }
    }

    val count: Int get() = encoded.size

    val discourseIDs: Set<String> get() = encoded.keys

    fun hasAlignment(discourseID: String): Boolean = discourseID in encoded

    fun entry(discourseID: String): Entry? = encoded[discourseID]?.let(::decode)

    companion object {
        const val RESOURCE: String = "/AlignmentCatalog.json"

        /** The shipped catalog from the classpath; empty (estimates only) if it is missing or corrupt. */
        fun loadShipped(): AlignmentCatalog = runCatching {
            val stream = checkNotNull(AlignmentCatalog::class.java.getResourceAsStream(RESOURCE))
            AlignmentCatalog(Json.decodeFromString<Map<String, String>>(stream.bufferedReader().use { it.readText() }))
        }.getOrElse { AlignmentCatalog(emptyMap()) }

        fun encode(entry: Entry): String {
            var previous = 0L
            val tokens = entry.starts.joinToString(",") { start ->
                if (start == null) {
                    "-"
                } else {
                    val tenths = Math.round(start * 10)
                    (tenths - previous).toString().also { previous = tenths }
                }
            }
            return "${entry.paragraphCount};${Math.round(entry.duration * 10)};$tokens"
        }

        fun decode(string: String): Entry? {
            val fields = string.split(';')
            if (fields.size != 3) return null
            val paragraphCount = fields[0].toIntOrNull() ?: return null
            val durationTenths = fields[1].toIntOrNull() ?: return null
            val starts = ArrayList<Double?>(paragraphCount.coerceAtLeast(0))
            var previous = 0
            if (fields[2].isNotEmpty()) {
                for (token in fields[2].split(',')) {
                    if (token == "-") {
                        starts.add(null)
                        continue
                    }
                    previous += token.toIntOrNull() ?: return null
                    starts.add(previous / 10.0)
                }
            }
            if (starts.size != paragraphCount) return null
            return Entry(paragraphCount, durationTenths / 10.0, starts)
        }
    }
}
