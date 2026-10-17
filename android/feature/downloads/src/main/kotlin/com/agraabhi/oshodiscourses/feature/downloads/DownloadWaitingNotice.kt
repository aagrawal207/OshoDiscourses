package com.agraabhi.oshodiscourses.feature.downloads

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Wifi
import androidx.compose.material.icons.rounded.WifiOff
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.agraabhi.oshodiscourses.core.domain.downloads.WaitingReason
import com.agraabhi.oshodiscourses.core.ui.theme.Osho

/** Row status label for a download held back by the network (iOS `WaitingReason.rowLabel`). */
val WaitingReason.rowLabel: String
    get() = when (this) {
        WaitingReason.WIFI -> "Waiting for Wi-Fi"
        WaitingReason.CONNECTION -> "Waiting for a connection"
    }

/**
 * Explains a download that is not moving because of the network, with the one action that
 * helps (iOS `DownloadWaitingNotice`). Public so Series detail can show it as a card.
 */
@Composable
fun DownloadWaitingNotice(reason: WaitingReason, onUseMobileData: () -> Unit, modifier: Modifier = Modifier) {
    val colors = Osho.colors
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                if (reason == WaitingReason.WIFI) Icons.Rounded.Wifi else Icons.Rounded.WifiOff,
                contentDescription = null,
                tint = colors.label,
                modifier = Modifier.size(18.dp),
            )
            Text(
                reason.rowLabel,
                style = Osho.typography.subheadline,
                fontWeight = FontWeight.SemiBold,
                color = colors.label,
                modifier = Modifier.padding(start = 8.dp),
            )
        }
        Text(
            if (reason == WaitingReason.WIFI) {
                "Downloads use Wi-Fi only. Each discourse is about 20–30 MB."
            } else {
                "Downloads continue when you're back online."
            },
            style = Osho.typography.footnote,
            color = colors.secondaryLabel,
        )
        if (reason == WaitingReason.WIFI) {
            Button(
                onClick = onUseMobileData,
                shape = CircleShape,
                colors = ButtonDefaults.buttonColors(containerColor = colors.accent, contentColor = colors.onAccent),
                contentPadding = PaddingValues(horizontal = 14.dp, vertical = 7.dp),
                modifier = Modifier
                    .heightIn(min = 34.dp)
                    .semantics {
                        onClick(label = "Downloads now and later can use mobile data. You can change this in Settings.") {
                            onUseMobileData()
                            true
                        }
                    },
            ) {
                Text("Use Mobile Data", style = Osho.typography.subheadline, fontWeight = FontWeight.SemiBold)
            }
        }
    }
}
