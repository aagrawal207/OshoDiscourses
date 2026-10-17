package com.agraabhi.oshodiscourses.feature.transcript

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Cancel
import androidx.compose.material.icons.rounded.CheckCircleOutline
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.Explore
import androidx.compose.material.icons.rounded.FormatAlignJustify
import androidx.compose.material.icons.rounded.FormatSize
import androidx.compose.material.icons.rounded.Forward30
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.KeyboardArrowUp
import androidx.compose.material.icons.rounded.MyLocation
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Share
import androidx.compose.material.icons.rounded.TextDecrease
import androidx.compose.material.icons.rounded.TextFields
import androidx.compose.material.icons.rounded.TextIncrease
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import com.agraabhi.oshodiscourses.core.ui.components.BarIconButton
import com.agraabhi.oshodiscourses.core.ui.components.CappedFontScale
import com.agraabhi.oshodiscourses.core.ui.components.GlassCapsule
import com.agraabhi.oshodiscourses.core.ui.components.OshoMenu
import com.agraabhi.oshodiscourses.core.ui.components.OshoMenuDivider
import com.agraabhi.oshodiscourses.core.ui.components.OshoMenuHeader
import com.agraabhi.oshodiscourses.core.ui.components.OshoMenuItem
import com.agraabhi.oshodiscourses.core.ui.components.OshoMenuNote
import com.agraabhi.oshodiscourses.core.ui.components.ReplayFifteenIcon
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import com.agraabhi.oshodiscourses.core.ui.theme.monospacedDigits

/**
 * Inline toolbar: Close on the left, the two-line title centred when it fits, and search plus
 * options grouped in a glass capsule on the right.
 */
@Composable
internal fun TranscriptToolbar(
    state: TranscriptUiState,
    vm: TranscriptViewModel,
    pageURL: String?,
    onDismiss: () -> Unit,
    onOpenURL: (String) -> Unit,
) {
    CappedFontScale {
        CenteredTitleBar(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
            leading = { GlassCircleButton(Icons.Rounded.Close, "Close", onDismiss) },
            title = {
                Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.semantics(mergeDescendants = true) { heading() }) {
                    Text(
                        state.seriesName ?: "Transcript",
                        style = Osho.typography.headline,
                        color = Osho.colors.label,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    state.discourseNumber?.let {
                        Text("Discourse $it", style = Osho.typography.caption, color = Osho.colors.secondaryLabel, maxLines = 1)
                    }
                }
            },
            trailing = {
                GlassCapsule {
                    BarIconButton(Icons.Rounded.Search, "Search transcript", vm::toggleSearch, enabled = state.isLoaded)
                    var menuOpen by remember { mutableStateOf(false) }
                    Box {
                        BarIconButton(Icons.Rounded.FormatSize, "Transcript options", { menuOpen = true })
                        OptionsMenu(state, vm, pageURL, expanded = menuOpen, onDismiss = { menuOpen = false }, onOpenURL = onOpenURL)
                    }
                }
            },
        )
    }
}

/** Places [title] at the bar's centre when it clears both sides, else centred in the gap between them. */
@Composable
private fun CenteredTitleBar(
    modifier: Modifier,
    leading: @Composable () -> Unit,
    title: @Composable () -> Unit,
    trailing: @Composable () -> Unit,
) {
    Layout(contents = listOf(leading, title, trailing), modifier = modifier) { (lead, mid, trail), constraints ->
        val gap = 8.dp.roundToPx()
        val loose = constraints.copy(minWidth = 0, minHeight = 0)
        val l = lead.first().measure(loose)
        val t = trail.first().measure(loose)
        val width = constraints.maxWidth
        val available = (width - l.width - t.width - 2 * gap).coerceAtLeast(0)
        val m = mid.first().measure(Constraints(maxWidth = available))
        val height = maxOf(l.height, t.height, m.height)
        layout(width, height) {
            l.placeRelative(0, (height - l.height) / 2)
            t.placeRelative(width - t.width, (height - t.height) / 2)
            val centred = (width - m.width) / 2
            val minX = l.width + gap
            val maxX = width - t.width - gap - m.width
            val x = if (centred in minX..maxX) centred else minX + (available - m.width) / 2
            m.placeRelative(x, (height - m.height) / 2)
        }
    }
}

