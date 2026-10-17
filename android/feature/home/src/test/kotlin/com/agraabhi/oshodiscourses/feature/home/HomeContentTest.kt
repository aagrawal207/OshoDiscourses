package com.agraabhi.oshodiscourses.feature.home

import com.agraabhi.oshodiscourses.core.domain.player.PlayerState
import com.agraabhi.oshodiscourses.core.domain.progress.PlaybackProgress
import com.agraabhi.oshodiscourses.core.model.LanguageFilter
import com.agraabhi.oshodiscourses.core.testing.FakeCatalogRepository
import com.google.common.truth.Truth.assertThat
import org.junit.Test

class HomeContentTest {
    private val catalog = FakeCatalogRepository(allSeries = HomeFixtures.series)
    private val vbt = HomeFixtures.vbt

    private fun id(n: Int) = HomeFixtures.id(vbt, n)

    private fun build(
        recent: List<String>,
        positions: Map<String, Double> = recent.associateWith { 60.0 },
        downloaded: Set<String> = recent.toSet(),
        current: String? = null,
        language: LanguageFilter = LanguageFilter.BOTH,
        completed: List<String> = emptyList(),
    ) = HomeContent.build(
        catalog,
        PlaybackProgress(positions = positions, recentlyPlayed = recent, listenedCompleted = completed),
        downloaded,
        current,
        language,
    )

    @Test
    fun continueListeningNeedsADownloadAndProgressOrTheCurrentTrack() {
        val state = build(
            recent = listOf(id(1), id(2), id(3), id(4)),
            positions = mapOf(id(1) to 10.0, id(3) to 0.0),
            downloaded = setOf(id(1), id(3), id(4)),
            current = id(4),
        )
        assertThat(state.continueListening.map { it.id }).containsExactly(id(1), id(4)).inOrder()
    }

    @Test
    fun countsEightShowsFourGroupedByFirstAppearance() {
        val mg = HomeFixtures.mahaGeeta
        val recent = listOf(id(1), HomeFixtures.id(mg, 1), id(2), id(3)) + (4..10).map(::id)
        val state = build(recent)
        assertThat(state.continueListening).hasSize(8)
        assertThat(state.continueGroups.map { it.series.id }).containsExactly(vbt.id, mg.id).inOrder()
        assertThat(state.continueGroups[0].items.map { it.id }).containsExactly(id(1), id(2), id(3)).inOrder()
    }

    @Test
    fun recentlyCompletedShowsSixAndSkipsUnknownIDs() {
        val state = build(recent = emptyList(), completed = listOf("english-gone-1") + (1..8).map(::id))
        assertThat(state.recentlyCompleted.map { it.id }).containsExactlyElementsIn((1..6).map(::id)).inOrder()
    }

    @Test
    fun shelvesFollowTheLanguageFilter() {
        assertThat(build(emptyList()).shelves.map { it.title }).containsExactly(
            "Popular in English",
            "Beginner Friendly (English)",
            "Popular in Hindi",
            "Beginner Friendly (Hindi)",
        ).inOrder()
        assertThat(build(emptyList(), language = LanguageFilter.ENGLISH).shelves.map { it.title })
            .containsExactly("Popular in English", "Beginner Friendly (English)")
        assertThat(build(emptyList(), language = LanguageFilter.HINDI).shelves.map { it.title })
            .containsExactly("Popular in Hindi", "Beginner Friendly (Hindi)")
    }

    @Test
    fun progressUsesLiveValuesForTheCurrentTrack() {
        val item = build(listOf(id(1)), positions = mapOf(id(1) to 100.0)).continueListening.single().copy(savedDuration = 400.0)
        assertThat(HomeContent.progressFraction(item, PlayerState())).isEqualTo(0.25f)
        val live = PlayerState(currentTrackId = id(1), currentTime = 300.0, duration = 600.0)
        assertThat(HomeContent.progressFraction(item, live)).isEqualTo(0.5f)
        assertThat(HomeContent.progressFraction(item.copy(position = 900.0), PlayerState())).isEqualTo(1f)
        assertThat(HomeContent.progressFraction(item.copy(savedDuration = 0.0), PlayerState())).isEqualTo(0f)
    }
}
