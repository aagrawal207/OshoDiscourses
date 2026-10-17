package com.agraabhi.oshodiscourses.core.model

import com.google.common.truth.Truth.assertThat
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Test

class ShippedResourcesTest {
    private fun read(name: String): String {
        val stream = checkNotNull(javaClass.getResourceAsStream("/$name")) { "$name is not on the classpath" }
        return stream.bufferedReader().use { it.readText() }
    }

    @Test
    fun transcriptCatalogLoadsFromIosResources() {
        val catalog = Json.parseToJsonElement(read("TranscriptCatalog.json")).jsonObject
        val entry = catalog.getValue("english-A_Bird_on_the_Wing__-1").jsonObject
        assertThat(entry.getValue("slug").jsonPrimitive.content).isEqualTo("a-bird-on-the-wing-01")
        assertThat(catalog.size).isGreaterThan(4_000)
    }

    @Test
    fun everyShippedCatalogIsOnTheClasspath() {
        for (name in listOf("ArchiveCatalog.json", "OshoworldCatalog.json", "TranscriptCatalog.json", "AlignmentCatalog.json")) {
            assertThat(Json.parseToJsonElement(read(name))).isInstanceOf(JsonObject::class.java)
        }
    }

    @Test
    fun assetCatalogMetadataIsNotPackaged() {
        assertThat(javaClass.getResource("/Assets.xcassets/Contents.json")).isNull()
    }
}
