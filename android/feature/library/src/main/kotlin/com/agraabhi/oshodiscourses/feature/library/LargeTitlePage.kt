package com.agraabhi.oshodiscourses.feature.library

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import com.agraabhi.oshodiscourses.core.ui.tabContentPadding
import com.agraabhi.oshodiscourses.core.ui.theme.Osho

internal const val LARGE_TITLE_LIST_TAG = "largeTitleList"

/** iOS large-title page: the title scrolls away and a centred inline title fades in (ui-style.md §3.3). */
@Composable
internal fun LargeTitlePage(
    title: String,
    background: Color,
    modifier: Modifier = Modifier,
    listState: LazyListState = rememberLazyListState(),
    bottomPadding: androidx.compose.ui.unit.Dp = 16.dp,
    content: LazyListScope.() -> Unit,
) {
    val collapsed by remember { derivedStateOf { listState.firstVisibleItemIndex > 0 } }
    Box(modifier.fillMaxSize().background(background)) {
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize().testTag(LARGE_TITLE_LIST_TAG),
            contentPadding = tabContentPadding(PaddingValues(bottom = bottomPadding)),
        ) {
            item(key = "largeTitle", contentType = "largeTitle") { LargeTitle(title) }
            content()
        }
        AnimatedVisibility(visible = collapsed, enter = fadeIn(), exit = fadeOut()) {
            Column(Modifier.fillMaxWidth().background(Osho.colors.barMaterial).statusBarsPadding()) {
                Box(Modifier.fillMaxWidth().height(44.dp), contentAlignment = Alignment.Center) {
                    CappedFontScale {
                        Text(title, style = Osho.typography.navInline, color = Osho.colors.label, maxLines = 1)
                    }
                }
                HorizontalDivider(thickness = 0.5.dp, color = Osho.colors.separator)
            }
        }
    }
}

@Composable
private fun LargeTitle(title: String) {
    Column(Modifier.fillMaxWidth().statusBarsPadding()) {
        Box(Modifier.height(44.dp))
        Box(Modifier.fillMaxWidth().height(52.dp).padding(horizontal = 16.dp), contentAlignment = Alignment.CenterStart) {
            CappedFontScale {
                Text(
                    title,
                    style = Osho.typography.largeTitle,
                    fontWeight = FontWeight.Bold,
                    color = Osho.colors.label,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.semantics { heading() },
                )
            }
        }
    }
}

/** iOS bars and large titles cap Dynamic Type at xxxLarge (about 1.35x) so they keep one line. */
@Composable
internal fun CappedFontScale(max: Float = 1.35f, content: @Composable () -> Unit) {
    val density = LocalDensity.current
    CompositionLocalProvider(LocalDensity provides Density(density.density, density.fontScale.coerceAtMost(max)), content = content)
}
