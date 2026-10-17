plugins {
    alias(libs.plugins.osho.android.feature)
}

dependencies {
    // BackHandler for the player's in-window sheets, popovers and DeNoise sub-pages.
    implementation(libs.androidx.activity.compose)
}
