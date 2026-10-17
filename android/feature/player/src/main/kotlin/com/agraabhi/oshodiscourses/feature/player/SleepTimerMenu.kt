package com.agraabhi.oshodiscourses.feature.player

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.agraabhi.oshodiscourses.core.domain.sleep.SleepTimer
import com.agraabhi.oshodiscourses.core.domain.sleep.SleepTimerMode
import com.agraabhi.oshodiscourses.core.domain.sleep.SleepTimerState
import com.agraabhi.oshodiscourses.core.ui.theme.Osho

/** The Sleep popover (iOS `PlayerView.sleepTimerContent`); every item applies and closes. */
@Composable
internal fun SleepTimerMenu(
    state: SleepTimerState,
    onEndOfDiscourse: () -> Unit,
    onMinutes: (Int) -> Unit,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val checked = PlayerFormatting.checkedSleepMinutes(state)
    Column(modifier.fillMaxWidth().padding(vertical = 8.dp)) {
        SleepItem("End of discourse", checked = state.mode == SleepTimerMode.END_OF_DISCOURSE, onClick = onEndOfDiscourse)
        MenuDivider()
        SleepTimer.PRESET_MINUTES.forEach { minutes ->
            SleepItem("$minutes min", checked = checked == minutes, onClick = { onMinutes(minutes) })
        }
        if (state.isActive) {
            MenuDivider()
            SleepItem("Cancel", checked = false, color = Osho.colors.systemRed, onClick = onCancel)
        }
    }
}

@Composable
private fun SleepItem(label: String, checked: Boolean, onClick: () -> Unit, color: Color = Osho.colors.label) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { selected = checked }
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, style = Osho.typography.body, color = color, modifier = Modifier.weight(1f))
        if (checked) Icon(Icons.Rounded.Check, contentDescription = null, tint = color, modifier = Modifier.size(14.dp))
    }
}

@Composable
private fun MenuDivider() {
    HorizontalDivider(Modifier.padding(vertical = 2.dp), thickness = Dp.Hairline, color = Osho.colors.separator)
}
