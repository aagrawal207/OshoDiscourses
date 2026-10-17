package com.agraabhi.oshodiscourses.core.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.agraabhi.oshodiscourses.core.ui.bottomClearance
import com.agraabhi.oshodiscourses.core.ui.theme.Osho

/** iOS 26 inset-grouped metrics (ui-style.md §3.3). */
object Grouped {
    val sideInset = 16.dp
    val cornerRadius = 22.dp
    val rowPadding = 16.dp
    val rowMinHeight = 52.dp
    val barHeight = 44.dp
}

/** iOS large title: its line sits this far below the bar, putting the baseline 89 below the safe area. */
private val LargeTitleTop = 14.dp

/** Extra room above the first section of an inline-title page, as iOS 26 grouped lists leave. */
private val InlinePageTop = 11.dp

/** The soft edge iOS 26 draws under a bar instead of a hairline. */
private val BarFade = 10.dp

/** The bar over scrolled content: so heavily blurred on iOS that it reads as the page colour, lifted. */
@Composable
fun navBarColor(background: Color): Color =
    if (Osho.colors.isDark) lerp(background, Color.White, 0.04f) else lerp(background, Color.White, 0.6f)

/**
 * A navigation page: a lazy list under an iOS-style bar. A large title scrolls with the content
 * and the bar shows the inline title once it has scrolled away. Sheets below the status bar pass
 * a zero [topInset]. A [search] field hides under the title until the list is pulled down.
 */
@Composable
fun GroupedPage(
    title: String,
    largeTitle: Boolean,
    background: Color,
    modifier: Modifier = Modifier,
    listState: LazyListState = rememberLazyListState(),
    navigation: (@Composable () -> Unit)? = null,
    actions: @Composable RowScope.() -> Unit = {},
    extraBottomPadding: Dp = 0.dp,
    topInset: Dp = WindowInsets.statusBars.asPaddingValues().calculateTopPadding(),
    search: PageSearch? = null,
    listModifier: Modifier = Modifier,
    overlay: @Composable BoxScope.() -> Unit = {},
    content: LazyListScope.() -> Unit,
) {
    val statusTop = topInset
    val density = LocalDensity.current
    val reveal = rememberSearchRevealState(listState)
    val searching = search != null && reveal.isActive
    // The inline title takes over once the large title's baseline passes under the bar.
    val collapseThreshold = with(density) { 40.dp.roundToPx() }
    val showInlineTitle by remember(largeTitle) {
        derivedStateOf {
            !largeTitle || listState.firstVisibleItemIndex > 0 || listState.firstVisibleItemScrollOffset > collapseThreshold
        }
    }
    val scrolled by remember { derivedStateOf { listState.firstVisibleItemIndex > 0 || listState.firstVisibleItemScrollOffset > 0 } }
    Box(modifier.fillMaxSize().background(background)) {
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize().then(if (search != null) Modifier.nestedScroll(reveal.connection) else Modifier).then(listModifier),
            contentPadding = PaddingValues(
                top = statusTop + Grouped.barHeight + if (largeTitle && !searching) 0.dp else InlinePageTop,
                bottom = bottomClearance + extraBottomPadding + 24.dp,
            ),
        ) {
            if (largeTitle && !searching) {
                item(key = "page.largeTitle", contentType = "largeTitle") {
                    CappedFontScale {
                        Text(
                            title,
                            style = Osho.typography.largeTitle,
                            fontWeight = FontWeight.Bold,
                            color = Osho.colors.label,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier
                                .padding(horizontal = Grouped.sideInset)
                                .padding(top = LargeTitleTop, bottom = 6.dp)
                                .semantics { heading() },
                        )
                    }
                }
            }
            if (search != null && !searching) searchRevealItem(reveal, search)
            content()
        }
        if (search != null && searching) {
            Column(Modifier.fillMaxWidth().background(background).padding(top = statusTop)) {
                ActiveSearchBar(reveal, search)
            }
        } else {
            PageBar(
                title = title,
                showTitle = showInlineTitle,
                scrolled = scrolled,
                background = background,
                statusTop = statusTop,
                navigation = navigation,
                actions = actions,
            )
        }
        overlay()
    }
}

