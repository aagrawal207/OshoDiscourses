package com.agraabhi.oshodiscourses.transcript

/** Real oshoworld.com responses captured with curl; the Hindi page is cut to its head and `__NEXT_DATA__`. */
object Fixtures {
    fun read(name: String): String {
        val stream = checkNotNull(Fixtures::class.java.getResourceAsStream("/oshoworld/$name")) { "missing fixture $name" }
        return stream.bufferedReader(Charsets.UTF_8).use { it.readText() }
    }
}
