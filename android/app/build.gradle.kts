plugins {
    alias(libs.plugins.osho.android.application)
    alias(libs.plugins.osho.android.screenshot)
}

android {
    namespace = "com.agraabhi.oshodiscourses"

    defaultConfig {
        applicationId = "com.agraabhi.oshodiscourses"
        versionCode = 1
        versionName = "1.0.0"
        // Play Console > Monetization setup > Licensing. Release builds must pass -Posho.playLicenseKey.
        val licenseKey = providers.gradleProperty("osho.playLicenseKey").orElse("").get()
        buildConfigField("String", "PLAY_LICENSE_KEY", "\"$licenseKey\"")
    }

    // The upload key and its passwords live outside the repo, in ~/.gradle/gradle.properties.
    val uploadStoreFile = providers.gradleProperty("osho.uploadStoreFile").orNull
    signingConfigs {
        if (uploadStoreFile != null) {
            create("upload") {
                storeFile = file(uploadStoreFile)
                storePassword = providers.gradleProperty("osho.uploadStorePassword").get()
                keyAlias = providers.gradleProperty("osho.uploadKeyAlias").get()
                keyPassword = providers.gradleProperty("osho.uploadKeyPassword").get()
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Local R8 checks only (-Posho.debugSignRelease=true); Play builds sign with the upload key.
            signingConfig = when {
                providers.gradleProperty("osho.debugSignRelease").orNull == "true" -> signingConfigs.getByName("debug")
                uploadStoreFile != null -> signingConfigs.getByName("upload")
                else -> null
            }
        }
    }

    buildFeatures {
        buildConfig = true
    }
}

dependencies {
    implementation(projects.core.model)
    implementation(projects.core.domain)
    implementation(projects.core.data)
    implementation(projects.core.ui)

    implementation(projects.playback)
    implementation(projects.downloads)
    implementation(projects.denoise)
    implementation(projects.transcript)
    implementation(projects.sync)
    implementation(projects.billing)

    implementation(projects.feature.home)
    implementation(projects.feature.library)
    implementation(projects.feature.series)
    implementation(projects.feature.player)
    implementation(projects.feature.transcript)
    implementation(projects.feature.downloads)
    implementation(projects.feature.settings)

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.core.splashscreen)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.process)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.viewmodel.navigation3)
    implementation(libs.androidx.navigation3.runtime)
    implementation(libs.androidx.navigation3.ui)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.okhttp)

    testImplementation(projects.core.testing)
    testImplementation(libs.androidx.test.core)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.espresso.core)
    androidTestImplementation(libs.androidx.test.uiautomator)
    androidTestImplementation(libs.androidx.compose.ui.test.junit4)
}

// A Play bundle must verify purchase signatures and be signed with the upload key.
val checkPlayRelease = tasks.register("checkPlayRelease") {
    val licenseKey = providers.gradleProperty("osho.playLicenseKey").orElse("")
    val uploadStore = providers.gradleProperty("osho.uploadStoreFile").orElse("")
    doLast {
        check(licenseKey.get().isNotBlank()) { "Pass -Posho.playLicenseKey (Play Console > Monetization setup > Licensing)." }
        check(uploadStore.get().isNotBlank()) { "Set osho.uploadStoreFile and its passwords in ~/.gradle/gradle.properties." }
    }
}
tasks.matching { it.name == "bundleRelease" }.configureEach { dependsOn(checkPlayRelease) }
