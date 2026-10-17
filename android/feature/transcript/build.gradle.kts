plugins {
    alias(libs.plugins.osho.android.feature)
}

dependencies {
    // BackHandler for leaving search, passage selection and Select Text with the system back gesture.
    implementation(libs.androidx.activity.compose)
}
