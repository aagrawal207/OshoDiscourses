plugins {
    alias(libs.plugins.osho.android.compose)
    alias(libs.plugins.osho.android.screenshot)
}

dependencies {
    api(projects.core.model)
    api(projects.core.domain)
    // BackHandler for the in-window sheets and popovers.
    implementation(libs.androidx.activity.compose)
    implementation(libs.coil.compose)
    implementation(libs.coil.network.okhttp)
    api(libs.haze)
    api(libs.haze.blur)
    implementation(libs.haze.materials)
}