@Composable
private fun PageBar(
    title: String,
    showTitle: Boolean,
    scrolled: Boolean,
    background: Color,
    statusTop: Dp,
    navigation: (@Composable () -> Unit)?,
    actions: @Composable RowScope.() -> Unit,
) {
    val bar = navBarColor(background)
    val total = statusTop + Grouped.barHeight + BarFade
    val solidUntil = (statusTop + Grouped.barHeight) / total
    // iOS 26 lifts the bar out of the page only once the title collapses; before that, only
    // the status bar keeps a soft edge so scrolled rows never collide with the clock.
    val fade = when {
        showTitle && scrolled -> Brush.verticalGradient(0f to bar, solidUntil to bar, 1f to bar.copy(alpha = 0f))
        scrolled -> Brush.verticalGradient(0f to background, (statusTop / total) to background.copy(alpha = 0.85f), ((statusTop + BarFade) / total) to background.copy(alpha = 0f))
        else -> Brush.verticalGradient(listOf(Color.Transparent, Color.Transparent))
    }
    Box(
        Modifier
            .fillMaxWidth()
            .height(total)
            .background(fade),
    ) {
        CappedFontScale {
            BoxWithConstraints(
                Modifier
                    .fillMaxWidth()
                    .padding(top = statusTop)
                    .height(Grouped.barHeight)
                    .padding(horizontal = Grouped.sideInset),
            ) {
                val titleWidth = maxWidth * 0.5f
                Row(Modifier.fillMaxSize(), verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) { navigation?.invoke() }
                    Box(Modifier.widthIn(max = titleWidth), contentAlignment = Alignment.Center) {
                        if (showTitle) {
                            Text(
                                title,
                                style = Osho.typography.navInline,
                                color = Osho.colors.label,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                textAlign = TextAlign.Center,
                            )
                        }
                    }
                    Row(
                        Modifier.weight(1f),
                        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End),
                        verticalAlignment = Alignment.CenterVertically,
                        content = actions,
                    )
                }
            }
        }
    }
}

/** [afterFooter]: iOS tucks a header closer under the previous section's footer than under its card. */
fun LazyListScope.sectionHeader(key: Any, text: String, first: Boolean = false, afterFooter: Boolean = false) {
    item(key = key, contentType = "sectionHeader") { SectionHeaderText(text, first, afterFooter) }
}

fun LazyListScope.sectionFooter(key: Any, text: String) {
    item(key = key, contentType = "sectionFooter") { ListSectionFooter(text) }
}

fun LazyListScope.sectionGap(key: Any, height: Dp = 24.dp) {
    item(key = key, contentType = "gap") { Spacer(Modifier.height(height)) }
}

@Composable
fun SectionHeaderText(text: String, first: Boolean = false, afterFooter: Boolean = false) {
    Text(
        text,
        style = Osho.typography.listHeader,
        color = Osho.colors.secondaryLabel,
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = Grouped.sideInset + Grouped.rowPadding, end = Grouped.sideInset + Grouped.rowPadding)
            .padding(top = if (first) 12.dp else if (afterFooter) 18.dp else 29.dp, bottom = 10.dp)
            .semantics { heading() },
    )
}

/** A section footer in a lazy grouped list, inset to the row text. */
@Composable
fun ListSectionFooter(text: String, modifier: Modifier = Modifier) {
    Text(
        text,
        style = Osho.typography.listFooter,
        color = Osho.colors.secondaryLabel,
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = Grouped.sideInset + Grouped.rowPadding)
            .padding(top = 8.dp),
    )
}

/** Card corners for one row of a section: only the ends are rounded. */
fun rowShape(isFirst: Boolean, isLast: Boolean): Shape {
    val r = Grouped.cornerRadius
    return RoundedCornerShape(
        topStart = if (isFirst) r else 0.dp,
        topEnd = if (isFirst) r else 0.dp,
        bottomStart = if (isLast) r else 0.dp,
        bottomEnd = if (isLast) r else 0.dp,
    )
}

/**
 * The card around one row. Dividers are inset on both sides as on iOS 26; [dividerStart] is
 * measured from the card's leading edge to the row's text.
 */
