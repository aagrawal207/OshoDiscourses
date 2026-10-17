package com.agraabhi.oshodiscourses.core.ui.components

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.animate
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Cancel
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.Velocity
import androidx.compose.ui.unit.dp
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/** A page's `.searchable` field: the query it edits and its prompt. */
@Stable
class PageSearch(val query: String, val onQueryChange: (String) -> Unit, val placeholder: String)

/** Height of the search capsule (iOS 26 measures about 44). */
val SearchFieldHeight = 44.dp

/** The revealed slot under the large title: the capsule plus its margins. */
private val RevealSlotHeight = SearchFieldHeight + 14.dp

/** Test tag of the field-shaped button that starts searching. */
const val SEARCH_REVEAL_TAG = "pageSearchReveal"

/**
 * iOS 26 `.searchable` on a large-title page: hidden until the list is pulled down at the top,
 * folded away again by scrolling up, and pinned to the top bar while active.
 */
@Stable
class SearchRevealState internal constructor(
    private val listState: LazyListState,
    private val scope: CoroutineScope,
    private val maxPx: Float,
    initiallyRevealed: Boolean,
    initiallyActive: Boolean = false,
) {
    var revealPx by mutableFloatStateOf(if (initiallyRevealed) maxPx else 0f)
        private set
    var isActive by mutableStateOf(initiallyActive)
        internal set
    private var settle: Job? = null

    val fraction: Float get() = if (maxPx <= 0f) 0f else revealPx / maxPx

    private val atTop: Boolean get() = listState.firstVisibleItemIndex == 0 && listState.firstVisibleItemScrollOffset == 0

    /** Only a fresh activation raises the keyboard, not a page coming back with search open. */
    internal var focusOnShow = false

    fun activate() {
        isActive = true
        focusOnShow = true
    }

    /** iOS keeps the field showing after Close, so a second search needs no pull. */
    fun close() {
        isActive = false
        settle?.cancel()
        revealPx = maxPx
    }

    private fun animateTo(target: Float) {
        settle?.cancel()
        settle = scope.launch { animate(revealPx, target, animationSpec = tween(200)) { v, _ -> revealPx = v } }
    }

    val connection: NestedScrollConnection = object : NestedScrollConnection {
        override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset {
            if (isActive || source != NestedScrollSource.UserInput || available.y >= 0f || revealPx <= 0f) return Offset.Zero
            settle?.cancel()
            val next = (revealPx + available.y).coerceAtLeast(0f)
            val used = next - revealPx
            revealPx = next
            return Offset(0f, used)
        }

        override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset {
            if (isActive || source != NestedScrollSource.UserInput || available.y <= 0f || !atTop || revealPx >= maxPx) return Offset.Zero
            settle?.cancel()
            val next = (revealPx + available.y).coerceAtMost(maxPx)
            val used = next - revealPx
            revealPx = next
            return Offset(0f, used)
        }

        override suspend fun onPreFling(available: Velocity): Velocity {
            if (isActive || revealPx <= 0f || revealPx >= maxPx) return Velocity.Zero
            animateTo(if (revealPx > maxPx / 2f || available.y > 800f) maxPx else 0f)
            return Velocity.Zero
        }
    }
}

@Composable
fun rememberSearchRevealState(listState: LazyListState, initiallyRevealed: Boolean = false): SearchRevealState {
    val scope = rememberCoroutineScope()
    val maxPx = with(LocalDensity.current) { RevealSlotHeight.toPx() }
    // Saved so a search stays open across a push and pop, as iOS keeps it.
    return rememberSaveable(
        listState,
        maxPx,
        saver = listSaver(
            save = { listOf(it.revealPx > 0f, it.isActive) },
            restore = { SearchRevealState(listState, scope, maxPx, initiallyRevealed = it[0], initiallyActive = it[1]) },
        ),
    ) { SearchRevealState(listState, scope, maxPx, initiallyRevealed) }
}

