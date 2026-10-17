plugins {
    alias(libs.plugins.osho.android.library)
}

dependencies {
    api(projects.core.domain)
    implementation(libs.androidx.datastore.preferences)
    implementation(libs.kotlinx.serialization.json)

    testImplementation(libs.robolectric)
    testImplementation(libs.androidx.test.core)
    testImplementation(projects.core.testing)
}
