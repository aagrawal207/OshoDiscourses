package com.agraabhi.oshodiscourses.core.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.dp
import com.agraabhi.oshodiscourses.core.ui.theme.Osho

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
    val state = rememberSwipeToDismissBoxState(positionalThreshold = { it * 0.5f })
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
