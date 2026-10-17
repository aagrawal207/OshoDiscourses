package com.agraabhi.oshodiscourses.feature.player

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Psychology
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.Sell
import androidx.compose.material.icons.outlined.SentimentSatisfied
import androidx.compose.material.icons.rounded.MusicNote
import androidx.compose.material.icons.rounded.Replay
import androidx.compose.material.icons.rounded.SelfImprovement
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.agraabhi.oshodiscourses.core.domain.bookmarks.BookmarkCategory
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import com.agraabhi.oshodiscourses.core.ui.theme.monospacedDigits
import com.agraabhi.oshodiscourses.feature.player.components.GlassTextButton
import com.agraabhi.oshodiscourses.feature.player.components.GroupedDivider
import com.agraabhi.oshodiscourses.feature.player.components.GroupedSection
import com.agraabhi.oshodiscourses.feature.player.components.InlineTopBar
import com.agraabhi.oshodiscourses.feature.player.components.SectionGap

/** SF Symbol per category (iOS `BookmarkCategory.icon`, ui-style.md §4). */
internal val BookmarkCategory.icon: ImageVector
    get() = when (this) {
        BookmarkCategory.RELISTEN -> Icons.Rounded.Replay
        BookmarkCategory.FUNNY -> Icons.Outlined.SentimentSatisfied
        BookmarkCategory.AWESOME -> Icons.Rounded.Star
        BookmarkCategory.PROFOUND -> Icons.Outlined.Psychology
        BookmarkCategory.MEDITATION -> Icons.Rounded.SelfImprovement
        BookmarkCategory.CUSTOM -> Icons.Outlined.Sell
    }

/**
 * iOS `AddBookmarkSheet`. iOS has no edit UI, and the contract has no update, so this only adds.
 * The time was captured in [draft] when the listener asked, not when they save.
 */
@Composable
internal fun AddBookmarkContent(
    draft: BookmarkDraft,
    onCancel: () -> Unit,
    onSave: (note: String, category: BookmarkCategory, customCategory: String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = Osho.colors
    var note by rememberSaveable { mutableStateOf("") }
    var category by rememberSaveable { mutableStateOf(BookmarkCategory.RELISTEN) }
    var custom by rememberSaveable { mutableStateOf("") }

    Column(modifier.fillMaxSize()) {
        InlineTopBar(
            "Add Bookmark",
            leading = { GlassTextButton("Cancel", onClick = onCancel) },
            trailing = { GlassTextButton("Save", onClick = { onSave(note, category, custom) }, prominent = true) },
        )
        Column(
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(top = 8.dp, bottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding() + 24.dp),
        ) {
            GroupedSection {
                FormRow {
                    Icon(Icons.Outlined.Schedule, contentDescription = null, tint = colors.systemBlue, modifier = Modifier.size(20.dp))
                    Text("Timestamp", style = Osho.typography.body, color = colors.label, modifier = Modifier.weight(1f))
                    Text(
                        PlayerFormatting.time(draft.timestamp),
                        style = Osho.typography.body.monospacedDigits(),
                        color = colors.secondaryLabel,
                    )
                }
                GroupedDivider(startInset = 52.dp)
                FormRow {
                    Icon(Icons.Rounded.MusicNote, contentDescription = null, tint = colors.systemBlue, modifier = Modifier.size(20.dp))
                    Text(draft.title, style = Osho.typography.body, color = colors.label, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            SectionGap()
            GroupedSection(header = "Category") {
                CategoryGrid(category, onSelect = { category = it }, modifier = Modifier.padding(horizontal = 16.dp, vertical = 15.dp))
                if (category == BookmarkCategory.CUSTOM) {
                    GroupedDivider()
                    FormTextField(custom, { custom = it }, placeholder = "Custom category name", singleLine = true)
                }
            }
            SectionGap()
            GroupedSection(header = "Note (optional)") {
                FormTextField(note, { note = it }, placeholder = "What caught your attention?", singleLine = false)
            }
        }
    }
}

@Composable
private fun FormRow(content: @Composable androidx.compose.foundation.layout.RowScope.() -> Unit) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 52.dp).padding(horizontal = 16.dp, vertical = 11.dp),
        horizontalArrangement = Arrangement.spacedBy(16.dp),
        verticalAlignment = Alignment.CenterVertically,
        content = content,
    )
}

/** SwiftUI `LazyVGrid(.adaptive(minimum: 100), spacing: 10)`: as many columns of 100+ as fit. */
@Composable
private fun CategoryGrid(selected: BookmarkCategory, onSelect: (BookmarkCategory) -> Unit, modifier: Modifier = Modifier) {
    BoxWithConstraints(modifier.fillMaxWidth()) {
        val columns = ((maxWidth + 10.dp) / 110.dp).toInt().coerceAtLeast(1)
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            BookmarkCategory.entries.chunked(columns).forEach { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    row.forEach { CategoryButton(it, it == selected, { onSelect(it) }, Modifier.weight(1f)) }
                    repeat(columns - row.size) { Spacer(Modifier.weight(1f)) }
                }
            }
        }
    }
}

@Composable
private fun CategoryButton(category: BookmarkCategory, selected: Boolean, onClick: () -> Unit, modifier: Modifier) {
    val colors = Osho.colors
    val content = if (selected) colors.systemBlue else colors.label
    Row(
        modifier = modifier
            .clip(RoundedCornerShape(8.dp))
            .background(if (selected) colors.systemBlue.copy(alpha = 0.2f) else colors.tertiarySystemFill)
            .clickable(role = Role.RadioButton, onClick = onClick)
            .semantics { this.selected = selected }
            .padding(horizontal = 4.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(category.icon, contentDescription = null, tint = content, modifier = Modifier.size(14.dp))
        Text(category.rawValue, style = Osho.typography.subheadline, color = content, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun FormTextField(value: String, onValueChange: (String) -> Unit, placeholder: String, singleLine: Boolean) {
    val colors = Osho.colors
    val style = Osho.typography.body.copy(color = colors.label)
    BasicTextField(
        value = value,
        onValueChange = onValueChange,
        singleLine = singleLine,
        minLines = if (singleLine) 1 else 3,
        maxLines = if (singleLine) 1 else 6,
        textStyle = style,
        cursorBrush = SolidColor(colors.accent),
        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 15.dp)
            .semantics { contentDescription = placeholder },
        decorationBox = { inner ->
            Box {
                if (value.isEmpty()) Text(placeholder, style = style.copy(color = colors.placeholderText))
                inner()
            }
        },
    )
}
