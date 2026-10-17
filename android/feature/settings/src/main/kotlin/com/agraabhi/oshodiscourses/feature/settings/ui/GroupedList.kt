package com.agraabhi.oshodiscourses.feature.settings.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBackIos
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.agraabhi.oshodiscourses.core.ui.bottomClearance
import com.agraabhi.oshodiscourses.core.ui.components.glass
import com.agraabhi.oshodiscourses.core.ui.theme.Osho

/** iOS 26 inset-grouped metrics (ui-style.md §3.3). */
internal object Grouped {
    val sideInset = 16.dp
    val cornerRadius = 22.dp
    val rowPadding = 16.dp
    val rowMinHeight = 52.dp
    val barHeight = 52.dp
}

/**
 * A navigation page: a lazy list under an iOS-style bar. A large title scrolls with the content
 * and the bar shows the inline title once it has scrolled away.
 */
@Composable
internal fun GroupedPage(
    title: String,
    largeTitle: Boolean,
    background: Color,
    modifier: Modifier = Modifier,
    listState: LazyListState = rememberLazyListState(),
    navigation: (@Composable () -> Unit)? = null,
    actions: @Composable RowScope.() -> Unit = {},
    extraBottomPadding: Dp = 0.dp,
    overlay: @Composable BoxScope.() -> Unit = {},
    content: LazyListScope.() -> Unit,
) {
    val statusTop = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    val density = LocalDensity.current
    val collapseThreshold = with(density) { 36.dp.roundToPx() }
    val showInlineTitle by remember(largeTitle) {
        derivedStateOf {
            !largeTitle || listState.firstVisibleItemIndex > 0 || listState.firstVisibleItemScrollOffset > collapseThreshold
        }
    }
    val scrolled by remember { derivedStateOf { listState.firstVisibleItemIndex > 0 || listState.firstVisibleItemScrollOffset > 0 } }
    Box(modifier.fillMaxSize().background(background)) {
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(top = statusTop + Grouped.barHeight, bottom = bottomClearance + extraBottomPadding + 24.dp),
        ) {
            if (largeTitle) {
                item(key = "page.largeTitle", contentType = "largeTitle") {
                    Text(
                        title,
                        style = Osho.typography.largeTitle,
                        fontWeight = FontWeight.Bold,
                        color = Osho.colors.label,
                        modifier = Modifier
                            .padding(horizontal = Grouped.sideInset)
                            .padding(bottom = 8.dp)
                            .semantics { heading() },
                    )
                }
            }
            content()
        }
        PageBar(
            title = title,
            showTitle = showInlineTitle,
            scrolled = scrolled,
            background = background,
            statusTop = statusTop,
            navigation = navigation,
            actions = actions,
        )
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
    // iOS 26 fades content under the bar instead of drawing an opaque bar.
    val fade = if (scrolled) {
        Brush.verticalGradient(0f to background, 0.75f to background.copy(alpha = 0.9f), 1f to background.copy(alpha = 0f))
    } else {
        Brush.verticalGradient(listOf(Color.Transparent, Color.Transparent))
    }
    Box(
        Modifier
            .fillMaxWidth()
            .height(statusTop + Grouped.barHeight + 8.dp)
            .background(fade),
    ) {
        // iOS bars stop growing past xxxLarge text so the title never collides with the buttons.
        val density = LocalDensity.current
        CompositionLocalProvider(LocalDensity provides Density(density.density, density.fontScale.coerceAtMost(1.35f))) {
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

/** 44 dp Liquid Glass circle used for back and toolbar icons. */
@Composable
internal fun GlassCircleButton(
    icon: ImageVector,
    contentDescription: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    tint: Color = Osho.colors.label,
    iconSize: Dp = 22.dp,
) {
    val colors = Osho.colors
    Box(
        modifier
            .size(44.dp)
            .shadow(8.dp, CircleShape, ambientColor = colors.glassShadow, spotColor = colors.glassShadow)
            // In-page chrome sits inside the shell's haze source, so it uses the tint fallback.
            .glass(CircleShape, hazeState = null)
            .border(0.5.dp, colors.glassBorder, CircleShape)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { this.contentDescription = contentDescription },
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(iconSize))
    }
}

/** Glass capsule for text toolbar buttons such as "Done". */
@Composable
internal fun GlassTextButton(label: String, onClick: () -> Unit, modifier: Modifier = Modifier, bold: Boolean = false) {
    val colors = Osho.colors
    Box(
        modifier
            .heightIn(min = 44.dp)
            .shadow(8.dp, CircleShape, ambientColor = colors.glassShadow, spotColor = colors.glassShadow)
            .glass(CircleShape, hazeState = null)
            .border(0.5.dp, colors.glassBorder, CircleShape)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(label, style = Osho.typography.body, fontWeight = if (bold) FontWeight.SemiBold else null, color = colors.label)
    }
}

@Composable
internal fun BackButton(onBack: () -> Unit) {
    GlassCircleButton(Icons.AutoMirrored.Rounded.ArrowBackIos, "Back", onBack, iconSize = 18.dp, modifier = Modifier)
}

internal fun LazyListScope.sectionHeader(key: Any, text: String, first: Boolean = false) {
    item(key = key, contentType = "sectionHeader") { SectionHeaderText(text, first) }
}

internal fun LazyListScope.sectionFooter(key: Any, text: String) {
    item(key = key, contentType = "sectionFooter") { SectionFooterText(text) }
}

internal fun LazyListScope.sectionGap(key: Any, height: Dp = 24.dp) {
    item(key = key, contentType = "gap") { Spacer(Modifier.height(height)) }
}

@Composable
internal fun SectionHeaderText(text: String, first: Boolean = false) {
    Text(
        text,
        style = Osho.typography.listHeader,
        color = Osho.colors.secondaryLabel,
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = Grouped.sideInset + Grouped.rowPadding, end = Grouped.sideInset + Grouped.rowPadding)
            .padding(top = if (first) 8.dp else 24.dp, bottom = 8.dp)
            .semantics { heading() },
    )
}

@Composable
internal fun SectionFooterText(text: String, modifier: Modifier = Modifier) {
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
internal fun rowShape(isFirst: Boolean, isLast: Boolean): Shape {
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
internal fun CardRow(
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
internal fun Modifier.rowContentPadding(vertical: Dp = 10.dp): Modifier =
    heightIn(min = Grouped.rowMinHeight).padding(horizontal = Grouped.rowPadding, vertical = vertical)

/** SwiftUI `ContentUnavailableView` (ui-style.md §8). */
@Composable
internal fun EmptyState(icon: ImageVector, title: String, description: String, modifier: Modifier = Modifier) {
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
internal fun SmallSpinner(modifier: Modifier = Modifier, size: Dp = 20.dp) {
    CircularProgressIndicator(
        modifier = modifier.size(size),
        color = Osho.colors.secondaryLabel,
        strokeWidth = 2.dp,
    )
}
