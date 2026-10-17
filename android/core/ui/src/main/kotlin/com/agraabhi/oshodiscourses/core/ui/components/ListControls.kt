package com.agraabhi.oshodiscourses.core.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Cancel
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxState
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import com.agraabhi.oshodiscourses.core.ui.theme.Osho

/** `.searchable` field under the large title. */
@Composable
fun SearchField(
    query: String,
    onQueryChange: (String) -> Unit,
    placeholder: String,
    modifier: Modifier = Modifier,
) {
    val colors = Osho.colors
    BasicTextField(
        value = query,
        onValueChange = onQueryChange,
        singleLine = true,
        textStyle = Osho.typography.body.copy(color = colors.label),
        cursorBrush = SolidColor(colors.accent),
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = Grouped.sideInset)
            .semantics { contentDescription = placeholder },
        decorationBox = { inner ->
            Row(
                Modifier
                    .fillMaxWidth()
                    .heightIn(min = 44.dp)
                    .background(colors.tertiarySystemFill, CircleShape)
                    .padding(horizontal = 12.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(Icons.Rounded.Search, contentDescription = null, tint = colors.secondaryLabel, modifier = Modifier.size(20.dp))
                Box(Modifier.weight(1f)) {
                    if (query.isEmpty()) {
                        Text(placeholder, style = Osho.typography.body, color = colors.placeholderText, maxLines = 1)
                    }
                    inner()
                }
                if (query.isNotEmpty()) {
                    Icon(
                        Icons.Rounded.Cancel,
                        contentDescription = "Clear search",
                        tint = colors.tertiaryLabel,
                        modifier = Modifier
                            .size(20.dp)
                            .clip(CircleShape)
                            .clickable(role = Role.Button) { onQueryChange("") },
                    )
                }
            }
        },
    )
}

/**
 * List `.onDelete`: a full swipe left past half the row deletes it, over a red "Delete" well.
 * [shape] clips the well to the row's card corners.
 */
@Composable
fun SwipeToDelete(
    enabled: Boolean,
    shape: Shape,
    onDelete: () -> Unit,
    content: @Composable () -> Unit,
) {
    if (!enabled) {
        content()
        return
    }
    val density = LocalDensity.current
    // Not saveable: a lazy row back under the same key (a re-download) would restore "dismissed"
    // and Material would call onDismiss again, deleting the new file.
    val state = remember { SwipeToDismissBoxState(SwipeToDismissBoxValue.Settled, density, positionalThreshold = { it * 0.5f }) }
    SwipeToDismissBox(
        state = state,
        enableDismissFromStartToEnd = false,
        onDismiss = { value -> if (value == SwipeToDismissBoxValue.EndToStart) onDelete() },
        modifier = Modifier.clip(shape),
        backgroundContent = {
            // Painted only mid-swipe; a resting red well bleeds through the anti-aliased corners.
            val swiping = state.dismissDirection == SwipeToDismissBoxValue.EndToStart
            Box(
                Modifier.fillMaxSize().background(if (swiping) Osho.colors.systemRed else Color.Transparent).padding(horizontal = 20.dp),
                contentAlignment = Alignment.CenterEnd,
            ) {
                if (swiping) Text("Delete", style = Osho.typography.body, color = Color.White)
            }
        },
    ) {
        content()
    }
}
