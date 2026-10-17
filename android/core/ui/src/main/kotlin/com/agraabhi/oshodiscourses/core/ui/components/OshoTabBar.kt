package com.agraabhi.oshodiscourses.core.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.agraabhi.oshodiscourses.core.ui.theme.Osho

@Immutable
data class OshoTabItem(val title: String, val icon: ImageVector)

/** Height of the capsule itself, without the navigation-bar inset below it. */
val OshoTabBarHeight = 62.dp

/**
 * The iOS 26 floating glass tab bar (ui-style.md §3.3, §8). Material's NavigationBar reads
 * too differently: iOS floats a capsule with filled icons and a soft pill on the selection.
 */
@Composable
fun OshoTabBar(
    items: List<OshoTabItem>,
    selectedIndex: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = Osho.colors
    Box(modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 20.dp)) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(OshoTabBarHeight)
                .shadow(12.dp, CircleShape, ambientColor = colors.glassShadow, spotColor = colors.glassShadow)
                .glass(CircleShape)
                .border(0.5.dp, colors.glassBorder, CircleShape)
                .padding(4.dp)
                .selectableGroup(),
            horizontalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            items.forEachIndexed { index, item ->
                TabItem(item, selected = index == selectedIndex, onClick = { onSelect(index) }, modifier = Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun TabItem(item: OshoTabItem, selected: Boolean, onClick: () -> Unit, modifier: Modifier) {
    val colors = Osho.colors
    val tint = if (selected) colors.accent else colors.label
    Column(
        modifier = modifier
            .fillMaxHeight()
            .background(if (selected) colors.tabSelectionPill else Color.Transparent, CircleShape)
            .selectable(
                selected = selected,
                onClick = onClick,
                role = Role.Tab,
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
            ),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        // SF tab glyphs draw about 26 tall; Material's leave a margin inside the box, hence 30.
        Icon(item.icon, contentDescription = null, tint = tint, modifier = Modifier.size(30.dp))
        Text(item.title, style = Osho.typography.tabLabel, color = tint, maxLines = 1)
    }
}
