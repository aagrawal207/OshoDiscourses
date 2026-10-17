plugins {
    alias(libs.plugins.osho.android.library)
}

dependencies {
    api(projects.core.domain)
    implementation(libs.play.billing.ktx)
    implementation(libs.play.review.ktx)
    implementation(libs.androidx.datastore.preferences)

    testImplementation(projects.core.testing)
}
