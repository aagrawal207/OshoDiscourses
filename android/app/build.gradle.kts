plugins {
    alias(libs.plugins.osho.android.application)
    alias(libs.plugins.osho.android.screenshot)
}

android {
    namespace = "com.agraabhi.oshodiscourses"

    defaultConfig {
        applicationId = "com.agraabhi.oshodiscourses"
        versionCode = 1
        versionName = "0.1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
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
    // Fakes back AppContainer until the coordinator swaps in the real implementations.
    implementation(projects.core.testing)

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
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.viewmodel.navigation3)
    implementation(libs.androidx.navigation3.runtime)
    implementation(libs.androidx.navigation3.ui)
    implementation(libs.kotlinx.serialization.json)

    testImplementation(libs.androidx.test.core)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.espresso.core)
    androidTestImplementation(libs.androidx.test.uiautomator)
    androidTestImplementation(libs.androidx.compose.ui.test.junit4)
}