@Composable
fun CardRow(
    isFirst: Boolean,
    isLast: Boolean,
    modifier: Modifier = Modifier,
    dividerStart: Dp = Grouped.rowPadding,
    background: Color = Osho.colors.secondarySystemGroupedBackground,
    onSwipeDelete: (() -> Unit)? = null,
    content: @Composable () -> Unit,
) {
    val separator = Osho.colors.separator
    val shape = rowShape(isFirst, isLast)
    Box(modifier.fillMaxWidth().padding(horizontal = Grouped.sideInset)) {
        SwipeToDelete(enabled = onSwipeDelete != null, shape = shape, onDelete = { onSwipeDelete?.invoke() }) {
            Box(
                Modifier
                    .fillMaxWidth()
                    .background(background, shape)
                    .then(
                        if (isLast) {
                            Modifier
                        } else {
                            Modifier.drawBehind {
                                val start = dividerStart.toPx()
                                val end = size.width - Grouped.rowPadding.toPx()
                                val y = size.height - 0.5f
                                drawLine(separator, Offset(start, y), Offset(end, y), strokeWidth = 1f)
                            }
                        },
                    ),
            ) {
                content()
            }
        }
    }
}

/** Standard row padding inside a [CardRow]. */
fun Modifier.rowContentPadding(vertical: Dp = 12.dp): Modifier =
    heightIn(min = Grouped.rowMinHeight).padding(horizontal = Grouped.rowPadding, vertical = vertical)

/** SwiftUI `ContentUnavailableView` (ui-style.md §8). */
@Composable
fun EmptyState(icon: ImageVector, title: String, description: String, modifier: Modifier = Modifier) {
    Column(
        modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(icon, contentDescription = null, tint = Osho.colors.secondaryLabel, modifier = Modifier.size(48.dp))
        Text(
            title,
            style = Osho.typography.title2,
            fontWeight = FontWeight.Bold,
            color = Osho.colors.label,
            textAlign = TextAlign.Center,
            modifier = Modifier.widthIn(max = 320.dp),
        )
        Text(
            description,
            style = Osho.typography.subheadline,
            color = Osho.colors.secondaryLabel,
            textAlign = TextAlign.Center,
            modifier = Modifier.widthIn(max = 320.dp),
        )
    }
}

/** `ProgressView()` at small control size: a gray spinner. */
@Composable
fun SmallSpinner(modifier: Modifier = Modifier, size: Dp = 20.dp) {
    CircularProgressIndicator(
        modifier = modifier.size(size),
        color = Osho.colors.secondaryLabel,
        strokeWidth = 2.dp,
    )
}

/**
 * An inset-grouped Form section outside a lazy list (ui-style.md §3.3, §8): 17/600 secondary
 * header, r 22 card inset 16, 13 sp secondary footer. Headers are never uppercased.
 */
@Composable
fun GroupedSection(
    modifier: Modifier = Modifier,
    header: String? = null,
    footer: (@Composable ColumnScope.() -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    val colors = Osho.colors
    Column(modifier.fillMaxWidth().padding(horizontal = Grouped.sideInset)) {
        if (header != null) {
            Text(
                header,
                style = Osho.typography.listHeader,
                color = colors.secondaryLabel,
                modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 6.dp).semantics { heading() },
            )
        }
        Column(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(Grouped.cornerRadius))
                .background(colors.secondarySystemGroupedBackground),
            content = content,
        )
        if (footer != null) {
            Column(
                Modifier.padding(start = 16.dp, end = 16.dp, top = 7.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
                content = footer,
            )
        }
    }
}

/** Footer text for the [GroupedSection] footer slot, which supplies the inset. */
@Composable
fun SectionFooterText(text: String, color: Color = Osho.colors.secondaryLabel) {
    Text(text, style = Osho.typography.listFooter, color = color)
}

/** Row separator inset to the text start, as UIKit draws it. */
@Composable
fun GroupedDivider(startInset: Dp = 16.dp) {
    HorizontalDivider(Modifier.padding(start = startInset), thickness = Dp.Hairline, color = Osho.colors.separator)
}

/** The bold, small disclosure chevron at the end of a navigation row. */
@Composable
fun DisclosureChevron() {
    Icon(
        Icons.Rounded.ChevronRight,
        contentDescription = null,
        tint = Osho.colors.tertiaryLabel,
        modifier = Modifier.size(22.dp),
    )
}

/** Gap between grouped sections. */
val SectionSpacing = 24.dp

@Composable
fun SectionGap() {
    Box(Modifier.height(SectionSpacing))
}
