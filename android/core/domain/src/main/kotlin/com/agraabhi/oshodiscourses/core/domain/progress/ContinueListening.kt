package com.agraabhi.oshodiscourses.core.domain.progress

/**
 * Which talks Home's Continue Listening lists, newest first (iOS `HomeView`). The launch restore
 * loads the first of them, so the mini-player and the top of Home always name the same talk.
 */
object ContinueListening {
    /**
     * Recently played, downloaded talks in the catalog with a saved position. The loaded talk is
     * listed before its first save. Completion is not checked: a finished talk played again returns.
     */
    fun discourseIDs(
        progress: PlaybackProgress,
        downloaded: Set<String>,
        currentTrackID: String?,
        isInCatalog: (String) -> Boolean,
    ): List<String> = progress.recentlyPlayed.filter { id ->
        id in downloaded && ((progress.positions[id] ?: 0.0) > 0 || id == currentTrackID) && isInCatalog(id)
    }
}
