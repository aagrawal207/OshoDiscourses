package com.agraabhi.oshodiscourses.downloads

import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadError
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadNetwork
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadSource.ARCHIVE
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadSource.OSHOWORLD
import com.google.common.truth.Truth.assertThat
import com.google.common.truth.Truth.assertWithMessage
import org.junit.Test

/** Port of iOS `DownloadSourcePolicyTests`. */
class DownloadSourcePolicyTest {
    @Test
    fun indiaAndNeighboursAreNearOshoworld() {
        val cases = listOf(
            Triple("IN", "America/New_York", true),
            Triple("US", "Asia/Kolkata", true),
            Triple("US", "Asia/Calcutta", true),
            Triple(null, "Asia/Kathmandu", true),
            Triple("BD", "Europe/London", true),
            Triple("US", "America/Los_Angeles", false),
            Triple("GB", "Europe/London", false),
            Triple("SG", "Asia/Singapore", false),
        )
        for ((region, timeZone, near) in cases) {
            assertWithMessage("$region $timeZone").that(DownloadSourcePolicy.isNearOshoworld(region, timeZone)).isEqualTo(near)
        }
    }

    @Test
    fun aSimOrNetworkCountryCountsLikeTheLocaleRegion() {
        assertThat(DownloadSourcePolicy.isNearOshoworld(listOf("US", "IN", null), "America/New_York")).isTrue()
        assertThat(DownloadSourcePolicy.isNearOshoworld(listOf("US", null, "np"), "Europe/Berlin")).isTrue()
        assertThat(DownloadSourcePolicy.isNearOshoworld(listOf("US", "GB", null), "Europe/London")).isFalse()
        assertThat(DownloadSourcePolicy.isNearOshoworld(listOf(null, null, null), "Asia/Colombo")).isTrue()
    }

    @Test
    fun nearListenersTryOshoworldFirstAndOthersTheMirror() {
        val both = listOf(ARCHIVE, OSHOWORLD)
        assertThat(DownloadSourcePolicy.order(both, emptyMap(), nearOshoworld = true)).containsExactly(OSHOWORLD, ARCHIVE).inOrder()
        assertThat(DownloadSourcePolicy.order(both, emptyMap(), nearOshoworld = false)).containsExactly(ARCHIVE, OSHOWORLD).inOrder()
        assertThat(DownloadSourcePolicy.order(listOf(OSHOWORLD), emptyMap(), nearOshoworld = false)).containsExactly(OSHOWORLD)
        assertThat(DownloadSourcePolicy.order(listOf(ARCHIVE), emptyMap(), nearOshoworld = true)).containsExactly(ARCHIVE)
    }

    @Test
    fun measuredSpeedOverridesTheRegionalGuessOnlyWhenClearlyFaster() {
        val both = listOf(ARCHIVE, OSHOWORLD)
        // A US listener whose mirror crawls switches once oshoworld proves faster.
        assertThat(DownloadSourcePolicy.order(both, mapOf(ARCHIVE to 50_000.0, OSHOWORLD to 900_000.0), nearOshoworld = false))
            .containsExactly(OSHOWORLD, ARCHIVE).inOrder()
        assertThat(DownloadSourcePolicy.order(both, mapOf(ARCHIVE to 100_000.0, OSHOWORLD to 120_000.0), nearOshoworld = false))
            .containsExactly(ARCHIVE, OSHOWORLD).inOrder()
        // One measurement is not a comparison.
        assertThat(DownloadSourcePolicy.order(both, mapOf(ARCHIVE to 9_000_000.0), nearOshoworld = true))
            .containsExactly(OSHOWORLD, ARCHIVE).inOrder()
        assertThat(DownloadSourcePolicy.order(both, mapOf(ARCHIVE to 0.0, OSHOWORLD to 1.0), nearOshoworld = true))
            .containsExactly(OSHOWORLD, ARCHIVE).inOrder()
    }

