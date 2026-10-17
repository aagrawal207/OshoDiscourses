package com.agraabhi.oshodiscourses.feature.player

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Remove
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.agraabhi.oshodiscourses.core.model.PlaybackSpeed
import com.agraabhi.oshodiscourses.core.ui.components.DisabledAlpha
import com.agraabhi.oshodiscourses.core.ui.components.IosSlider
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import com.agraabhi.oshodiscourses.core.ui.theme.monospacedDigits
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * iOS `PlaybackSpeedControl`: 0.05 steps by slider, one step by −/+, common speeds by preset.
 * [rate] is the player's; the slider edits a local draft so a drag never fights rounding.
 */
@Composable
internal fun PlaybackSpeedControl(
    rate: Float,
    onRateChange: (Float) -> Unit,
    onStep: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    var draft by remember { mutableFloatStateOf(rate) }
    var editing by remember { mutableStateOf(false) }
    LaunchedEffect(rate) { if (!editing) draft = rate }
    val shown = if (editing) PlaybackSpeed.normalized(draft) else rate
    // Accessibility text sizes stack the controls; one row of five presets cannot fit.
    val stacked = LocalDensity.current.fontScale >= 1.6f

    val haptics = LocalHapticFeedback.current
    var lastTicked by remember { mutableFloatStateOf(shown) }
    LaunchedEffect(shown) {
        if (!PlaybackSpeed.matches(shown, lastTicked)) haptics.performHapticFeedback(HapticFeedbackType.SegmentTick)
        lastTicked = shown
    }

    fun apply(value: Float) {
        draft = PlaybackSpeed.normalized(value)
        onRateChange(draft)
    }

    val slider = @Composable {
        IosSlider(
            value = draft,
            onValueChange = { apply(it) },
            valueRange = PlaybackSpeed.MIN..PlaybackSpeed.MAX,
            steps = ((PlaybackSpeed.MAX - PlaybackSpeed.MIN) / PlaybackSpeed.STEP).toInt() - 1,
            onValueChangeStarted = { editing = true },
            onValueChangeFinished = { editing = false },
            modifier = Modifier.semantics {
                contentDescription = "Playback speed"
                stateDescription = PlaybackSpeed.accessibilityLabel(shown)
            },
        )
    }
    val slower = @Composable { StepButton(Icons.Rounded.Remove, "Slower", enabled = shown > PlaybackSpeed.MIN + 0.001f) { onStep(-1) } }
    val faster = @Composable { StepButton(Icons.Rounded.Add, "Faster", enabled = shown < PlaybackSpeed.MAX - 0.001f) { onStep(1) } }

    Column(
        modifier = modifier.padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        if (stacked) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("Speed", style = Osho.typography.headline, color = Osho.colors.label)
                SpeedValue(shown)
            }
            slider()
            Row(Modifier.fillMaxWidth()) {
                slower()
                Spacer(Modifier.weight(1f))
                faster()
            }
            PlaybackSpeed.presets.chunked(2).forEach { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    row.forEach { PresetButton(it, selected = PlaybackSpeed.matches(shown, it), onClick = { apply(it) }, modifier = Modifier.weight(1f)) }
                    if (row.size == 1) Spacer(Modifier.weight(1f))
                }
            }
        } else {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Speed", style = Osho.typography.headline, color = Osho.colors.label, modifier = Modifier.weight(1f))
                SpeedValue(shown)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                slower()
                Box(Modifier.weight(1f)) { slider() }
                faster()
            }
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                PlaybackSpeed.presets.forEach {
                    PresetButton(it, selected = PlaybackSpeed.matches(shown, it), onClick = { apply(it) }, modifier = Modifier.weight(1f))
                }
            }
        }
    }
}

@Composable
private fun SpeedValue(rate: Float) {
    val colors = Osho.colors
    AnimatedContent(
        targetState = PlaybackSpeed.normalized(rate),
        transitionSpec = {
            val up = targetState > initialState
            (slideInVertically(tween(200)) { if (up) it else -it } + fadeIn(tween(200)))
                .togetherWith(slideOutVertically(tween(200)) { if (up) -it else it } + fadeOut(tween(200)))
        },
        label = "speed",
        modifier = Modifier.clearAndSetSemantics {},
    ) { value ->
        Text(
            PlaybackSpeed.label(value),
            style = Osho.typography.title2.monospacedDigits(),
            fontWeight = FontWeight.SemiBold,
            color = if (PlaybackSpeed.matches(value, 1f)) colors.label else colors.accent,
        )
    }
}

/** 44 dp −/+ that repeats while held, like SwiftUI's `buttonRepeatBehavior(.enabled)`. */
@Composable
private fun StepButton(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, enabled: Boolean, onStep: () -> Unit) {
    val step by rememberUpdatedState(onStep)
    val isEnabled by rememberUpdatedState(enabled)
    Box(
        modifier = Modifier
            .size(44.dp)
            .alpha(if (enabled) 1f else DisabledAlpha)
            .semantics {
                contentDescription = label
                role = Role.Button
                if (!enabled) disabled()
                onClick { if (isEnabled) step(); isEnabled }
            }
            .pointerInput(Unit) {
                coroutineScope {
                    val scope = this
                    awaitEachGesture {
                        awaitFirstDown()
                        if (!isEnabled) return@awaitEachGesture
                        step()
                        val repeater = scope.launch {
                            delay(400)
                            while (isEnabled) {
                                step()
                                delay(90)
                            }
                        }
                        waitForUpOrCancellation()
                        repeater.cancel()
                    }
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = Osho.colors.accent, modifier = Modifier.size(20.dp))
    }
}

@Composable
private fun PresetButton(preset: Float, selected: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val colors = Osho.colors
    val shape = RoundedCornerShape(10.dp)
    Box(
        modifier = modifier
            .heightIn(min = 44.dp)
            .clip(shape)
            .background(if (selected) colors.accent.copy(alpha = 0.18f) else colors.tertiarySystemFill)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics {
                contentDescription = PlaybackSpeed.accessibilityLabel(preset)
                this.selected = selected
            },
        contentAlignment = Alignment.Center,
    ) {
        Text(
            PlaybackSpeed.label(preset),
            style = Osho.typography.subheadline.monospacedDigits(),
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            color = if (selected) colors.accent else colors.label,
            maxLines = 1,
            overflow = TextOverflow.Clip,
            modifier = Modifier.padding(horizontal = 2.dp).clearAndSetSemantics {},
        )
    }
}
