package com.agraabhi.oshodiscourses.buildlogic

import com.android.build.api.dsl.ApplicationExtension
import com.android.build.api.dsl.LibraryExtension
import org.gradle.api.Project
import org.gradle.kotlin.dsl.dependencies
import org.gradle.kotlin.dsl.findByType

internal fun Project.configureCompose() {
    pluginManager.apply("org.jetbrains.kotlin.plugin.compose")
    extensions.findByType<LibraryExtension>()?.buildFeatures?.compose = true
    extensions.findByType<ApplicationExtension>()?.buildFeatures?.compose = true

    val catalog = libs
    dependencies {
        val bom = platform(catalog.lib("androidx-compose-bom"))
        add("implementation", bom)
        add("testImplementation", bom)
        add("androidTestImplementation", bom)
        add("implementation", catalog.bundle("compose"))
        add("debugImplementation", catalog.lib("androidx-compose-ui-tooling"))
        // createComposeRule needs the test activity in the merged debug manifest.
        add("debugImplementation", catalog.lib("androidx-compose-ui-test-manifest"))
    }
}
