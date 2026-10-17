package com.agraabhi.oshodiscourses.buildlogic

import org.gradle.api.Project
import org.gradle.api.artifacts.VersionCatalog
import org.gradle.api.artifacts.VersionCatalogsExtension
import org.gradle.kotlin.dsl.getByType

val Project.libs: VersionCatalog
    get() = extensions.getByType<VersionCatalogsExtension>().named("libs")

fun VersionCatalog.lib(alias: String) = findLibrary(alias).get()

fun VersionCatalog.bundle(alias: String) = findBundle(alias).get()

fun VersionCatalog.intVersion(alias: String): Int = findVersion(alias).get().requiredVersion.toInt()
