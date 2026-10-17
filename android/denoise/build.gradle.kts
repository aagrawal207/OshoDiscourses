plugins {
    alias(libs.plugins.osho.android.library)
}

dependencies {
    api(projects.core.domain)
    implementation(libs.androidx.media3.common)
    implementation(libs.androidx.media3.exoplayer)

    testImplementation(libs.robolectric)
}
