package com.agraabhi.oshodiscourses.core.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.agraabhi.oshodiscourses.core.ui.BottomClearanceSpacer
import com.agraabhi.oshodiscourses.core.ui.theme.Osho

/** A large-title page with a note, for screens whose feature task has not landed yet. */
@Composable
fun PlaceholderScreen(
    title: String,
    modifier: Modifier = Modifier,
    message: String = "Coming soon.",
    content: @Composable () -> Unit = {},
) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .background(Osho.colors.systemBackground)
            .statusBarsPadding()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            text = title,
            style = Osho.typography.largeTitle,
            fontWeight = FontWeight.Bold,
            color = Osho.colors.label,
            modifier = Modifier.semantics { heading() },
        )
        Text(text = message, style = Osho.typography.body, color = Osho.colors.secondaryLabel)
        content()
        BottomClearanceSpacer()
    }
}
