package com.agraabhi.oshodiscourses.navigation

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.core.LinearOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.agraabhi.oshodiscourses.R
import com.agraabhi.oshodiscourses.core.ui.theme.LaunchBackground
import kotlinx.coroutines.delay

/**
 * iOS `LaunchView` (ui-style.md §6.17), held 0.15 s over the mounted app, then faded. The lotus
 * stays where the system splash drew it, so the hand-off does not jump.
 */
@Composable
fun LaunchOverlay() {
    var visible by rememberSaveable { mutableStateOf(true) }
    LaunchedEffect(Unit) {
        delay(150)
        visible = false
    }
    AnimatedVisibility(visible = visible, enter = EnterTransition.None, exit = fadeOut(tween(250, easing = LinearOutSlowInEasing))) {
        Box(
            Modifier.fillMaxSize().background(LaunchBackground).clearAndSetSemantics { contentDescription = "Osho Talks" },
            contentAlignment = Alignment.Center,
        ) {
            Image(painterResource(R.drawable.launch_lotus), contentDescription = null, modifier = Modifier.size(132.dp))
            // Fixed size, as on iOS: the launch title does not follow the font scale.
            CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density, 1f)) {
                Text(
                    "Osho Talks",
                    style = TextStyle(fontSize = 22.sp, fontWeight = FontWeight.SemiBold, color = Color.White),
                    modifier = Modifier.offset(y = 66.dp + 22.dp + 13.dp),
                )
            }
        }
    }
}