    @Test
    fun recentDownloadsOutweighOldOnes() {
        assertThat(DownloadSourcePolicy.blended(previous = null, sample = 400.0)).isEqualTo(400.0)
        assertThat(DownloadSourcePolicy.blended(previous = 400.0, sample = 0.0)).isEqualTo(200.0)
        assertThat(DownloadSourcePolicy.blended(previous = 400.0, sample = Double.NaN)).isEqualTo(400.0)
        assertThat(DownloadSourcePolicy.blended(previous = null, sample = -1.0)).isEqualTo(0.0)
    }

    @Test
    fun speedsSurviveRelaunchAndIgnoreDamagedValues() {
        val stored = DownloadSourcePolicy.encodeSpeeds(mapOf(ARCHIVE to 1_000.0, OSHOWORLD to 2_500.0))
        assertThat(DownloadSourcePolicy.decodeSpeeds(stored)).containsExactly(ARCHIVE, 1_000.0, OSHOWORLD, 2_500.0)
        assertThat(DownloadSourcePolicy.decodeSpeeds("""{"archive": -5.0, "oshoworld": 3.0, "unknown": 9.0}"""))
            .containsExactly(OSHOWORLD, 3.0)
        assertThat(DownloadSourcePolicy.decodeSpeeds("""{"archive": "fast"}""")).isEmpty()
        assertThat(DownloadSourcePolicy.decodeSpeeds("garbage")).isEmpty()
        assertThat(DownloadSourcePolicy.decodeSpeeds(null)).isEmpty()
    }

    @Test
    fun networkClassificationSeparatesMobileDataFromWiFi() {
        assertThat(DownloadNetworkClassifier.classify(satisfied = false, wifi = true, wired = false, cellular = true)).isEqualTo(DownloadNetwork.OFFLINE)
        assertThat(DownloadNetworkClassifier.classify(satisfied = true, wifi = false, wired = false, cellular = true)).isEqualTo(DownloadNetwork.CELLULAR_ONLY)
        assertThat(DownloadNetworkClassifier.classify(satisfied = true, wifi = true, wired = false, cellular = true)).isEqualTo(DownloadNetwork.UNRESTRICTED)
        assertThat(DownloadNetworkClassifier.classify(satisfied = true, wifi = false, wired = true, cellular = false)).isEqualTo(DownloadNetwork.UNRESTRICTED)
        // A VPN or other interface without cellular is not mobile data.
        assertThat(DownloadNetworkClassifier.classify(satisfied = true, wifi = false, wired = false, cellular = false)).isEqualTo(DownloadNetwork.UNRESTRICTED)
    }

    @Test
    fun aStalledServerIsAbandonedSoonerWhenAnotherCanBeTried() {
        val now = 1_000_000L
        val stalled = now - 120_000
        val moving = now - 119_000
        assertThat(DownloadRules.stallAction(moving, now, restartsSoFar = 5, maxRestarts = 1)).isEqualTo(DownloadRules.StallAction.NONE)
        assertThat(DownloadRules.stallAction(stalled, now, restartsSoFar = 0, maxRestarts = 1)).isEqualTo(DownloadRules.StallAction.RESTART)
        assertThat(DownloadRules.stallAction(stalled, now, restartsSoFar = 1, maxRestarts = 1)).isEqualTo(DownloadRules.StallAction.ABANDON)
        assertThat(DownloadRules.stallAction(stalled, now, restartsSoFar = 1, maxRestarts = DownloadRules.MAX_STALL_RESTARTS))
            .isEqualTo(DownloadRules.StallAction.RESTART)
        assertThat(DownloadRules.maxRestarts(hasFallback = true)).isEqualTo(1)
        assertThat(DownloadRules.maxRestarts(hasFallback = false)).isEqualTo(2)
        assertThat(DownloadRules.shouldTryNextSource(DownloadError.Stalled)).isTrue()
        assertThat(DownloadError.Stalled.message).isEqualTo("The download stopped responding. Check your connection and try again.")
    }
}
