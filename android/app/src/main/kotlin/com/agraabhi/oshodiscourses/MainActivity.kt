package com.agraabhi.oshodiscourses

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
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch
import com.agraabhi.oshodiscourses.core.ui.LocalAppServices
import com.agraabhi.oshodiscourses.core.ui.theme.OshoTheme
import com.agraabhi.oshodiscourses.core.ui.theme.isDark
import com.agraabhi.oshodiscourses.navigation.AppShell

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        installSplashScreen()
        super.onCreate(savedInstanceState)
        val container = (application as OshoApplication).container

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
        // The daily accent can roll over while the app sits in the background.
        val container = (application as OshoApplication).container
        lifecycleScope.launch { container.settings.refreshShuffledTheme() }
    }
}