@Composable
private fun OptionsMenu(
    state: TranscriptUiState,
    vm: TranscriptViewModel,
    pageURL: String?,
    expanded: Boolean,
    onDismiss: () -> Unit,
    onOpenURL: (String) -> Unit,
) {
    OshoMenu(expanded = expanded, onDismiss = onDismiss) {
        fun act(block: () -> Unit) {
            onDismiss()
            block()
        }
        OshoMenuHeader("Text size")
        OshoMenuItem("Smaller", Icons.Rounded.TextDecrease, { vm.stepFontSize(-1) }, enabled = state.canShrinkText)
        OshoMenuItem("Larger", Icons.Rounded.TextIncrease, { vm.stepFontSize(1) }, enabled = state.canGrowText)
        OshoMenuDivider()
        OshoMenuItem(
            "Select Passages",
            Icons.Rounded.CheckCircleOutline,
            { act { vm.startSelecting(null) } },
            enabled = state.isLoaded && !state.isSelecting,
        )
        OshoMenuDivider()
        OshoMenuHeader("Layout")
        OshoMenuItem(
            "One sentence per line",
            Icons.Rounded.FormatAlignJustify,
            { vm.setSentenceLayout(!state.sentenceLayout) },
            checked = state.sentenceLayout,
        )
        state.timingNote?.let { note ->
            OshoMenuDivider()
            OshoMenuHeader("Timing")
            OshoMenuNote(note)
            state.clearAnchorsLabel?.let { label ->
                OshoMenuItem(label, Icons.Rounded.MyLocation, { act { vm.clearAnchors() } }, destructive = true)
            }
        }
        if (pageURL != null) {
            OshoMenuDivider()
            OshoMenuItem("Open on oshoworld.com", Icons.Rounded.Explore, { act { onOpenURL(pageURL) } })
        }
    }
}

@Composable
internal fun TranscriptSearchBar(state: TranscriptUiState, vm: TranscriptViewModel) {
    val colors = Osho.colors
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }
    CappedFontScale {
        Row(
            Modifier.fillMaxWidth().background(colors.barMaterial).padding(horizontal = 16.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Row(
                Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(10.dp))
                    .background(colors.secondarySystemBackground)
                    .padding(horizontal = 10.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Rounded.Search, null, tint = colors.secondaryLabel, modifier = Modifier.size(18.dp))
                Box(Modifier.weight(1f)) {
                    if (state.searchQuery.isEmpty()) {
                        Text("Find in transcript", style = Osho.typography.body, color = colors.placeholderText, maxLines = 1)
                    }
                    BasicTextField(
                        value = state.searchQuery,
                        onValueChange = vm::setSearchQuery,
                        singleLine = true,
                        textStyle = Osho.typography.body.copy(color = colors.label),
                        cursorBrush = SolidColor(colors.accent),
                        keyboardOptions = KeyboardOptions(
                            capitalization = KeyboardCapitalization.None,
                            autoCorrectEnabled = false,
                            imeAction = ImeAction.Search,
                        ),
                        keyboardActions = KeyboardActions(onSearch = { vm.jumpToMatch(1) }),
                        modifier = Modifier.fillMaxWidth().focusRequester(focus).semantics { contentDescription = "Find in transcript" },
                    )
                }
                if (state.searchQuery.isNotEmpty()) {
                    Icon(
                        Icons.Rounded.Cancel,
                        contentDescription = "Clear search",
                        tint = colors.secondaryLabel,
                        modifier = Modifier.size(18.dp).clip(CircleShape).clickable(role = Role.Button) { vm.setSearchQuery("") },
                    )
                }
            }
            state.searchCounter?.let {
                Text(it, style = Osho.typography.footnote.monospacedDigits(), color = colors.secondaryLabel, maxLines = 1)
            }
            if (state.searchMatches.isNotEmpty()) {
                BarIconButton(Icons.Rounded.KeyboardArrowUp, "Previous match", { vm.jumpToMatch(-1) }, tint = colors.accent, iconSize = 24.dp, modifier = Modifier.size(32.dp, 44.dp))
                BarIconButton(Icons.Rounded.KeyboardArrowDown, "Next match", { vm.jumpToMatch(1) }, tint = colors.accent, iconSize = 24.dp, modifier = Modifier.size(32.dp, 44.dp))
            }
            Text(
                "Cancel",
                style = Osho.typography.body,
                color = colors.accent,
                maxLines = 1,
                modifier = Modifier.clickable(role = Role.Button, onClick = vm::cancelSearch).padding(vertical = 10.dp),
            )
        }
    }
}

