package com.agraabhi.oshodiscourses.feature.transcript

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Share
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import kotlinx.coroutines.delay

/** Kept verbatim from iOS; Android has no drag-out, so the coordinator may drop the last clause. */
internal const val SELECT_TEXT_HINT = "Touch and hold to select words, then copy, share or drag them into another app."

/** Passages in a selectable text view so the reader can pick exact words with the system handles. */
@Composable
internal fun TranscriptTextSelectionScreen(
    item: TextSelectionItem,
    fontSize: Double,
    onCopyAll: (String) -> Unit,
    onShare: (String) -> Unit,
    onDone: () -> Unit,
) {
    val colors = Osho.colors
    val haptics = LocalHapticFeedback.current
    var copied by remember { mutableStateOf(false) }
    LaunchedEffect(copied) {
        if (copied) {
            haptics.performHapticFeedback(HapticFeedbackType.Confirm)
            delay(2_000)
            copied = false
        }
    }
    Column(Modifier.fillMaxSize().background(colors.systemBackground).statusBarsPadding()) {
        SheetHandle(Modifier.align(Alignment.CenterHorizontally))
        CappedFontScale {
            Box(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp)) {
                Box(Modifier.align(Alignment.CenterStart).toolbarGlass(androidx.compose.foundation.shape.CircleShape)) {
                    Text(
                        if (copied) "Copied" else "Copy All",
                        style = Osho.typography.body,
                        color = colors.label,
                        modifier = Modifier
                            .clickable(role = Role.Button) {
                                onCopyAll(item.text)
                                copied = true
                            }
                            .padding(horizontal = 16.dp, vertical = 11.dp),
                    )
                }
                Text(
                    "Select Text",
                    style = Osho.typography.navInline,
                    color = colors.label,
                    modifier = Modifier.align(Alignment.Center).semantics { heading() },
                )
                Row(Modifier.align(Alignment.CenterEnd), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    GlassCircleButton(Icons.Rounded.Share, "Share", { onShare(item.shareText) })
                    Box(Modifier.toolbarGlass(androidx.compose.foundation.shape.CircleShape)) {
                        Text(
                            "Done",
                            style = Osho.typography.body,
                            fontWeight = FontWeight.SemiBold,
                            color = colors.accent,
                            modifier = Modifier.clickable(role = Role.Button, onClick = onDone).padding(horizontal = 16.dp, vertical = 11.dp),
                        )
                    }
                }
            }
            Text(
                SELECT_TEXT_HINT,
                style = Osho.typography.footnote,
                color = colors.secondaryLabel,
                modifier = Modifier.fillMaxWidth().background(colors.barMaterial).padding(horizontal = 20.dp, vertical = 10.dp),
            )
        }
        HorizontalDivider(thickness = 0.5.dp, color = colors.separator)
        val density = LocalDensity.current
        val style = with(density) {
            TextStyle(fontSize = fontSize.toFloat().dp.toSp(), lineHeight = (fontSize.toFloat() * 1.48f).dp.toSp(), color = colors.label)
        }
        SelectionContainer(Modifier.weight(1f)) {
            Text(
                item.text,
                style = style,
                modifier = Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .windowInsetsPadding(WindowInsets.navigationBars)
                    .padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 32.dp),
            )
        }
    }
}
