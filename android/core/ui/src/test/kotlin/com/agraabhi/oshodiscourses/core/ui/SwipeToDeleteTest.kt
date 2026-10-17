package com.agraabhi.oshodiscourses.core.ui

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertLeftPositionInRootIsEqualTo
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeLeft
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.agraabhi.oshodiscourses.core.model.AccentTheme
import com.agraabhi.oshodiscourses.core.model.Appearance
import com.agraabhi.oshodiscourses.core.ui.components.SwipeToDelete
import com.agraabhi.oshodiscourses.core.ui.theme.OshoTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [36], qualifiers = "w393dp-h852dp-xxhdpi")
class SwipeToDeleteTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun rowThatReturnsUnderTheSameKeyIsNotDeletedAgain() {
        val rows = mutableStateListOf("Discourse 19")
        val deleted = mutableListOf<String>()
        compose.setContent {
            OshoTheme(appearance = Appearance.LIGHT, accent = AccentTheme.PURPLE) {
                LazyColumn {
                    items(rows, key = { "downloaded.$it" }) { row ->
                        SwipeToDelete(enabled = true, shape = RoundedCornerShape(0.dp), onDelete = { deleted += row }) {
                            Text(row, Modifier.fillMaxWidth().height(56.dp))
                        }
                    }
                }
            }
        }

        compose.onNodeWithText("Discourse 19").performTouchInput { swipeLeft() }
        compose.waitForIdle()
        assertEquals(listOf("Discourse 19"), deleted)
        // The engine removes the file later, so the row leaves the list after it settled as dismissed.
        compose.runOnIdle { rows.clear() }
        compose.waitForIdle()

        // A re-download brings the row back with the same lazy key.
        compose.runOnIdle { rows += "Discourse 19" }
        compose.waitForIdle()
        // A restored "dismissed" state would park the row off screen and fire onDismiss again.
        compose.onNodeWithText("Discourse 19").assertLeftPositionInRootIsEqualTo(0.dp)
        assertEquals(listOf("Discourse 19"), deleted)
    }
}
