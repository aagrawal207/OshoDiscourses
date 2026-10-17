package com.agraabhi.oshodiscourses.buildlogic

import com.android.build.api.dsl.ApplicationExtension
import com.android.build.api.dsl.LibraryExtension
import org.gradle.api.JavaVersion
import org.gradle.api.Project
import org.gradle.kotlin.dsl.configure
import org.gradle.api.tasks.testing.Test
import org.gradle.kotlin.dsl.dependencies
import org.gradle.kotlin.dsl.withType

/** Gradle path `:feature:home` becomes namespace `com.agraabhi.oshodiscourses.feature.home`. */
fun Project.defaultNamespace(): String =
    "com.agraabhi.oshodiscourses" + path.replace(':', '.').replace('-', '_')

internal fun Project.configureAndroidLibrary() {
    val catalog = libs
    extensions.configure<LibraryExtension> {
        namespace = defaultNamespace()
        compileSdk = catalog.intVersion("compileSdk")
        defaultConfig {
            minSdk = catalog.intVersion("minSdk")
            testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        }
        compileOptions {
            sourceCompatibility = JavaVersion.VERSION_21
            targetCompatibility = JavaVersion.VERSION_21
        }
        testOptions {
            unitTests.isIncludeAndroidResources = true
        }
        packaging {
            resources.excludes += setOf("/META-INF/{AL2.0,LGPL2.1}", "/META-INF/LICENSE*.md")
        }
    }
    addCommonDependencies()
}

internal fun Project.configureAndroidApplication() {
    val catalog = libs
    extensions.configure<ApplicationExtension> {
        compileSdk = catalog.intVersion("compileSdk")
        defaultConfig {
            minSdk = catalog.intVersion("minSdk")
            targetSdk = catalog.intVersion("targetSdk")
            testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        }
        compileOptions {
            sourceCompatibility = JavaVersion.VERSION_21
            targetCompatibility = JavaVersion.VERSION_21
        }
        testOptions {
            unitTests.isIncludeAndroidResources = true
        }
        packaging {
            resources.excludes += setOf("/META-INF/{AL2.0,LGPL2.1}", "/META-INF/LICENSE*.md")
        }
    }
    addCommonDependencies()
}

private fun Project.addCommonDependencies() {
    tasks.withType<Test>().configureEach {
        // Robolectric's SDK 36 runtime reaches into FileDescriptor internals that JDK 17+ seals.
        jvmArgs(
            "--add-exports=java.base/jdk.internal.access=ALL-UNNAMED",
            "--add-opens=java.base/java.io=ALL-UNNAMED",
            "--add-opens=java.base/java.lang=ALL-UNNAMED",
            "--add-opens=java.base/java.util=ALL-UNNAMED",
        )
    }

    val catalog = libs
    dependencies {
        add("implementation", catalog.lib("kotlinx-coroutines-android"))
        add("testImplementation", catalog.bundle("jvm-test"))
    }
}
