package com.agraabhi.oshodiscourses.core.ui

import androidx.compose.runtime.staticCompositionLocalOf
import com.agraabhi.oshodiscourses.core.domain.AppServices

/** The process-wide services; `:app` provides the container, previews and tests provide fakes. */
val LocalAppServices = staticCompositionLocalOf<AppServices> {
    error("LocalAppServices is not provided. Wrap the content in CompositionLocalProvider(LocalAppServices provides ...).")
}
