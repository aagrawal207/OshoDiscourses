package com.agraabhi.oshodiscourses.core.ui.components

import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/** Test tag of the page's list, for scrolling it in UI tests. */
const val LARGE_TITLE_LIST_TAG = "largeTitleList"

/**
 * iOS large-title tab root (ui-style.md §3.3): the title scrolls away under a bar that shows the
 * centred inline title, with an optional pull-to-reveal [search].
 */
@Composable
fun LargeTitlePage(
    title: String,
    background: Color,
    modifier: Modifier = Modifier,
    listState: LazyListState = rememberLazyListState(),
    bottomPadding: Dp = 16.dp,
    search: PageSearch? = null,
    content: LazyListScope.() -> Unit,
) {
    GroupedPage(
        title = title,
        largeTitle = true,
        background = background,
        modifier = modifier,
        listState = listState,
        extraBottomPadding = bottomPadding - 24.dp,
        search = search,
        listModifier = Modifier.testTag(LARGE_TITLE_LIST_TAG),
        content = content,
    )
}

/** iOS bars and large titles cap Dynamic Type at xxxLarge (about 1.35x) so they keep one line. */
@Composable
fun CappedFontScale(max: Float = 1.35f, content: @Composable () -> Unit) {
    val density = LocalDensity.current
    CompositionLocalProvider(LocalDensity provides Density(density.density, density.fontScale.coerceAtMost(max)), content = content)
}