/** Thin progress, elapsed time, back 15 / play / forward 30, remaining time. */
@Composable
internal fun TranscriptTransportBar(state: TranscriptUiState, vm: TranscriptViewModel) {
    val colors = Osho.colors
    val duration = maxOf(state.duration, 1.0)
    val progress = (state.currentTime.coerceIn(0.0, duration) / duration).toFloat()
    CappedFontScale {
        Column(
            Modifier
                .fillMaxWidth()
                .background(colors.barMaterial)
                .navigationBarsPadding()
                .padding(start = 20.dp, end = 20.dp, top = 8.dp, bottom = 6.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Box(Modifier.fillMaxWidth().height(2.4.dp).clip(CircleShape).background(colors.systemFill)) {
                Box(Modifier.fillMaxWidth(progress).height(2.4.dp).clip(CircleShape).background(colors.accent))
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    formatTime(state.currentTime),
                    style = Osho.typography.caption.monospacedDigits(),
                    color = colors.secondaryLabel,
                    modifier = Modifier.widthIn(min = 64.dp),
                    maxLines = 1,
                )
                Spacer(Modifier.weight(1f))
                Row(horizontalArrangement = Arrangement.spacedBy(28.dp), verticalAlignment = Alignment.CenterVertically) {
                    BarIconButton(Icons.Rounded.Search, "Back 15 seconds", vm::skipBackward) {
                        ReplayFifteenIcon(colors.label, size = 26.dp)
                    }
                    BarIconButton(
                        if (state.isPlaying) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                        if (state.isPlaying) "Pause" else "Play",
                        vm::togglePlayPause,
                        iconSize = 34.dp,
                    )
                    BarIconButton(Icons.Rounded.Forward30, "Forward 30 seconds", vm::skipForward, iconSize = 26.dp)
                }
                Spacer(Modifier.weight(1f))
                Text(
                    "-" + formatTime(maxOf(0.0, state.duration - state.currentTime)),
                    style = Osho.typography.caption.monospacedDigits(),
                    color = colors.secondaryLabel,
                    modifier = Modifier.widthIn(min = 64.dp),
                    textAlign = androidx.compose.ui.text.style.TextAlign.End,
                    maxLines = 1,
                )
            }
        }
    }
}

/** Replaces the transport while picking passages. */
@Composable
internal fun TranscriptSelectionBar(state: TranscriptUiState, vm: TranscriptViewModel) {
    val colors = Osho.colors
    val enabled = state.selection.isNotEmpty()
    CappedFontScale {
        Column(Modifier.fillMaxWidth().background(colors.barMaterial).navigationBarsPadding()) {
            HorizontalDivider(thickness = 0.5.dp, color = colors.separator)
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "Done",
                    style = Osho.typography.body,
                    fontWeight = FontWeight.SemiBold,
                    color = colors.accent,
                    modifier = Modifier.clickable(role = Role.Button, onClick = vm::stopSelecting).padding(vertical = 11.dp),
                )
                Text(
                    state.selectionCountLabel,
                    style = Osho.typography.subheadline.monospacedDigits(),
                    color = colors.secondaryLabel,
                    maxLines = 1,
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                    modifier = Modifier.weight(1f),
                )
                BarIconButton(Icons.Rounded.TextFields, "Select Text", vm::openTextSelectionForSelection, enabled = enabled, tint = colors.accent)
                BarIconButton(Icons.Rounded.ContentCopy, "Copy", vm::copySelection, enabled = enabled, tint = colors.accent)
                BarIconButton(Icons.Rounded.Share, "Share", vm::shareSelection, enabled = enabled, tint = colors.accent)
            }
        }
    }
}
