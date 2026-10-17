package com.agraabhi.oshodiscourses

import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.agraabhi.oshodiscourses.core.ui.LocalAppServices
import com.agraabhi.oshodiscourses.core.ui.theme.OshoTheme
import com.agraabhi.oshodiscourses.core.ui.theme.isDark
import com.agraabhi.oshodiscourses.downloads.Downloads
import com.agraabhi.oshodiscourses.navigation.AppShell

class MainActivity : ComponentActivity() {
    private val container: AppContainer get() = (application as OshoApplication).container

    override fun onCreate(savedInstanceState: Bundle?) {
        installSplashScreen()
        super.onCreate(savedInstanceState)
        applyDebugArguments(intent)
        val container = container

        setContent {
            val settings by container.settings.settings.collectAsStateWithLifecycle()
            val dark = settings.appearance.isDark()
            // The in-app Appearance setting, not the system theme, decides the bar icon colour.
            DisposableEffect(dark) {
                val style = if (dark) {
                    SystemBarStyle.dark(Color.TRANSPARENT)
                } else {
                    SystemBarStyle.light(Color.TRANSPARENT, Color.TRANSPARENT)
                }
                enableEdgeToEdge(statusBarStyle = style, navigationBarStyle = style)
                onDispose {}
            }
            CompositionLocalProvider(LocalAppServices provides container) {
                OshoTheme(appearance = settings.appearance, accent = settings.effectiveAccentTheme) {
                    AppShell()
                }
            }
        }
    }

    override fun onStart() {
        super.onStart()
        // A user-initiated transfer job can only be scheduled while the app is visible.
        container.downloadEngine.resumePendingTransfers()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        applyDebugArguments(intent)
    }

    /** iOS `-debugDownloadNetwork`; the engine ignores it outside debuggable builds. */
    private fun applyDebugArguments(intent: Intent) {
        if (intent.hasExtra(Downloads.DEBUG_NETWORK_EXTRA)) {
            container.downloadEngine.applyDebugNetworkArgument(intent.getStringExtra(Downloads.DEBUG_NETWORK_EXTRA))
        }
    }
}
