package com.agraabhi.oshodiscourses.core.ui

import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.calculateEndPadding
import androidx.compose.foundation.layout.calculateStartPadding
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * Height a tab's pages reserve so their last row scrolls clear of the floating mini-player
 * (iOS `miniPlayerClearance`: measured height + 6 + 12). Zero with no track and in sheets.
 */
val LocalMiniPlayerClearance = compositionLocalOf { 0.dp }

/**
 * Height of the floating tab bar plus the navigation-bar inset. Pages draw edge to edge
 * behind the glass bar, so they reserve this too. Zero in sheets.
 */
val LocalTabBarClearance = compositionLocalOf { 0.dp }

/** Both clearances; every scrolling tab page, including pushed pages, must reserve this. */
val bottomClearance: Dp
    @Composable get() = LocalTabBarClearance.current + LocalMiniPlayerClearance.current

/** [base] plus [bottomClearance] at the bottom, for `LazyColumn(contentPadding = ...)`. */
@Composable
fun tabContentPadding(base: PaddingValues = PaddingValues()): PaddingValues {
    val direction = LocalLayoutDirection.current
    return PaddingValues(
        start = base.calculateStartPadding(direction),
        top = base.calculateTopPadding(),
        end = base.calculateEndPadding(direction),
        bottom = base.calculateBottomPadding() + bottomClearance,
    )
}

/** A trailing spacer for non-lazy scrolling columns. */
@Composable
fun BottomClearanceSpacer(extra: Dp = 0.dp) {
    Spacer(Modifier.height(bottomClearance + extra))
}
