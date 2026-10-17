plugins {
    alias(libs.plugins.osho.android.library)
}

dependencies {
    api(projects.core.domain)
    implementation(libs.play.services.auth)
    implementation(libs.kotlinx.coroutines.play.services)
    implementation(libs.okhttp)
    implementation(libs.kotlinx.serialization.json)

    testImplementation(projects.core.testing)
    testImplementation(libs.okhttp.mockwebserver)
}
