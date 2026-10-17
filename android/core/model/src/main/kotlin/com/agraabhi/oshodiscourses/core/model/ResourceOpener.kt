package com.agraabhi.oshodiscourses.core.model

import java.io.InputStream

/** Opens a shipped resource by file name, or returns null when it is missing. */
fun interface ResourceOpener {
    fun open(name: String): InputStream?

    companion object {
        /** The JVM classpath; on Android the JSON is packaged as Java resources of `:core:model`. */
        val classpath: ResourceOpener = ResourceOpener { name ->
            ResourceOpener::class.java.getResourceAsStream("/$name")
        }
    }
}

internal fun ResourceOpener.readText(name: String): String? =
    open(name)?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }
