package com.agraabhi.oshodiscourses.core.model

import com.google.common.truth.Truth.assertThat
import kotlin.test.assertNotNull
import org.junit.Test

/** Port of iOS `OshoDiscoursesTests`, `OshoworldCatalogTests` and the URL half of `ArchiveCatalogTests`. */
class CatalogTest {
    private val catalog = shared

    private fun named(name: String): SeriesInfo = assertNotNull(catalog.allSeries.firstOrNull { it.name == name }, name)

    private fun url(series: SeriesInfo, number: Int) = buildAudioURL(series, number, catalog.oshoworld)

    @Test
    fun catalogHasEveryOshoworldSeriesAndDiscourse() {
        assertThat(catalog.allSeries).hasSize(351)
        assertThat(catalog.allSeries.sumOf { it.count }).isEqualTo(5_481)
        assertThat(catalog.allDiscourses()).hasSize(5_481)
    }

    @Test
    fun languagesSplitAsShipped() {
        assertThat(catalog.englishSeries).hasSize(175)
        assertThat(catalog.hindiSeries).hasSize(176)
        assertThat(catalog.englishSeries.sumOf { it.count }).isEqualTo(3_020)
        assertThat(catalog.hindiSeries.sumOf { it.count }).isEqualTo(2_461)
    }

    @Test
    fun catalogOrderStartsWithEnglishUnderscoreAndEndsWithHindiCatalogSeries() {
        assertThat(catalog.allSeries.first().id).isEqualTo("english-A_Bird_on_the_Wing__")
        assertThat(catalog.allSeries.last().id).isEqualTo("hindi-Swarn_Pakhi_Tha_Jo_Kabhi")
    }

    @Test
    fun urlBuildingUnderscore() {
        val url = url(named("Beyond Enlightenment"), 1)
        assertThat(url).contains("Beyond_Enlightenment")
        assertThat(url).endsWith("01.mp3")
    }

    @Test
    fun urlBuildingSlug() {
        val url = url(named("The Book of Wisdom"), 5)
        assertThat(url).contains("the-book-of-wisdom")
        assertThat(url).endsWith("05.mp3")
    }

    @Test
    fun urlBuildingOshoPrefix() {
        val url = url(named("Ashtavakra Maha Geeta"), 10)
        assertThat(url).contains("OSHO-Maha_Geeta")
        assertThat(url).contains("Hindi Audio")
    }

    @Test
    fun underscorePatternKeepsTrailingSeparatorAndFolderName() {
        val bird = named("A Bird on the Wing")
        assertThat(patternAudioURL(bird, 3)).isEqualTo(
            "https://www.oshoworld.com/wp-content/uploads/newAudios/A_Bird_on_the_Wing_(11)/A_Bird_on_the_Wing__03.mp3",
        )
        val follow = named("Come Follow to You Vol 1")
        assertThat(patternAudioURL(follow, 2)).isEqualTo(
            "https://www.oshoworld.com/wp-content/uploads/newAudios/Come_Follow_to_You_Vol_1_(10)/Come_Follow_to_You_Vol_1-02.mp3",
        )
    }

    @Test
    fun seriesOfAHundredOrMorePadToThreeDigits() {
        val series = named("Es Dhammo Sanantano")
        assertThat(series.count).isEqualTo(122)
        assertThat(patternAudioURL(series, 7))
            .isEqualTo("https://www.oshoworld.com/wp-content/uploads/2020/11/Hindi Audio/OSHO-Es_Dhammo_Sanantano_007.mp3")
    }

    @Test
    fun englishOshoPrefixUsesEnglishAudioFolder() {
        val series = SeriesInfo("Test", "Test_Series", 5, Language.ENGLISH, URLType.OSHO_PREFIX)
        assertThat(patternAudioURL(series, 4))
            .isEqualTo("https://www.oshoworld.com/wp-content/uploads/2020/11/English Audio/OSHO-Test_Series_04.mp3")
    }

    @Test
    fun slugWithoutTitleHasNoPatternURL() {
        val series = SeriesInfo("Test", "Test", 5, Language.ENGLISH, URLType.SLUG, slug = "test-series")
        assertThat(patternAudioURL(series, 1)).isEmpty()
    }

    @Test
    fun curatedListsExist() {
        assertThat(catalog.curated.popularEnglish).isNotEmpty()
        assertThat(catalog.curated.beginnerEnglish).isNotEmpty()
        assertThat(catalog.curated.popularHindi).isNotEmpty()
        assertThat(catalog.curated.beginnerHindi).isNotEmpty()
    }

    @Test
    fun curatedListsResolveEveryName() {
        val names = catalog.curatedNames
        assertThat(catalog.curated.popularEnglish.map { it.name }).containsExactlyElementsIn(names.popularEnglish).inOrder()
        assertThat(catalog.curated.beginnerEnglish.map { it.name }).containsExactlyElementsIn(names.beginnerEnglish).inOrder()
        assertThat(catalog.curated.popularHindi.map { it.name }).containsExactlyElementsIn(names.popularHindi).inOrder()
        assertThat(catalog.curated.beginnerHindi.map { it.name }).containsExactlyElementsIn(names.beginnerHindi).inOrder()
        assertThat(names.popularEnglish).hasSize(8)
        assertThat(names.beginnerEnglish).hasSize(8)
        assertThat(names.popularHindi).hasSize(7)
        assertThat(names.beginnerHindi).hasSize(7)
        assertThat(catalog.curated.popularHindi.first().name).isEqualTo("Ashtavakra Maha Geeta")
    }

    @Test
    fun cachedDiscoursesMatchSeriesCounts() {
        for (series in catalog.allSeries) {
            val discourses = catalog.discourses(series)
            assertThat(discourses).hasSize(series.count)
            assertThat(discourses.first().id).isEqualTo("${series.id}-1")
            assertThat(discourses.map { it.number }).isEqualTo((1..series.count).toList())
        }
    }

    @Test
    fun lookupsResolveEveryDiscourse() {
        for (discourse in catalog.allDiscourses()) {
            val entry = assertNotNull(catalog.entry(discourse.id))
            assertThat(entry.discourse).isEqualTo(discourse)
            assertThat(entry.series.id).isEqualTo(discourse.seriesID)
            assertThat(catalog.discourse(discourse.id)).isEqualTo(discourse)
        }
        assertThat(catalog.entry("english-Nope-1")).isNull()
        assertThat(catalog.series("english-A_Bird_on_the_Wing__")?.name).isEqualTo("A Bird on the Wing")
        assertThat(catalog.series("missing")).isNull()
    }

    @Test
    fun displayTitleNamesSeriesAndNumber() {
        assertThat(catalog.discourse("english-A_Bird_on_the_Wing__-4")?.displayTitle).isEqualTo("A Bird on the Wing - #4")
    }

    @Test
    fun seriesIDsAreUnique() {
        val ids = catalog.allSeries.map { it.id }
        assertThat(ids.toSet()).hasSize(ids.size)
    }

    // OshoworldCatalog.json

    @Test
    fun overridesLoad() {
        assertThat(catalog.oshoworld.overrideCount).isAtLeast(800)
    }

    @Test
    fun renamedFolderUsesTheSitePathNotThePattern() {
        val series = named("The Perfect Master")
        assertThat(patternAudioURL(series, 1)).endsWith("The Perfect Master 01.mp3")
        assertThat(url(series, 1)).endsWith("the-perfect-master-series/The Perfect Master Vol 1 01.mp3")
        assertThat(url(series, 11)).endsWith("The Perfect Master Vol 2 01.mp3")
    }

    @Test
    fun catalogTypeSeriesResolveEveryDiscourse() {
        val catalogSeries = catalog.allSeries.filter { it.urlType == URLType.CATALOG }
        assertThat(catalogSeries).hasSize(13)
        for (series in catalogSeries) {
            assertThat(patternAudioURL(series, 1)).isEmpty()
            for (discourse in catalog.discourses(series)) {
                assertThat(discourse.audioURL).startsWith("https://www.oshoworld.com/")
                assertThat(discourse.audioURL).endsWith(".mp3")
            }
        }
    }

    @Test
    fun skippedSiteNumbersFollowThePosition() {
        val series = named("Swarn Pakhi Tha Jo Kabhi")
        assertThat(series.count).isEqualTo(22)
        assertThat(url(series, 18)).endsWith("OSHO-Swarn_Pakhi_Tha_Jo_Kabhi_19.mp3")
        assertThat(url(series, 17)).endsWith("OSHO-Swarn_Pakhi_Tha_Jo_Kabhi_17.mp3")
    }