/** The field-shaped button in the list, revealed by a pull at the top. */
fun LazyListScope.searchRevealItem(state: SearchRevealState, search: PageSearch) {
    item(key = "page.searchReveal", contentType = "searchReveal") {
        val height = with(LocalDensity.current) { state.revealPx.toDp() }
        Box(Modifier.fillMaxWidth().height(height).clipToBounds(), contentAlignment = Alignment.BottomCenter) {
            SearchCapsule(
                placeholder = search.placeholder,
                modifier = Modifier
                    .padding(horizontal = Grouped.sideInset)
                    .padding(top = 6.dp, bottom = 8.dp)
                    .alpha(state.fraction)
                    .clickable(role = Role.Button, onClickLabel = "search", onClick = state::activate)
                    .testTag(SEARCH_REVEAL_TAG)
                    .semantics { contentDescription = search.placeholder },
            ) {
                Text(search.placeholder, style = Osho.typography.body, color = Osho.colors.placeholderText, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

/** The active search row that replaces the bar: focused field plus a glass Close circle. */
@Composable
fun ActiveSearchBar(state: SearchRevealState, search: PageSearch, modifier: Modifier = Modifier) {
    val focus = LocalFocusManager.current
    val requester = remember { FocusRequester() }
    val close = {
        search.onQueryChange("")
        focus.clearFocus()
        state.close()
    }
    BackHandler(onBack = close)
    LaunchedEffect(Unit) {
        if (state.focusOnShow) {
            state.focusOnShow = false
            requester.requestFocus()
        }
    }
    Row(
        modifier.fillMaxWidth().height(Grouped.barHeight).padding(horizontal = Grouped.sideInset),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        SearchField(
            query = search.query,
            onQueryChange = search.onQueryChange,
            placeholder = search.placeholder,
            modifier = Modifier.weight(1f).focusRequester(requester),
            sideInset = 0.dp,
            glass = true,
        )
        GlassIconButton(Icons.Rounded.Close, contentDescription = "Close", onClick = close, iconSize = 24.dp)
    }
}

/** The capsule every search field draws: magnifier, then the text slot. */
@Composable
internal fun SearchCapsule(
    placeholder: String,
    modifier: Modifier = Modifier,
    glass: Boolean = false,
    trailing: @Composable () -> Unit = {},
    text: @Composable () -> Unit,
) {
    val colors = Osho.colors
    Row(
        modifier
            .fillMaxWidth()
            .height(SearchFieldHeight)
            .then(if (glass) Modifier.glassButton(CircleShape) else Modifier.background(colors.tertiarySystemFill, CircleShape))
            .padding(start = 12.dp, end = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(Icons.Rounded.Search, contentDescription = null, tint = if (glass) colors.label else colors.secondaryLabel, modifier = Modifier.size(22.dp))
        Box(Modifier.weight(1f)) { text() }
        trailing()
    }
}

/** `.searchable` text field; [glass] is the active iOS 26 look in the top bar. */
@Composable
fun SearchField(
    query: String,
    onQueryChange: (String) -> Unit,
    placeholder: String,
    modifier: Modifier = Modifier,
    sideInset: Dp = Grouped.sideInset,
    glass: Boolean = false,
) {
    val colors = Osho.colors
    val focus = LocalFocusManager.current
    BasicTextField(
        value = query,
        onValueChange = onQueryChange,
        singleLine = true,
        textStyle = Osho.typography.body.copy(color = colors.label),
        cursorBrush = SolidColor(colors.accent),
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
        keyboardActions = KeyboardActions(onSearch = { focus.clearFocus() }),
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = sideInset)
            .semantics { contentDescription = placeholder },
        decorationBox = { inner ->
            SearchCapsule(
                placeholder = placeholder,
                glass = glass,
                trailing = {
                    if (query.isNotEmpty()) {
                        Box(
                            Modifier
                                .size(32.dp)
                                .clickable(
                                    interactionSource = remember { MutableInteractionSource() },
                                    indication = null,
                                    role = Role.Button,
                                    onClick = { onQueryChange("") },
                                )
                                .semantics { contentDescription = "Clear text" },
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(Icons.Rounded.Cancel, contentDescription = null, tint = if (glass) colors.label else colors.tertiaryLabel, modifier = Modifier.size(22.dp))
                        }
                    }
                },
            ) {
                if (query.isEmpty()) {
                    Text(placeholder, style = Osho.typography.body, color = colors.placeholderText, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                inner()
            }
        },
    )
}
