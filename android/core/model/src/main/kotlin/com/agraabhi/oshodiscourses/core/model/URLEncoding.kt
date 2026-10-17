package com.agraabhi.oshodiscourses.core.model

/**
 * Percent-encoding that matches Foundation's `addingPercentEncoding` with the URL character
 * sets the iOS app uses, so request URLs and archive.org paths are byte-identical.
 */
object URLEncoding {
    private const val UNRESERVED = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

    /** Foundation `CharacterSet.urlQueryAllowed`. */
    private val queryAllowed = allowedSet(UNRESERVED + "!$&'()*+,-./:;=?@_~")

    /** Foundation `CharacterSet.urlPathAllowed`: the query set without `?`. */
    private val pathAllowed = allowedSet(UNRESERVED + "!$&'()*+,-./:;=@_~")

    /**
     * The oshoworld request URL for a stored, un-encoded audio URL (iOS
     * `DownloadService.encodedURL`). Spaces become %20; null for an empty URL.
     */
    fun requestURL(rawURL: String): String? = if (rawURL.isEmpty()) null else encode(rawURL, queryAllowed)

    /** Encodes a path, keeping `/` (iOS `ArchiveCatalog.buildURL`). */
    fun encodePath(path: String): String = encode(path, pathAllowed)

    private fun allowedSet(chars: String): BooleanArray {
        val allowed = BooleanArray(128)
        for (c in chars) allowed[c.code] = true
        return allowed
    }

    private fun encode(value: String, allowed: BooleanArray): String {
        if (value.all { it.code < 128 && allowed[it.code] }) return value
        val out = StringBuilder(value.length + 16)
        for (byte in value.toByteArray(Charsets.UTF_8)) {
            val b = byte.toInt() and 0xFF
            if (b < 128 && allowed[b]) {
                out.append(b.toChar())
            } else {
                out.append('%').append(HEX[b shr 4]).append(HEX[b and 0x0F])
            }
        }
        return out.toString()
    }

    private const val HEX = "0123456789ABCDEF"
}