    @Test
    fun noDiscourseIsLeftWithoutAnyURL() {
        for (discourse in catalog.allDiscourses()) assertThat(discourse.audioURL).isNotEmpty()
    }

    @Test
    fun missingOverridesFallBackToPatterns() {
        val empty = OshoworldCatalog.load { null }
        assertThat(empty.overrideCount).isEqualTo(0)
        val series = named("The Perfect Master")
        assertThat(buildAudioURL(series, 1, empty)).isEqualTo(patternAudioURL(series, 1))
    }

    // ArchiveCatalog.json

    @Test
    fun archiveMappingCoversMostOfTheCatalog() {
        assertThat(catalog.archiveCatalog.mappedSeriesCount).isAtLeast(320)
        assertThat(catalog.archiveCatalog.mappedDiscourseCount).isAtLeast(4_800)
    }

    @Test
    fun ashtavakraMahaGeetaResolvesToKnownArchiveURL() {
        val discourse = catalog.discourses(named("Ashtavakra Maha Geeta")).first()
        assertThat(catalog.archiveAudioURL(discourse)).isEqualTo(
            "https://archive.org/download/osho-audio-discourses-collection/OSHO_WORLD/Hindi/100-Maha%20Geeta%2001-91%20%E2%80%93%20Osho%20World/OSHO-Maha_Geeta_01.mp3",
        )
    }

    @Test
    fun everyMappedArchiveURLIsWellFormed() {
        for (discourse in catalog.allDiscourses()) {
            val url = catalog.archiveAudioURL(discourse) ?: continue
            val uri = java.net.URI(url)
            assertThat(uri.scheme).isEqualTo("https")
            assertThat(uri.host).isEqualTo("archive.org")
        }
    }

    @Test
    fun seriesIDRoundTripsForEveryDiscourse() {
        for (series in catalog.allSeries) {
            for (discourse in catalog.discourses(series)) assertThat(discourse.seriesID).isEqualTo(series.id)
        }
    }

    @Test
    fun unmappedDiscourseHasNoArchiveURLOrCover() {
        val series = named("A Sudden Clash of Thunder")
        assertThat(catalog.archiveAudioURL(catalog.discourses(series).first())).isNull()
        assertThat(catalog.coverURL(series.id)).isNull()
    }

    @Test
    fun mappedSeriesHasCover() {
        assertThat(catalog.coverURL(named("Ashtavakra Maha Geeta").id)).endsWith(".png")
    }

    @Test
    fun damagedWisdomRecordingUsesTheOriginalSource() {
        val entry = assertNotNull(catalog.entry("english-Wisdom_Of_The_Sands-3"))
        assertThat(catalog.archiveAudioURL(entry.discourse)).isNull()
        assertThat(entry.discourse.audioURL).isEqualTo(
            "https://www.oshoworld.com/wp-content/uploads/newAudios/wisdom-of-the-sands-series/Wisdom Of The Sands Vol 1 03.mp3",
        )
        assertThat(catalog.coverURL(entry.series.id)).isNotNull()
    }

    @Test
    fun missingArchiveJsonDisablesTheMirror() {
        val empty = ArchiveCatalog.load { null }
        assertThat(empty.audioURL(catalog.allDiscourses().first())).isNull()
        assertThat(empty.mappedSeriesCount).isEqualTo(0)
    }

    // TranscriptCatalog.json

    @Test
    fun transcriptAvailabilityMatchesShippedCatalog() {
        assertThat(catalog.hasTranscript("english-A_Bird_on_the_Wing__-1")).isTrue()
        assertThat(catalog.hasTranscript("english-Nope-1")).isFalse()
        assertThat(catalog.allSeries.sumOf { catalog.transcriptCount(it.id) }).isEqualTo(4_946)
        assertThat(catalog.allDiscourses().count { catalog.hasTranscript(it.id) }).isEqualTo(4_946)
    }

    companion object {
        val shared: BundledCatalogRepository by lazy { BundledCatalogRepository().also { it.warmUp() } }
    }
}
