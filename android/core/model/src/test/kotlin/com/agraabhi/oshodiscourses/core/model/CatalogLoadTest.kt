package com.agraabhi.oshodiscourses.core.model

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class CatalogLoadTest {
    @Test
    fun nothingParsesUntilFirstUse() {
        val opened = mutableListOf<String>()
        val repository = BundledCatalogRepository { name -> opened += name; ResourceOpener.classpath.open(name) }
        assertThat(opened).isEmpty()
        repository.series("english-A_Bird_on_the_Wing__")
        assertThat(opened).containsExactly(BundledCatalogRepository.CATALOG_RESOURCE, OshoworldCatalog.RESOURCE)
        repository.coverURL("english-A_Bird_on_the_Wing__")
        repository.hasTranscript("english-A_Bird_on_the_Wing__-1")
        assertThat(opened).containsExactly(
            BundledCatalogRepository.CATALOG_RESOURCE,
            OshoworldCatalog.RESOURCE,
            ArchiveCatalog.RESOURCE,
            BundledCatalogRepository.TRANSCRIPT_RESOURCE,
        )
    }

    @Test
    fun warmUpOfAFreshRepositoryIsFast() {
        val cold = System.nanoTime()
        BundledCatalogRepository().warmUp() // JIT and class loading, which a phone pays once per process
        println("BundledCatalogRepository.warmUp cold: ${(System.nanoTime() - cold) / 1_000_000} ms")
        val started = System.nanoTime()
        BundledCatalogRepository().warmUp()
        val millis = (System.nanoTime() - started) / 1_000_000
        println("BundledCatalogRepository.warmUp: $millis ms")
        assertThat(millis).isLessThan(1_000)
    }

    @Test
    fun missingCatalogResourceFailsLoudly() {
        val repository = BundledCatalogRepository { null }
        val error = runCatching { repository.allSeries }.exceptionOrNull()
        assertThat(error).hasMessageThat().contains("export-catalog.sh")
        assertThat(repository.coverURL("x")).isNull()
        assertThat(repository.hasTranscript("x-1")).isFalse()
    }
}
